import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Surface Pro 12 NFC reader: chimes and shows a card with what the reader
// read. Reads come from the sp12-nfc daemon (sp12-nfc.service) over
// /run/sp12-nfc/events, one JSON object per line.
//
// The card sits at the top left, next to the antenna (behind the top-left
// corner of the screen). It closes on click or after `duration`.
//
//   omarchy-shell nfc show '<event json>'   show a read (sp12-nfc demo uses it)
//   omarchy-shell nfc close
//   omarchy-shell nfc last                  the last read, as JSON
//   omarchy-shell nfc state                 reader: polling / idle / offline
Item {
  id: root

  property var shell: null

  // Settings. The shell reloads this file on save.
  property string sound: "/usr/share/sounds/freedesktop/stereo/complete.oga"
  property int duration: 8000          // ms before the card closes; 0 keeps it up
  property string socketPath: "/run/sp12-nfc/events"
  property int maxLines: 4

  property bool opened: false
  property var read: ({})
  property string readerState: "offline"
  property string lastJson: ""

  readonly property var glyphs: ({
    "payment": "󰆛",   // credit card
    "tag": "󰓹",       // tag
    "peer": "󰄜",      // cellphone
    "felica": "󰆛",
    "iso15693": "󰓹",
    "mifare": "󰆛",
    "type1": "󰓹"
  })
  readonly property string defaultGlyph: "󰏒"   // nfc
  readonly property string icon: (read.random_uid && read.kind !== "payment") ? glyphs.peer
    : (glyphs[read.kind] || defaultGlyph)
  readonly property string title: String(read.title || "NFC")
  readonly property string subtitle: {
    var parts = []
    if (read.tech) parts.push(String(read.tech))
    if (read.uid) parts.push(read.random_uid ? "random id " + read.uid : "uid " + read.uid)
    return parts.join("  ·  ")
  }
  readonly property var lines: {
    var l = Array.isArray(read.lines) ? read.lines.slice(0, root.maxLines) : []
    if (Array.isArray(read.lines) && read.lines.length > root.maxLines)
      l.push("… " + (read.lines.length - root.maxLines) + " more")
    return l
  }

  // Clear the bar the way the notification popups do (live size, or the
  // default when the bar object isn't reachable).
  readonly property string barPosition: shell && shell.barConfig ? String(shell.barConfig.position || "top") : "top"
  readonly property int defaultBarSize: (barPosition === "left" || barPosition === "right") ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  readonly property int liveBarSize: shell && shell.bar && !shell.bar.barHidden ? Math.max(0, shell.bar.barSize) : defaultBarSize
  readonly property int topClearance: (barPosition === "top" ? liveBarSize : 0) + Style.gapsOut
  readonly property int leftClearance: (barPosition === "left" ? liveBarSize : 0) + Style.gapsOut

  readonly property int pad: Style.space(14)
  readonly property int gap: Style.space(12)
  readonly property int cardWidth: Style.space(360)

  function handle(line) {
    var ev
    try { ev = JSON.parse(line) } catch (e) { return }
    if (!ev || typeof ev !== "object") return
    if (ev.event === "reader") {
      root.readerState = ev.state === "polling" ? "polling" : (ev.state || "idle")
      return
    }
    if (ev.event === "card") root.show(ev)
  }

  function show(ev) {
    root.read = ev
    root.lastJson = JSON.stringify(ev)
    root.opened = true
    if (root.duration > 0) hideTimer.restart()
    else hideTimer.stop()
    root.chime()
  }

  function close() { root.opened = false }

  function chime() {
    if (root.sound === "") return
    chimeProc.running = false
    chimeProc.command = ["pw-play", root.sound]
    chimeProc.running = true
  }

  Process { id: chimeProc }

  Timer {
    id: hideTimer
    interval: root.duration
    onTriggered: root.opened = false
  }

  // The daemon starts with the device; keep trying until it's there, and
  // reconnect when it restarts.
  Socket {
    id: sock
    path: root.socketPath
    connected: true
    parser: SplitParser {
      onRead: data => root.handle(data)
    }
    onConnectionStateChanged: {
      if (!sock.connected) {
        root.readerState = "offline"
        retry.restart()
      }
    }
    onError: retry.restart()
  }

  Timer {
    id: retry
    interval: 3000
    onTriggered: {
      if (sock.connected) return
      // Assigning true again after a failed attempt is a no-op: toggle.
      sock.connected = false
      sock.connected = true
    }
  }

  IpcHandler {
    target: "nfc"
    function show(payloadJson: string): string {
      try {
        var ev = JSON.parse(payloadJson || "{}")
        ev.event = "card"
        root.show(ev)
        return "ok"
      } catch (e) {
        return "bad json"
      }
    }
    function close(): string { root.close(); return "ok" }
    function last(): string { return root.lastJson }
    function state(): string { return root.readerState }
    function ping(): string { return "ok" }
    function debug(): string {
      return JSON.stringify({ top: root.topClearance, left: root.leftClearance, bar: root.liveBarSize,
                              shell: !!root.shell, hasBar: !!(root.shell && root.shell.bar),
                              gaps: Style.gapsOut, def: root.defaultBarSize })
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; left: true }
    margins { top: root.topClearance; left: root.leftClearance }
    implicitWidth: card.width
    implicitHeight: card.height
    color: "transparent"
    WlrLayershell.namespace: "sp12-nfc"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    BorderSurface {
      id: card
      width: root.cardWidth
      height: card.borderTop + root.pad + content.height + root.pad + card.borderBottom
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.close()
      }

      Row {
        id: content
        x: card.borderLeft + root.pad
        y: card.borderTop + root.pad
        width: card.width - card.borderLeft - card.borderRight - 2 * root.pad
        spacing: root.gap

        Text {
          id: iconText
          textFormat: Text.PlainText
          text: root.icon
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
          color: Color.popups.border
          anchors.top: parent.top
          anchors.topMargin: -Math.round(Style.font.displayLarge * 0.08)
        }

        Column {
          width: content.width - iconText.width - root.gap
          spacing: Style.spacing.xs

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.title
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
            color: Color.popups.text
            elide: Text.ElideRight
            maximumLineCount: 1
          }

          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: root.subtitle
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: Util.alpha(Color.popups.text, 0.7)
            elide: Text.ElideRight
            maximumLineCount: 1
          }

          Item { width: 1; height: root.lines.length > 0 ? Style.spacing.sm : 0 }

          Repeater {
            model: root.lines
            delegate: Text {
              required property string modelData
              width: parent.width
              textFormat: Text.PlainText
              text: modelData
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              color: Color.popups.text
              elide: Text.ElideRight
              wrapMode: Text.NoWrap
              maximumLineCount: 1
            }
          }
        }
      }
    }
  }
}
