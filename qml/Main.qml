import QtQuick
import QtQuick.Window

import "OrbitTrace.js" as Orbit

// Entry window: draws the Plymouth-matching splash immediately (cheap first
// frame), continues the satellite sweep from where Plymouth froze, and
// lazy-loads the dashboard behind it, cross-fading once it is ready.
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
        Behavior on opacity { NumberAnimation { duration: 450 } }
        onLoaded: opacity = 1
    }

    Item {
        id: splash
        anchors.fill: parent
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 450 } }

        Image {
            anchors.fill: parent
            source: "images/splashbg.png"
            smooth: true
        }

        // Satellite sweep — the same baked orbit table the Plymouth theme uses
        // (qml/OrbitTrace.js is emitted by gen.py next to the theme), with a
        // 6-dot fading tail, continuing from the decoded start index.
        Item {
            id: orbit
            anchors.fill: parent
            readonly property real sx: width / 1280
            readonly property real sy: height / 800
            readonly property int startIdx: win.satStartIndex >= 0 ? win.satStartIndex : 0
            property real head: 0
            NumberAnimation on head {
                from: 0; to: Orbit.n; duration: 2200
                loops: Animation.Infinite; running: true
            }
            Repeater {
                model: 6
                Image {
                    source: "images/sat.png"
                    readonly property int idx:
                        ((Math.floor(orbit.head) + orbit.startIdx - index * 3) % Orbit.n + Orbit.n) % Orbit.n
                    width: 72 * orbit.sx
                    height: 72 * orbit.sy
                    x: Orbit.tx[idx] * orbit.sx - width / 2
                    y: Orbit.ty[idx] * orbit.sy - height / 2
                    opacity: (1.0 - index / 6) * (1.0 - index / 6)
                    smooth: true
                }
            }
        }

    }

    // Qt logo, top-left — a single "hero" element shared by the splash and the
    // dashboard. It fades in when the Qt-side splash starts (making the
    // Plymouth -> Qt hand-off moment visible), then GLIDES from its splash
    // geometry to the dashboard-header geometry while the layers cross-fade
    // underneath. GroundControl.qml draws no logo of its own.
    Image {
        id: heroLogo
        source: "images/qtlogo.png"
        x: 24
        y: 24
        width: 76
        height: 56
        smooth: true
        opacity: 0
        NumberAnimation on opacity { from: 0; to: 1; duration: 800; running: true }
        Behavior on x      { NumberAnimation { duration: 450; easing.type: Easing.InOutCubic } }
        Behavior on y      { NumberAnimation { duration: 450; easing.type: Easing.InOutCubic } }
        Behavior on width  { NumberAnimation { duration: 450; easing.type: Easing.InOutCubic } }
        Behavior on height { NumberAnimation { duration: 450; easing.type: Easing.InOutCubic } }
    }

    // Hold the splash briefly, then load the dashboard and cross-fade while
    // the hero logo glides to its header position.
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
            heroLogo.x = 20
            heroLogo.y = 14
            heroLogo.width = 49
            heroLogo.height = 36
        }
    }
}
