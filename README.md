# ASTRA Ground Control — seamless boot-splash demo

A demo of a **zero-black-frame boot** on embedded Linux: the
[Plymouth](https://gitlab.freedesktop.org/plymouth/plymouth) boot splash hands
the screen over to a Qt Quick
([eglfs](https://doc.qt.io/qt-6/embedded-linux.html#eglfs)) application with no
black frame in between, and the splash animation **continues from the exact
position where Plymouth left off**.

Two techniques, working together:

1. **DEACTIVATE instead of `quit --retain-splash`** — quitting makes plymouthd
   free its framebuffer, which force-disables the CRTC (that is where the usual
   black gap comes from). Sending the two-byte `DEACTIVATE` request
   (`{'D', 0x00}`, see
   [ply-boot-protocol.h](https://gitlab.freedesktop.org/plymouth/plymouth/-/blob/main/src/ply-boot-protocol.h))
   keeps the daemon alive holding its last frame while it drops
   [DRM master](https://docs.kernel.org/gpu/drm-uapi.html#drm-master), so the
   app's first frame simply page-flips on top. This is Ray Strode's
   [Plymouth ⟶ X transition](https://blogs.gnome.org/halfline/2009/11/28/plymouth-%E2%9F%B6-x-transition/)
   applied to eglfs.
2. **Phase continuity via KMS read-back** — the Plymouth theme draws a
   near-invisible 8×3 px marker on the bottom edge whose *x position* encodes
   the animation phase. At startup the app reads the frozen frame back from the
   CRTC (`drmModeGetCrtc` → `drmModeGetFB` → `DRM_IOCTL_MODE_MAP_DUMB`, with a
   [PRIME](https://docs.kernel.org/gpu/drm-uapi.html#prime-buffer-sharing)
   fallback), decodes the marker, and resumes the same sweep from that index.

The theme and the app share one generated animation table, so the Plymouth and
QML sides can never drift apart.

## Layout

```
gen.py                     # generates the theme AND the matching app assets
main.cpp                   # DEACTIVATE handshake, KMS read-back, phase injection
CMakeLists.txt             # libdrm is optional (desktop builds no-op the read-back)
qml/
  Main.qml                 # splash + lazy-loaded UI + cross-fade
  GroundControl.qml        # mock satellite ground-control dashboard
  OrbitTrace.js            # generated: the shared orbit table
  images/  fonts/          # generated assets + bundled SIL-OFL fonts
plymouth/
  plymouthd.defaults       # Theme=astra
  themes/astra/            # the generated Plymouth "script" theme
blog.md                    # write-up (Japanese, Zenn)
```

## Run on the desktop

Requires Qt 6.5+ (Quick) and CMake 3.21+.

```sh
cmake -B build && cmake --build build
./build/astra-demo
```

On the desktop there is no Plymouth, so the read-back no-ops and the sweep
starts at phase 0 after a 5 s splash, then cross-fades into the dashboard.

## Run on a device

Tested on a [Toradex Verdin iMX8MP](https://developer.toradex.com/hardware/verdin-som-family/modules/verdin-imx8m-plus/)
running [Torizon OS](https://developer.toradex.com/torizon/) 7 (Qt 6.11,
`eglfs_kms`, 1280×800). What you need:

1. Install `plymouth/themes/astra/` to `/usr/share/plymouth/themes/astra/` and
   ship `plymouthd.defaults` (`Theme=astra`). **The theme must end up inside the
   initramfs** — plymouthd starts from the initrd and loads its theme there, so
   bake it into the OS image build.
2. Cross-build the app and run it with `QT_QPA_PLATFORM=eglfs`. The KMS
   read-back needs DRM master or `CAP_SYS_ADMIN` (root in a privileged
   container is fine); without it the app falls back to phase 0.
3. The app sends DEACTIVATE itself at startup — make sure nothing else quits
   Plymouth before the app is up.

To change the artwork or the animation, edit `gen.py` and re-run it; it
rewrites the theme, the app images, and `OrbitTrace.js` in one go.

## License

[MIT](LICENSE). Bundled fonts
([Jost](https://github.com/indestructible-type/Jost),
[Noto Sans JP](https://fonts.google.com/noto/specimen/Noto+Sans+JP)) are under
the [SIL Open Font License 1.1](qml/fonts/OFL.txt). The Qt logo is a trademark
of [The Qt Company](https://www.qt.io/); it appears here to mark the
Plymouth → Qt hand-off moment in the demo.
