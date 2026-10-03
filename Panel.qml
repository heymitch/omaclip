import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// omaclip in the bar. Idle: a record mark; click for recent clips and settings.
// Recording: a red dot and the elapsed time; click to stop. Settings are written
// through `omaclip config set`, the same file the command line reads.
Panel {
  id: root
  moduleName: "heymitch.omaclip"
  ipcTarget: "heymitch.omaclip"

  readonly property string home: Quickshell.env("HOME")
  readonly property string omaclip: String(Qt.resolvedUrl("bin/omaclip")).replace("file://", "")
  readonly property string statusPath: home + "/.local/state/omaclip/status.json"
  readonly property string clipsPath: home + "/.local/state/omaclip/clips.jsonl"
  readonly property string configPath: home + "/.config/omaclip/config.json"

  property string status: "idle"
  property real since: 0
  property real now: Date.now() / 1000
  property var config: ({})
  property var recent: []
  property string testResult: ""
  property bool testing: false

  readonly property bool isRecording: status === "recording"
  readonly property bool busy: status === "countdown" || status === "uploading"
  readonly property bool connected: !!config.token && (!!config.server || !!config.uploadUrl)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function elapsed() {
    var s = Math.max(0, Math.floor(root.now - root.since))
    var m = Math.floor(s / 60)
    return m + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }

  function run(args) { Quickshell.execDetached([root.omaclip].concat(args)) }

  function setConfig(key, value) {
    var next = Object.assign({}, root.config)
    next[key] = value
    root.config = next
    run(["config", "set", key, String(value)])
  }

  function refreshConfig() { configProc.running = true }
  function refreshRecent() { recentProc.running = true }

  onOpenedChanged: if (opened) { refreshConfig(); refreshRecent(); testResult = "" }

  // ---------- data ----------

  FileView {
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var s = JSON.parse(text())
        root.status = String(s.status || "idle")
        root.since = Number(s.since || 0)
      } catch (e) { root.status = "idle" }
    }
  }

  FileView {
    path: root.clipsPath
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.refreshRecent() }
  }

  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.refreshConfig() }
  }

  Process {
    id: configProc
    command: [root.omaclip, "config", "get"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: { try { root.config = JSON.parse(text) } catch (e) {} }
    }
  }

  Process {
    id: recentProc
    command: [root.omaclip, "recent", "5"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: { try { root.recent = JSON.parse(text) } catch (e) { root.recent = [] } }
    }
  }

  Process {
    id: testProc
    command: [root.omaclip, "test"]
    stdout: StdioCollector { onStreamFinished: if (text.trim()) root.testResult = text.trim() }
    stderr: StdioCollector { onStreamFinished: if (text.trim()) root.testResult = text.trim() }
    onExited: root.testing = false
  }

  // A recording can also be stopped from Omarchy's own indicator; follow the real process.
  Process {
    id: liveProc
    command: ["pgrep", "--quiet", "-f", "^gpu-screen-recorder"]
    onExited: function(code) {
      if (code !== 0 && root.status === "recording") root.status = "idle"
    }
  }

  Timer {
    interval: 1000
    running: root.isRecording
    repeat: true
    onTriggered: { root.now = Date.now() / 1000; liveProc.running = true }
  }

  // ---------- bar button ----------

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: root.status === "idle" && !root.opened
    tooltipText: root.isRecording ? "Stop recording" : (root.status === "uploading" ? "Uploading…" : "omaclip: record, share, settings")
    onPressed: function() {
      if (root.isRecording) root.run(["stop"])
      else root.toggle()
    }

    Row {
      anchors.centerIn: parent
      spacing: 5
      leftPadding: 6
      rightPadding: 8

      Text {
        text: root.isRecording ? "●" : (root.status === "uploading" ? "󰕒" : (root.status === "countdown" ? "󰔟" : "󰑋"))
        color: root.isRecording ? Color.urgent : Color.bar.text
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.bar.iconFont
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: root.isRecording
        text: root.elapsed()
        color: Color.bar.text
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // ---------- panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    Column {
      id: column
      width: parent.width
      spacing: Style.spacing.md
      padding: Style.spacing.panelPadding
      readonly property real inner: width - Style.spacing.panelPadding * 2

      Item {
        width: column.inner
        height: recordButton.implicitHeight

        Text {
          text: "omaclip"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Button {
          id: recordButton
          anchors.right: parent.right
          iconText: root.isRecording ? "󰓛" : "󰑋"
          text: root.isRecording ? "Stop " + root.elapsed() : "Record"
          bordered: true
          active: root.isRecording
          enabled: !root.busy
          onClicked: {
            root.close()
            root.run([root.isRecording ? "stop" : "start"])
          }
        }
      }

      Text {
        width: column.inner
        visible: !root.connected
        wrapMode: Text.WordWrap
        text: "Not connected to a server yet. Recordings still save locally. Add your server and token below to share links."
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // ----- recent -----
      PanelSectionHeader { width: column.inner; text: "RECENT LINKS" }

      Text {
        visible: root.recent.length === 0
        text: "Shared clips show up here. Click one to copy its link."
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: root.recent

        Rectangle {
          required property var modelData
          width: column.inner
          height: Style.spacing.controlHeight
          radius: Style.cornerRadius
          color: rowHover.containsMouse ? Color.menu.selectedBackground : "transparent"

          MouseArea {
            id: rowHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Quickshell.execDetached(["wl-copy", modelData.url])
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var ts = String(modelData.ts || "")
              var d = Number(modelData.duration || 0)
              var len = Math.floor(d / 60) + ":" + (Math.round(d % 60) < 10 ? "0" : "") + Math.round(d % 60)
              return (ts.length >= 16 ? ts.slice(5, 16).replace("T", " ") : ts) + "   " + len + "   " + modelData.id
            }
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            PanelActionButton { iconText: "󰏌"; tooltipText: "Open"; onClicked: Quickshell.execDetached(["xdg-open", modelData.url]) }
            PanelActionButton { iconText: "󰆴"; tooltipText: "Take down"; onClicked: root.run(["unshare", modelData.id]) }
          }
        }
      }

      // ----- recording -----
      PanelSectionHeader { width: column.inner; text: "RECORDING" }

      Toggle { width: column.inner; label: "Camera bubble"; checked: root.config.camera === true; onClicked: root.setConfig("camera", !checked) }
      Toggle { width: column.inner; label: "Microphone"; checked: root.config.mic === true; onClicked: root.setConfig("mic", !checked) }
      Toggle { width: column.inner; label: "Computer audio"; checked: root.config.desktopAudio === true; onClicked: root.setConfig("desktopAudio", !checked) }
      Toggle { width: column.inner; label: "3-2-1 countdown with mic check"; checked: root.config.countdown === true; onClicked: root.setConfig("countdown", !checked) }

      Row {
        spacing: Style.spacing.lg
        Column {
          spacing: Style.spacing.xs
          Text { text: "Camera corner"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
          ButtonGroup {
            options: [
              { value: "top-left", label: "↖", tooltip: "Top left" }, { value: "top-right", label: "↗", tooltip: "Top right" },
              { value: "bottom-left", label: "↙", tooltip: "Bottom left" }, { value: "bottom-right", label: "↘", tooltip: "Bottom right" }
            ]
            value: String(root.config.cameraCorner || "bottom-left")
            onChanged: function(v) { root.setConfig("cameraCorner", v) }
          }
        }
        Column {
          spacing: Style.spacing.xs
          Text { text: "Camera size"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
          ButtonGroup {
            options: [{ value: "small", label: "S", tooltip: "Small" }, { value: "medium", label: "M", tooltip: "Medium" }, { value: "large", label: "L", tooltip: "Large" }]
            value: String(root.config.cameraSize || "medium")
            onChanged: function(v) { root.setConfig("cameraSize", v) }
          }
        }
        Column {
          spacing: Style.spacing.xs
          Text { text: " "; font.pixelSize: Style.font.caption }
          Button { text: "Preview"; bordered: true; tooltipText: "Show or hide the camera where it will record"; onClicked: root.run(["camera"]) }
        }
      }

      // ----- server -----
      PanelSectionHeader { width: column.inner; text: "SERVER" }

      Text { text: "Clip site (e.g. https://clips.example.com)"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
      TextField {
        width: column.inner
        text: String(root.config.server || "")
        placeholderText: "https://clips.example.com"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        onEditingFinished: if (text !== String(root.config.server || "")) root.setConfig("server", text.trim())
      }

      Text { text: "Upload address (only if it isn't <site>/api/upload, e.g. a Tailscale address)"; width: column.inner; wrapMode: Text.WordWrap; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
      TextField {
        width: column.inner
        text: String(root.config.uploadUrl || "")
        placeholderText: "leave empty to use the clip site"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        onEditingFinished: if (text !== String(root.config.uploadUrl || "")) root.setConfig("uploadUrl", text.trim())
      }

      Text { text: "Upload token (printed by the server installer)"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
      TextField {
        width: column.inner
        password: true
        text: String(root.config.token || "")
        placeholderText: "token"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        onEditingFinished: if (text !== String(root.config.token || "")) root.setConfig("token", text.trim())
      }

      Row {
        spacing: Style.spacing.md
        Button {
          text: root.testing ? "Testing…" : "Test connection"
          bordered: true
          enabled: !root.testing
          onClicked: { root.testing = true; root.testResult = ""; testProc.running = true }
        }
        Text {
          width: column.inner - x
          anchors.verticalCenter: parent.verticalCenter
          text: root.testResult
          wrapMode: Text.WordWrap
          color: root.testResult.indexOf("Connected") === 0 ? Color.foreground : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
