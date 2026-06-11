import QtQuick

import "OrbitTrace.js" as Orbit

// Mock satellite ground-control dashboard ("ハリボテ"): everything animates on
// fake data so the demo looks alive on video, but nothing is real.
Rectangle {
    id: root
    color: "#0b101e"

    readonly property color accent: "#4dd0e1"
    readonly property color dim: "#8a93a8"
    readonly property color cardBg: "#121a2e"

    component Card: Rectangle {
        property alias title: titleText.text
        color: root.cardBg
        radius: 10
        border.color: "#1e2a47"
        border.width: 1
        Text {
            id: titleText
            x: 16; y: 12
            color: root.dim
            font.pixelSize: 13
            font.letterSpacing: 2
        }
    }

    // header --------------------------------------------------------------
    Item {
        id: header
        width: parent.width; height: 64
        // The Qt logo here is the hero element owned by Main.qml — it glides
        // from the splash into this spot (x:20 y:14 49x36) during the
        // cross-fade, so this header draws no logo of its own.
        Text {
            id: title
            x: 84; anchors.verticalCenter: parent.verticalCenter
            text: "ASTRA GROUND CONTROL"
            color: "white"; font.pixelSize: 20; font.letterSpacing: 4
            font.family: "Jost"
        }
        Text {
            anchors.left: title.right; anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: "衛星地上管制"
            color: root.dim; font.pixelSize: 14
            font.family: "Noto Sans JP"
        }
        Rectangle {
            x: 530; anchors.verticalCenter: parent.verticalCenter
            width: 110; height: 26; radius: 13
            color: "#10331f"; border.color: "#2e7d4f"
            Row {
                anchors.centerIn: parent; spacing: 6
                Rectangle {
                    width: 8; height: 8; radius: 4; color: "#46d97e"
                    anchors.verticalCenter: parent.verticalCenter
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        NumberAnimation { from: 1; to: 0.3; duration: 700 }
                        NumberAnimation { from: 0.3; to: 1; duration: 700 }
                    }
                }
                Text { text: "UPLINK OK"; color: "#9fe8bc"; font.pixelSize: 12; font.letterSpacing: 1 }
            }
        }
        Text {
            id: clock
            anchors.right: parent.right; anchors.rightMargin: 24
            anchors.verticalCenter: parent.verticalCenter
            color: root.dim; font.pixelSize: 16; font.family: "Jost"
            property int t: 49500   // fake mission clock, seconds
            text: "MET " + Math.floor(t / 3600) + ":" +
                  String(Math.floor(t / 60) % 60).padStart(2, "0") + ":" +
                  String(t % 60).padStart(2, "0")
            Timer { interval: 1000; running: true; repeat: true; onTriggered: clock.t++ }
        }
    }

    // orbit track ----------------------------------------------------------
    Card {
        id: track
        title: "ORBIT TRACK"
        x: 20; y: header.height
        width: 600; height: 420

        // The orbit scene (planet + orbit + sweeping satellite) is the hero
        // element owned by Main.qml: it shrinks from full screen into this
        // card's map area (inset 16/40) during the transition and lives there
        // afterwards — the card itself draws only the frame and the captions.
        Text {
            anchors.bottom: parent.bottom; anchors.left: parent.left
            anchors.margins: 14
            color: root.dim; font.pixelSize: 12; font.family: "Jost"
            text: "ALT 547.2 km   INC 97.6°   PERIOD 95.4 min"
        }
    }

    // telemetry tiles -------------------------------------------------------
    Card {
        id: sig
        title: "SIGNAL"
        x: 640; y: header.height
        width: 295; height: 200
        Item {
            anchors.fill: parent; anchors.margins: 16; anchors.topMargin: 40
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom; anchors.bottomMargin: 28
                spacing: 10
                Repeater {
                    model: 5
                    Rectangle {
                        id: bar
                        width: 22
                        height: 24 + barH
                        radius: 3
                        anchors.bottom: parent.bottom
                        color: index < 4 ? root.accent : "#27425c"
                        property real barH: 14 * index
                        Behavior on height { NumberAnimation { duration: 400 } }
                        Timer {
                            interval: 900 + index * 130; running: true; repeat: true
                            onTriggered: bar.barH = 12 * index + Math.random() * 20
                        }
                    }
                }
            }
            Text {
                id: rssi
                anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                color: "white"; font.pixelSize: 15; font.family: "Jost"
                property real db: -92.4
                text: "S-BAND  " + db.toFixed(1) + " dBm"
                Timer {
                    interval: 1200; running: true; repeat: true
                    onTriggered: rssi.db = Math.max(-97, Math.min(-88, rssi.db + (Math.random() - 0.5)))
                }
            }
        }
    }

    Card {
        id: pwr
        title: "POWER"
        x: 945; y: header.height
        width: 315; height: 200
        Text {
            id: pwrVal
            anchors.centerIn: parent
            color: "white"; font.pixelSize: 42
            property real v: 87.3
            text: v.toFixed(1) + "%"
            Timer {
                interval: 1500; running: true; repeat: true
                onTriggered: pwrVal.v = Math.max(82, Math.min(93, pwrVal.v + (Math.random() - 0.45)))
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom; anchors.bottomMargin: 18
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40; height: 8; radius: 4; color: "#1c2742"
            Rectangle {
                width: parent.width * pwrVal.v / 100; height: parent.height; radius: 4
                color: "#46d97e"
                Behavior on width { NumberAnimation { duration: 600 } }
            }
        }
        Text {
            x: 16; anchors.bottom: parent.bottom; anchors.bottomMargin: 34
            color: root.dim; font.pixelSize: 12; font.family: "Jost"
            text: "BUS 28.1 V   SOLAR 412 W"
        }
    }

    Card {
        id: att
        title: "ATTITUDE"
        x: 640; y: header.height + 220
        width: 295; height: 200
        Column {
            anchors.centerIn: parent
            spacing: 10
            Repeater {
                model: [["ROLL", 0.42], ["PITCH", -1.18], ["YAW", 2.07]]
                Row {
                    spacing: 14
                    Text {
                        text: modelData[0]; color: root.dim
                        font.pixelSize: 14; font.family: "Jost"; width: 64
                    }
                    Text {
                        id: axis
                        property real v: modelData[1]
                        text: (v >= 0 ? "+" : "") + v.toFixed(2) + "°"
                        color: "white"; font.pixelSize: 18; font.family: "Jost"
                        Timer {
                            interval: 800 + index * 170; running: true; repeat: true
                            onTriggered: axis.v += (Math.random() - 0.5) * 0.06
                        }
                    }
                }
            }
        }
    }

    Card {
        id: thermal
        title: "THERMAL"
        x: 945; y: header.height + 220
        width: 315; height: 200
        Text {
            id: tempVal
            anchors.centerIn: parent
            color: "white"; font.pixelSize: 42
            property real v: 21.6
            text: v.toFixed(1) + " °C"
            Timer {
                interval: 1300; running: true; repeat: true
                onTriggered: tempVal.v = Math.max(18, Math.min(26, tempVal.v + (Math.random() - 0.5) * 0.4))
            }
        }
        Text {
            x: 16; anchors.bottom: parent.bottom; anchors.bottomMargin: 14
            color: root.dim; font.pixelSize: 12; font.family: "Jost"
            text: "RADIATOR OK   HEATER OFF"
        }
    }

    // event log --------------------------------------------------------------
    Card {
        id: log
        title: "EVENT LOG"
        x: 20; y: header.height + 440
        width: 1240; height: 270

        ListModel { id: logModel }
        property int seq: 4821
        readonly property var lines: [
            "TLM frame %1 received (247 bytes, CRC OK)",
            "GS pass AOS in 00:12:%1",
            "Reaction wheel #2 speed trim: %1 rpm",
            "Payload imager idle (next window %1 min)",
            "テレメトリ受信 OK (フレーム %1)",
            "次のパスまで %1 分 — 地上局: 仙台",
            "Battery charge mode: taper (%1 mA)",
            "Star tracker lock: 14 stars, q=0.99%1"
        ]
        Timer {
            interval: 900; running: true; repeat: true
            onTriggered: {
                log.seq++
                const tpl = log.lines[Math.floor(Math.random() * log.lines.length)]
                const arg = log.seq % 2 ? log.seq : Math.floor(Math.random() * 60)
                logModel.append({ line: "[" + clock.text.substring(4) + "]  " + tpl.arg(arg) })
                if (logModel.count > 64)
                    logModel.remove(0)
                logView.positionViewAtEnd()
            }
        }
        ListView {
            id: logView
            anchors.fill: parent
            anchors.margins: 16
            anchors.topMargin: 40
            clip: true
            model: logModel
            delegate: Text {
                required property string line
                text: line
                color: "#a8e6ef"
                font.pixelSize: 14
                font.family: "Jost"
            }
        }
    }
}
