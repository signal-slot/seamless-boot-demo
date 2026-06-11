import QtQuick
import QtQuick.Window

import "OrbitTrace.js" as Orbit

// Entry window: draws the Plymouth-matching splash immediately (cheap first
// frame), continues the satellite sweep from where Plymouth froze, and
// lazy-loads the dashboard behind it. The transition is not a plain
// cross-fade: the full-screen orbit scene (planet + orbit + sweeping
// satellite) SHRINKS into the dashboard's ORBIT TRACK card, and the Qt logo
// glides into the header, while only the background layers cross-fade.
Window {
    id: win
    width: 1280
    height: 800
    visible: true
    title: qsTr("ASTRA Ground Control")
    color: "#0a0e1a"

    // Orbit index (0..239) where the Plymouth splash froze, decoded by
    // main.cpp from the KMS framebuffer (the theme embeds it as a
    // near-invisible position marker). -1 = unknown -> sweep starts at 0.
    property int satStartIndex: -1

    // Once the dashboard is loaded the hero elements glide to their
    // dashboard geometry (orbit scene -> ORBIT TRACK card, logo -> header).
    property bool docked: false

    // The device runtime ships no fonts at all — embed our own (SIL-OFL).
    FontLoader { source: "fonts/Jost-Regular.ttf" }
    FontLoader { source: "fonts/Jost-Medium.ttf" }
    FontLoader { source: "fonts/NotoSansJP-VariableFont_wght.ttf" }

    Loader {
        id: ui
        anchors.fill: parent
        asynchronous: true
        active: false                  // starts loading after the splash delay
        source: "GroundControl.qml"
        opacity: 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 600 } }
        onLoaded: opacity = 1
    }

    // Splash background: stars + texts only — the planet/orbit live in the
    // hero element below (splashbg ⊕ map is pixel-identical to the Plymouth
    // theme background, so the boot hand-off stays seamless).
    Item {
        id: splash
        anchors.fill: parent
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 600 } }

        Image {
            anchors.fill: parent
            source: "images/splashbg.png"
            smooth: true
        }
    }

    // HERO: the orbit scene. Full-screen during the splash; on dock it
    // shrinks into the ORBIT TRACK card's map area (card at 20,64, map inset
    // 16 left/right/bottom and 40 top -> 36,104 568x364). All contents are
    // laid out in 1280x800 design units scaled by sx/sy, so the satellite
    // keeps sweeping while the whole scene shrinks.
    Item {
        id: heroOrbit
        x: win.docked ? 36 : 0
        y: win.docked ? 104 : 0
        width: win.docked ? 568 : win.width
        height: win.docked ? 364 : win.height
        Behavior on x      { NumberAnimation { duration: 600; easing.type: Easing.InOutCubic } }
        Behavior on y      { NumberAnimation { duration: 600; easing.type: Easing.InOutCubic } }
        Behavior on width  { NumberAnimation { duration: 600; easing.type: Easing.InOutCubic } }
        Behavior on height { NumberAnimation { duration: 600; easing.type: Easing.InOutCubic } }

        readonly property real sx: width / 1280
        readonly property real sy: height / 800
        readonly property int startIdx: win.satStartIndex >= 0 ? win.satStartIndex : 0
        property real head: 0
        NumberAnimation on head {
            from: 0; to: Orbit.n; duration: 2200
            loops: Animation.Infinite; running: true
        }

        Image {
            anchors.fill: parent
            source: "images/map.png"
            smooth: true
        }
        Repeater {
            model: 6   // head + fading tail, exactly like the Plymouth theme
            Image {
                source: "images/sat.png"
                readonly property int idx:
                    ((Math.floor(heroOrbit.head) + heroOrbit.startIdx - index * 3) % Orbit.n + Orbit.n) % Orbit.n
                width: 72 * heroOrbit.sx
                height: 72 * heroOrbit.sy
                x: Orbit.tx[idx] * heroOrbit.sx - width / 2
                y: Orbit.ty[idx] * heroOrbit.sy - height / 2
                opacity: (1.0 - index / 6) * (1.0 - index / 6)
                smooth: true
            }
        }
    }

    // Qt logo, top-left — fades in when the Qt-side splash starts (making the
    // Plymouth -> Qt hand-off moment visible), then glides to the dashboard
    // header position. GroundControl draws no logo of its own.
    Image {
        id: heroLogo
        source: "images/qtlogo.png"
        x: win.docked ? 20 : 24
        y: win.docked ? 14 : 24
        width: win.docked ? 49 : 76
        height: win.docked ? 36 : 56
        smooth: true
        opacity: 0
        NumberAnimation on opacity { from: 0; to: 1; duration: 800; running: true }
        Behavior on x      { NumberAnimation { duration: 600; easing.type: Easing.InOutCubic } }
        Behavior on y      { NumberAnimation { duration: 600; easing.type: Easing.InOutCubic } }
        Behavior on width  { NumberAnimation { duration: 600; easing.type: Easing.InOutCubic } }
        Behavior on height { NumberAnimation { duration: 600; easing.type: Easing.InOutCubic } }
    }

    // Hold the splash briefly, then load the dashboard; on load, dock the
    // hero elements while the background layers cross-fade.
    Timer {
        interval: 5000
        running: true
        repeat: false
        onTriggered: ui.active = true
    }
    Connections {
        target: ui
        function onLoaded() {
            splash.opacity = 0
            win.docked = true
        }
    }
}
