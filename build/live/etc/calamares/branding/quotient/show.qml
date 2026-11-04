// What plays while the files copy: the brand's words on ink, one idea per
// slide, no spinner theatre. Ink band + Jost, Plex Mono eyebrow in accent.
import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation
    Timer { id: advanceTimer; interval: 9000; running: false; repeat: true; onTriggered: presentation.goToNextSlide() }

    component Band: Slide {
        property string eyebrow
        property string title
        property string body
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "#14201A" }
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width * 0.72, 760)
            spacing: 18
            Text { text: eyebrow; color: "#7FD9AE"; font.family: "IBM Plex Mono"; font.pixelSize: 13; font.weight: Font.DemiBold; font.letterSpacing: 2; width: parent.width; horizontalAlignment: Text.AlignHCenter }
            Text { text: title; color: "#FBFAF6"; font.family: "Jost"; font.pixelSize: 40; font.weight: Font.Bold; wrapMode: Text.WordWrap; width: parent.width; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.1 }
            Text { text: body; color: "#E6EEE8"; font.family: "IBM Plex Sans"; font.pixelSize: 18; wrapMode: Text.WordWrap; width: parent.width; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.35; visible: body.length > 0 }
        }
    }

    Band { eyebrow: "SETTING UP YOUR MAINFRAME"; title: "Your data. Your server. Your rules."
           body: "This PC is becoming your Mainframe: the one place your Qfolders live, shared with the people you invite and nobody else." }
    Band { eyebrow: "WHAT HAPPENS NEXT"; title: "Restart, then claim it from your phone."
           body: "When the files are in place the PC restarts and shows a code on its screen. Open the Terminal app, scan the code, and the Mainframe is yours." }
    Band { eyebrow: "NO ACCOUNTS, NO ADS"; title: "Nothing here talks to anyone but you."
           body: "QuotientOS checks for Quotient and security updates. That is the whole list." }

    function onActivate() { advanceTimer.running = true }
    function onLeave() { advanceTimer.running = false }
}
