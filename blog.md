---
title: "組み込み Linux のブート画面を黒フレームゼロで Qt アプリに繋ぐ"
emoji: "🛰️"
type: "tech"
topics: ["qt", "linux", "embedded", "plymouth", "drm"]
published: false
---

組み込み Linux 機器では、電源投入からアプリケーション UI が表示されるまでの間を [Plymouth](https://gitlab.freedesktop.org/plymouth/plymouth) のブートスプラッシュで繋ぐのが定番です。ところが実際にやってみると、**Plymouth からアプリへ切り替わる瞬間に一瞬黒い画面が挟まる**、**スプラッシュのアニメーションが切り替わりでリセットされる**、という 2 つの「あと一歩」が残ります。

この記事では、Qt ([eglfs](https://doc.qt.io/qt-6/embedded-linux.html#eglfs)) アプリへのハンドオフを **黒フレームゼロ** にし、さらに **Plymouth で動いていたアニメーションをアプリ側がそのままの位相で引き継ぐ** ところまでを実装します。

検証環境は [Toradex Verdin iMX8MP](https://developer.toradex.com/hardware/verdin-som-family/modules/verdin-imx8m-plus/)([Torizon OS](https://developer.toradex.com/torizon/) 7、Qt 6.11 / eglfs_kms、1280×800 LVDS パネル)ですが、KMS でスキャンアウトする Linux + Qt 構成なら同じ考え方が使えます。

## ブートチェーンと「黒」の正体

まず、何も対策しないデフォルト状態の画面遷移を時系列で見てみます。

<!-- TODO: Zenn にアップロードしてパスを差し替え -->
![Torizon OS 起動時の画面遷移（時系列）— デフォルトでは t2〜t4 が黒](/images/boot-timeline-before.png)
*デフォルトの遷移。t2(Plymouth 終了)から t5(アプリの初回フレーム)までずっと黒い*

黒が出る区間は 3 つあります。

1. **t2: Plymouth が終了して画面が消える**(本記事の主題)
2. **t3: アプリの DRM (KMS) 初期化でモードが切り替わる**
3. **t4: アプリの初回フレーム描画までのラグ**(リソース読み込みなど)

問題は Plymouth → Qt の継ぎ目です。よく使われるのは

```sh
plymouth quit --retain-splash
```

で「最後のフレームを残したまま終了」させる方法ですが、これでも黒が出ます。理由は [Plymouth のソース](https://gitlab.freedesktop.org/plymouth/plymouth/-/blob/main/src/main.c)を読むと明確です。

- `quit` を受けたデーモンは `quit_splash()` で **スプラッシュのフレームバッファを解放**してからプロセスを終了します
- スキャンアウト中の FB が破棄されると、**カーネルは CRTC を強制的に無効化**します([`drm_framebuffer_remove()`](https://elixir.bootlin.com/linux/latest/source/drivers/gpu/drm/drm_framebuffer.c) がスキャンアウト中のプレーンを落とします)
- 次に Qt (eglfs) が最初のフレームを出すまでの間、パネルには何も供給されない = **黒**

つまり `--retain-splash` は「終了処理の順序を変える」だけで、**バッファの所有者(plymouthd)が死ぬ以上、絵は残せない**のです。

## 解法 1: QUIT ではなく DEACTIVATE を送る

Plymouth には quit とは別に **DEACTIVATE** という操作があります(X や Wayland コンポジタへのシームレスな引き継ぎのために用意された経路で、Ray Strode の [Plymouth ⟶ X transition](https://blogs.gnome.org/halfline/2009/11/28/plymouth-%E2%9F%B6-x-transition/) が原典です)。

| | QUIT (--retain-splash) | DEACTIVATE |
|---|---|---|
| plymouthd | 終了する | **生き続ける(idle)** |
| スプラッシュ FB | 解放される → 黒 | **保持される** |
| DRM master | 解放される | **解放される** |

DEACTIVATE なら、plymouthd は最後のフレームを掴んだまま [DRM master](https://docs.kernel.org/gpu/drm-uapi.html#drm-master) だけを手放します([`ply_renderer_deactivate`](https://gitlab.freedesktop.org/plymouth/plymouth/-/blob/main/src/libply-splash-core/ply-renderer.c) → `drmDropMaster`)。パネルには Plymouth の絵が出続け、その上に Qt が自分のフレームを page-flip で重ねるだけ — 黒の出る余地がありません。残った idle なデーモンは、後から `plymouth-quit.service` が普通に片付けてくれます。

### ワイヤプロトコル

Plymouth のクライアントプロトコル([`src/ply-boot-protocol.h`](https://gitlab.freedesktop.org/plymouth/plymouth/-/blob/main/src/ply-boot-protocol.h))では、引数なしリクエストは「コマンド 1 文字 + NUL」です。DEACTIVATE は `'D'` なので、送るバイト列はたった 2 バイトです。応答は ACK (`0x06`)。

アプリ起動の最初(QGuiApplication を作る前)に、[abstract socket](https://man7.org/linux/man-pages/man7/unix.7.html) へ直接送ります。

```cpp
// DEACTIVATE: plymouthd は生きたまま絵を保持し、DRM master だけ手放す。
// ACK を待ってから eglfs を初期化すれば master の取り合いも起きない。
static void deactivatePlymouth()
{
    const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return;
    struct timeval tv { 3, 0 };
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    static const char name[] = "/org/freedesktop/plymouthd"; // abstract socket
    struct sockaddr_un addr {};
    addr.sun_family = AF_UNIX;
    addr.sun_path[0] = '\0';
    std::memcpy(addr.sun_path + 1, name, sizeof(name) - 1);
    const socklen_t len = offsetof(struct sockaddr_un, sun_path) + 1 + (sizeof(name) - 1);

    if (::connect(fd, reinterpret_cast<struct sockaddr *>(&addr), len) == 0) {
        const unsigned char request[] = { 'D', 0x00 };
        if (::write(fd, request, sizeof(request)) == (ssize_t)sizeof(request)) {
            char ack = 0;
            (void)::read(fd, &ack, 1);   // ACK = master 解放完了
        }
    }
    ::close(fd);
}
```

これは [`plymouth deactivate`](https://gitlab.freedesktop.org/plymouth/plymouth/-/blob/main/src/client/plymouth.c) コマンドと等価ですが、アプリ内から ACK を同期的に待つことで「Plymouth が master を手放す **前に** eglfs が [`drmSetMaster()`](https://man.archlinux.org/man/drmSetMaster.3) してしまう」ブート時の競合(atomic commit が `EACCES` で失敗し続けるやつ)も同時に解決できます。

### モードが一致していれば modeset は走らない

「Qt が画面を初期化したら、どのみち modeset で一瞬暗転するのでは?」という疑問が湧きますが、ここが [DRM atomic](https://docs.kernel.org/gpu/drm-kms.html#atomic-mode-setting) の良いところです。

eglfs は初回フレームで MODE_ID / ACTIVE プロパティを atomic コミットに積みますが、DRM コアは**モードの内容**を比較し([`drm_mode_equal()`](https://elixir.bootlin.com/linux/latest/source/drivers/gpu/drm/drm_modes.c))、現在のモードと同一なら `mode_changed = false`、つまり**プレーン更新のみ**として処理します([`drm_atomic_helper_check_modeset()`](https://elixir.bootlin.com/linux/latest/source/drivers/gpu/drm/drm_atomic_helper.c))。パネルの再プログラム(≒1 フレームのブランク)は発生しません。

Plymouth も Qt も同じコネクタの preferred mode を選ぶので、実機ではこの条件が自然に成立します。ブートログで確認すると:

```
[boot] +13ms Plymouth deactivated (alive, DRM released)
[boot] +734ms QML loaded
```

の間、パネルには Plymouth の最終フレームが出続け、Qt の初回フレームが page-flip でそれを置き換えます。黒フレームはゼロです。

## 解法 2: アニメーションの位相を引き継ぐ

黒が消えても、もうひとつ気になる点が残ります。Plymouth のスプラッシュでアニメーション(今回のデモでは軌道を周回する衛星)が動いていた場合、ハンドオフの瞬間に

1. Plymouth のアニメは deactivate 時点で**凍結**する(絵は残る)
2. アプリ側のスプラッシュが同じアニメを**最初から**再生し直す

となり、「一時停止 → 位置がワープして再開」に見えます。これを「凍結した位置からそのまま走り続ける」ようにします。

### アイデア: フレームに位相を埋め込み、KMS から読み戻す

鍵は 2 つです。

1. **Plymouth テーマが毎フレーム、画面の隅に“人間には見えないマーカー”を描き、その位置でアニメの位相をエンコードする**
2. **アプリが起動時に、CRTC に残っている Plymouth の最終フレームを KMS から読み戻してマーカーをデコードする**

DEACTIVATE のおかげで plymouthd が生きており、FB も生きているので、(2) が可能になるわけです。読み戻しはカメラ撮影と違って**ピクセル値が正確に取れる**ため、マーカーは背景より数 LSB 明るいだけで十分 — 目視では分かりません。

### テーマ側: 位置エンコードのマーカー

アニメの軌道は 240 点のテーブル(`trace_x[]/trace_y[]`)としてテーマに焼き込み、ヘッド位置 `head`(0..239)がリフレッシュ毎に進みます。マーカーは 8×3 px のスプライトで、**x 座標が head をそのままエンコード**します。テーマは [Plymouth の script プラグイン](https://www.freedesktop.org/wiki/Software/Plymouth/Scripts/)で書いています。

```
# astra.script (Plymouth script プラグイン) — 抜粋
marker = Sprite(Image("marker.png"));   # 8x3, 背景より +10LSB 程度の色
marker.SetZ(30);

fun refresh_cb() {
    accum = accum + 1;
    head = Math.Int(accum * 2.2) % N;
    marker.SetPosition(Math.Int(head * 1272 / (N - 1)), 797, 30);
    # ... 衛星本体とテールの描画 ...
}
Plymouth.SetRefreshFunction(refresh_cb);
```

色で位相を表す案もありますが、Plymouth script のスプライトは静止画像なので実行時に色を変えにくく、8bit 量子化のマージンも気になります。**位置エンコードならスプライト 1 枚を `SetPosition` で動かすだけ**で、デコードも頑健です。

### アプリ側: KMS リードバック

起動直後(DEACTIVATE の ACK 後)に、CRTC 上の FB を [libdrm](https://gitlab.freedesktop.org/mesa/drm) で読み戻します。手順は

1. [`drmModeGetCrtc()`](https://man.archlinux.org/man/drmModeGetCrtc.3) で現在スキャンアウト中の `buffer_id` を取得
2. [`drmModeGetFB()`](https://man.archlinux.org/man/drmModeGetFB.3) で GEM ハンドル・pitch・サイズを取得(**DRM master か CAP_SYS_ADMIN が必要**。組み込みコンテナの root なら OK)
3. `DRM_IOCTL_MODE_MAP_DUMB` で mmap(Plymouth の DRM レンダラはリニアな [dumb buffer](https://docs.kernel.org/gpu/drm-kms.html#dumb-buffer-objects) を使うのでこれで読めます。だめなら [`drmPrimeHandleToFD()`](https://man.archlinux.org/man/drmPrimeHandleToFD.3) + mmap にフォールバック)
4. マーカー行をスキャンしてデコード

```cpp
// 最下行のマーカーをデコード: 行の最暗チャネル +5 以上が
// RGB すべてで成立する画素 = マーカー(8px)。重心 x → インデックス。
static int decodeMarker(const uchar *base, quint32 w, quint32 h, quint32 pitch)
{
    const uchar *row = base + size_t(pitch) * (h - 2);
    int floorv = 255;
    for (quint32 x = 0; x < w; ++x) {
        const uchar *p = row + size_t(x) * 4;          // XRGB8888: B,G,R,X
        floorv = std::min({ floorv, int(p[0]), int(p[1]), int(p[2]) });
    }
    long sum = 0; int cnt = 0;
    for (quint32 x = 0; x < w; ++x) {
        const uchar *p = row + size_t(x) * 4;
        if (p[0] >= floorv + 5 && p[1] >= floorv + 5 && p[2] >= floorv + 5) {
            sum += x; ++cnt;
        }
    }
    if (cnt < 3 || cnt > 24)
        return -1;                                     // マーカーなし
    const double left = double(sum) / cnt - 3.5;
    return std::clamp(int(left * 239.0 / double(w - 8) + 0.5), 0, 239);
}
```

デコードした位相は [`QQmlApplicationEngine::setInitialProperties()`](https://doc.qt.io/qt-6/qqmlapplicationengine.html#setInitialProperties) で QML へ渡します。

```cpp
const int satStartIndex = readSatStartIndex();   // -1 ならマーカーなし
QQmlApplicationEngine engine;
engine.setInitialProperties({ { QStringLiteral("satStartIndex"), satStartIndex } });
engine.loadFromModule("AstraDemo", "Main");
```

### QML 側: 同じテーブルでオフセット再生

アニメのテーブルはテーマ生成器が **Plymouth script と QML 用 JS の両方に同じ値を出力**するので、ズレようがありません。QML 側は受け取ったインデックスをオフセットとして足すだけです。

```qml
import "OrbitTrace.js" as Orbit   // gen.py が script と同時に出力

Item {
    id: orbit
    readonly property int startIdx: win.satStartIndex >= 0 ? win.satStartIndex : 0
    property real head: 0
    NumberAnimation on head {
        from: 0; to: Orbit.n; duration: 2200
        loops: Animation.Infinite; running: true
    }
    Repeater {
        model: 6   // 先頭 + フェードするテール
        Image {
            source: "images/sat.png"
            readonly property int idx:
                ((Math.floor(orbit.head) + orbit.startIdx - index * 3) % Orbit.n + Orbit.n) % Orbit.n
            x: Orbit.tx[idx] * orbit.sx - width / 2
            y: Orbit.ty[idx] * orbit.sy - height / 2
            opacity: (1.0 - index / 6) * (1.0 - index / 6)
        }
    }
}
```

これで「Plymouth で index 43 まで進んだ衛星が、アプリのスプラッシュでも index 43 から走り続ける」が実現します。実機のブートログ:

```
[boot] +13ms Plymouth deactivated (alive, DRM released)
[boot] +32ms sweep phase from KMS: index 43        ← 読み戻し+デコードは ~20ms
[boot] +734ms QML loaded
```

## 改善後の遷移(全体像)

ここまでの 2 つの対策を入れた後の時系列です。

<!-- TODO: Zenn にアップロードしてパスを差し替え -->
![Torizon OS 起動時の画面遷移（改善後・黒画面撲滅）](/images/boot-timeline-after.png)
*改善後の遷移。黒画面は撲滅。Plymouth の最終フレームのまま一瞬止まり、同じ位置からアニメーションが再開する*

黒画面は完全になくなりますが、**deactivate からアプリの初回フレームまでの間、アニメーションが一時停止する区間は残ります**(アプリのプロセス起動+QML ロードの時間)。画面は Plymouth の最終フレームを表示し続けるので破綻はしませんが、ここを縮めたければアプリ側の起動最適化(エントリ QML の軽量化、不要モジュールのロード排除など)が効いてきます。

## アプリ側スプラッシュの構成

最初のフレームを軽くするため、エントリの QML は QtQuick だけで完結させ、重い本体 UI は背後で [Loader](https://doc.qt.io/qt-6/qml-qtquick-loader.html) の遅延ロードにしてクロスフェードします。

```qml
Window {
    Loader {
        id: ui
        asynchronous: true
        active: false                       // スプラッシュ表示後にロード開始
        source: "GroundControl.qml"
        opacity: 0
        onLoaded: opacity = 1
        Behavior on opacity { NumberAnimation { duration: 450 } }
    }
    Item {
        id: splash                          // 背景画像 + 衛星スイープ + Qt ロゴ
        // ...
    }
    Timer { interval: 5000; running: true; onTriggered: ui.active = true }
    Connections { target: ui; function onLoaded() { splash.opacity = 0 } }
}
```

スプラッシュの背景はテーマと同じ生成画像なので、Plymouth → Qt の切り替わりは「左上に Qt ロゴがフェードインする」ことでしか分かりません(逆に言うと、ロゴの出現がハンドオフの瞬間の目印になります)。

## ハマりどころ

実装で踏みやすいポイントをまとめます。

| 症状 | 原因 | 対処 |
|---|---|---|
| ハンドオフで ~100ms の黒 | `quit --retain-splash`(FB が解放される) | **DEACTIVATE** を送る |
| ブート時に atomic commit が EACCES で失敗し続ける | Plymouth より先に `drmSetMaster()` してしまう | DEACTIVATE の **ACK を待ってから** Qt を初期化 |
| テーマを更新したのに反映されない | 見えているスプラッシュは **initramfs 内の plymouthd** が initrd 内のテーマで描画している | テーマは initramfs に入れる(イメージビルドに組込む) |
| `drmModeGetFB` で handle が取れない | master でも CAP_SYS_ADMIN でもない | 権限を付与するか、リードバック失敗時は位相 0 で開始するフォールバックに |
| 実機でテキストが出ない | ランタイムにフォントが 1 つもない | アプリの qrc にフォントを埋め込み [`FontLoader`](https://doc.qt.io/qt-6/qml-qtquick-fontloader.html) で読む(日本語は [Noto Sans JP](https://fonts.google.com/noto/specimen/Noto+Sans+JP) など) |

## デモプロジェクト

公開デモ「ASTRA Ground Control」(衛星管制風のダミー UI)を [signal-slot/seamless-boot-demo](https://github.com/signal-slot/seamless-boot-demo) で公開しています。

```
seamless-boot-demo/
  gen.py                     # テーマ+アプリ資産の生成器(Pillow)
  main.cpp                   # DEACTIVATE / KMS リードバック / 位相注入
  CMakeLists.txt             # libdrm は任意リンク(デスクトップでは no-op)
  qml/
    Main.qml                 # スプラッシュ + 遅延ロード + クロスフェード
    GroundControl.qml        # ダミーの管制ダッシュボード
    OrbitTrace.js            # gen.py が出力する共有軌道テーブル
    images/  fonts/
  plymouth/
    plymouthd.defaults       # Theme=astra
    themes/astra/            # script テーマ一式(gen.py が出力)
```

`gen.py` が背景・スプライト・マーカー・`astra.script`・`OrbitTrace.js` を**ひとつのソースから**生成するため、Plymouth と QML のアニメーションは常に同一です。デスクトップでは `cmake -B build && cmake --build build && ./build/astra-demo` でそのまま動きます(リードバックは no-op になり、位相 0 から再生)。

## まとめ

- `plymouth quit --retain-splash` の黒は **FB の解放**が原因。**DEACTIVATE** なら plymouthd が絵を保持したまま DRM master だけ手放せる
- モードが同一なら DRM atomic は modeset を走らせないので、Qt の初回フレームは **page-flip だけ**で重なる — 黒フレームゼロ
- DEACTIVATE で FB が生きているので、**KMS から最終フレームを読み戻せる**。テーマに不可視の位置マーカーを描いておけば、アニメーションの位相をアプリへ正確に引き継げる
- テーマ生成器が Plymouth script と QML の両方へ同じ軌道テーブルを出力することで、引き継ぎは 1 px もズレない

電源投入からアプリまで、アニメーションが途切れず流れるブートは気持ちがいいものです。ぜひお手元の組み込み Qt プロジェクトでも試してみてください。

## 参考リンク

- [Plymouth](https://gitlab.freedesktop.org/plymouth/plymouth) / [ply-boot-protocol.h](https://gitlab.freedesktop.org/plymouth/plymouth/-/blob/main/src/ply-boot-protocol.h) / [script プラグインのスクリプト言語](https://www.freedesktop.org/wiki/Software/Plymouth/Scripts/)
- Ray Strode, [Plymouth ⟶ X transition](https://blogs.gnome.org/halfline/2009/11/28/plymouth-%E2%9F%B6-x-transition/) — シームレス引き継ぎの原典
- カーネル DRM ドキュメント: [KMS](https://docs.kernel.org/gpu/drm-kms.html) / [DRM master](https://docs.kernel.org/gpu/drm-uapi.html#drm-master) / [dumb buffer](https://docs.kernel.org/gpu/drm-kms.html#dumb-buffer-objects)
- [libdrm (mesa/drm)](https://gitlab.freedesktop.org/mesa/drm)
- Qt: [Embedded Linux (eglfs)](https://doc.qt.io/qt-6/embedded-linux.html) / [QQmlApplicationEngine::setInitialProperties](https://doc.qt.io/qt-6/qqmlapplicationengine.html#setInitialProperties) / [FontLoader](https://doc.qt.io/qt-6/qml-qtquick-fontloader.html) / [Loader](https://doc.qt.io/qt-6/qml-qtquick-loader.html)
- [Toradex Verdin iMX8MP](https://developer.toradex.com/hardware/verdin-som-family/modules/verdin-imx8m-plus/) / [Torizon OS](https://developer.toradex.com/torizon/)
- デモ一式: [signal-slot/seamless-boot-demo](https://github.com/signal-slot/seamless-boot-demo)
