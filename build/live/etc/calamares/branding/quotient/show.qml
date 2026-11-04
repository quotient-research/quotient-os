import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation
    Timer { interval: 8000; running: false; repeat: true; onTriggered: presentation.goToNextSlide() ; id: advanceTimer }
    Slide {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "#0E1110" }
        Text { anchors.centerIn: parent; color: "#ECEFED"; font.pixelSize: 36; font.bold: true
               horizontalAlignment: Text.AlignHCenter
               text: "Your data. Your server. Your rules." }
    }
    Slide {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "#0E1110" }
        Text { anchors.centerIn: parent; color: "#ECEFED"; font.pixelSize: 28; width: parent.width * 0.7; wrapMode: Text.WordWrap
               horizontalAlignment: Text.AlignHCenter
               text: "When this finishes, the PC restarts as your Mainframe. Open the Terminal app on your phone and scan the code on its screen to claim it." }
    }
    function onActivate() { advanceTimer.running = true }
    function onLeave() { advanceTimer.running = false }
}
