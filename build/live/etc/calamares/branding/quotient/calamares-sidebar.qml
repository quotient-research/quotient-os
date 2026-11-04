// The window's title bar (kit TitleBar): green, 2px ink bottom border, the Q
// mark, a Plex Mono uppercase label, and the steps with the current one in a
// white box. Shown across the top (branding.desc: sidebar: qml,top).
import io.calamares.ui 1.0
import io.calamares.core 1.0
import QtQuick 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: titleBar
    color: "#2FCF87"
    height: 56
    Layout.fillWidth: true

    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: "#14201A" }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        anchors.bottomMargin: 2
        spacing: 14

        Image {
            source: "file://" + Branding.imagePath(Branding.ProductLogo)
            sourceSize.width: 30; sourceSize.height: 30
            Layout.preferredWidth: 30; Layout.preferredHeight: 30
        }
        Text {
            text: "QUOTIENT MAINFRAME · SET UP"
            font.family: "IBM Plex Mono"; font.pixelSize: 13; font.weight: Font.DemiBold; font.letterSpacing: 1.6
            color: "#14201A"
        }
        Item { Layout.fillWidth: true }
        Row {
            spacing: 6
            Repeater {
                model: ViewManager
                Rectangle {
                    property bool current: index === ViewManager.currentStepIndex
                    property bool done: index < ViewManager.currentStepIndex
                    height: 26
                    width: label.implicitWidth + 18
                    radius: 4
                    color: current ? "#FFFFFF" : "transparent"
                    border.width: current ? 2 : 0
                    border.color: "#14201A"
                    Text {
                        id: label
                        anchors.centerIn: parent
                        text: display
                        font.family: "IBM Plex Mono"; font.pixelSize: 12; font.weight: current ? Font.DemiBold : Font.Normal
                        color: done ? "#145739" : "#14201A"
                        opacity: (current || done) ? 1 : 0.7
                    }
                }
            }
        }
    }
}
