import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Mobile hotspot panel (io.github.shivamnarkar47.omarchy-hotspot), modeled on omarchy.network:
// a bar button that opens a keyboard-navigable popup with a hero toggle,
// a scannable QR code, and live connection details. The AP runs on a
// virtual interface (ap0) served by wpa_supplicant + dnsmasq via
// omarchy-hotspot-helper, so the station connection stays up the whole
// time. QR payload: WIFI:T:WPA;S:OmarchyHotspot;P:<password>;; rendered
// from the same 0/1 matrix format as omarchy.wifiqr.
Panel {
  id: root
  moduleName: "io.github.shivamnarkar47.omarchy-hotspot"
  ipcTarget: "io.github.shivamnarkar47.omarchy-hotspot"

  readonly property string helper: "/usr/local/bin/omarchy-hotspot-helper"
  readonly property string qrScript: decodeURIComponent(String(Qt.resolvedUrl("qr.sh")).replace(/^file:\/\//, ""))
  readonly property string hotspotSsid: "OmarchyHotspot"
  readonly property string passwordFile: "/var/lib/omarchy-hotspot/password"

  // "off" | "on" | "busy" | "error"
  property string hotspotState: "off"
  property string hotspotPassword: ""
  property string hotspotUplink: ""
  property string hotspotChannel: ""
  property string hotspotClients: ""
  property string lastError: ""

  // Password editing state.
  property bool editingPassword: false
  property string passwordDraft: ""
  property bool passwordBusy: false
  property string passwordError: ""
  property string pendingPassword: ""

  property var qrRows: []
  property int qrSize: 0
  property bool qrLoading: false

  readonly property string iconText: "󰀃"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property bool isOn: hotspotState === "on"
  readonly property bool isBusy: hotspotState === "busy"
  readonly property bool isError: hotspotState === "error"
  readonly property bool showingQr: qrSize > 0 && !qrLoading && !isError

  // Copy feedback: icon flips to a checkmark briefly.
  property bool copyFlash: false

  // Cursor: "hero" (toggle switch) | "actions" (copy password, refresh QR)
  property bool cursorActive: false
  property string focusSection: "hero"
  property int actionIndex: 0
  readonly property int actionCount: 3  // copy password, refresh QR, edit password

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function close() {
    root.controller.hide()
  }

  function refresh() {
    if (statusProc.running) return
    // pkexec (passwordless via polkit rule): channel + client counts need root.
    statusProc.command = ["bash", "-c", "pkexec " + root.helper + " status"]
    statusProc.running = true
  }

  function toggle() {
    if (toggleProc.running) return
    hotspotState = "busy"
    lastError = ""
    toggleProc.command = ["bash", "-c", "pkexec " + root.helper + " toggle"]
    toggleProc.running = true
  }

  function generateQr() {
    if (qrProc.running || !isOn) return
    qrLoading = true
    qrProc.command = ["bash", root.qrScript]
    qrProc.running = true
  }

  function applyStatus(raw) {
    var parts = String(raw || "").trim().split(/\s+/)
    if (parts[0] === "on") {
      hotspotState = "on"
      hotspotPassword = parts[2] || ""
      hotspotUplink = parts[3] || ""
      hotspotChannel = parts[4] || ""
      hotspotClients = parts[5] || ""
      if (qrSize === 0 && !qrProc.running) Qt.callLater(generateQr)
    } else {
      hotspotState = "off"
      hotspotUplink = ""
      hotspotChannel = ""
      hotspotClients = ""
    }
  }

  function applyQr(raw) {
    var lines = String(raw || "").trim().split(/\r?\n/).filter(function(l) { return l !== "" })
    // Drop the meta line if present (kept for parity with omarchy-network-qr).
    if (lines.length > 0 && lines[0].indexOf("meta\t") === 0) lines.shift()
    if (lines.length < 2) return
    var size = lines[0].length
    if (size !== lines.length) return
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].length !== size || !/^[01]+$/.test(lines[i])) return
    }
    qrRows = lines
    qrSize = size
    qrLoading = false
  }

  function copyPassword() {
    if (!root.bar || !hotspotPassword) return
    // Copy from the secret file (user-readable, 600) so the password never
    // appears in a process command line.
    Quickshell.execDetached(["bash", "-c", "cat " + root.passwordFile + " | wl-copy"])
    // Flash the copy icon to a checkmark so the click is visibly acknowledged.
    copyFlash = true
    copyFlashTimer.restart()
  }

  function startPasswordEdit() {
    if (passwordBusy) return
    passwordDraft = hotspotPassword || ""
    passwordError = ""
    editingPassword = true
    Qt.callLater(function() { if (passwordField) passwordField.forceActiveFocus() })
  }

  function cancelPasswordEdit() {
    editingPassword = false
    passwordDraft = ""
    passwordError = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function savePassword() {
    if (passwordBusy) return
    var draft = passwordDraft.trim()
    if (draft.length < 8) { passwordError = "Minimum 8 characters"; return }
    if (draft.length > 63) { passwordError = "Maximum 63 characters"; return }
    passwordBusy = true
    passwordError = ""
    // Feed the passphrase over stdin (not argv) so it is never exposed in the
    // process command line. The helper reads it from stdin.
    pendingPassword = draft
    passProc.command = ["bash", "-c", "pkexec " + root.helper + " set-password"]
    passProc.running = true
  }

  function statusLine() {
    if (isOn) {
      var line = "ON · CH " + (hotspotChannel || "—") + " · " + (hotspotClients ? hotspotClients + " DEVICE" + (hotspotClients === "1" ? "" : "S") : "NO CLIENTS")
      if (hotspotUplink) line += " · VIA " + hotspotUplink
      return line
    }
    if (isBusy) return "…"
    if (isError) return "ERROR"
    return "OFF"
  }

  function headerDetail() {
    if (isOn) return "Sharing " + (hotspotUplink || "this connection")
    if (isError) return lastError
    return "Wi-Fi stays connected"
  }

  // ---- Cursor navigation ------------------------------------------------
  function moveCursor(dy) {
    if (!cursorActive) { cursorActive = true; return }
    if (dy < 0 && focusSection === "actions") focusSection = "hero"
    else if (dy > 0 && focusSection === "hero") { focusSection = "actions"; actionIndex = 0 }
  }

  function activate() {
    if (!cursorActive) return
    if (focusSection === "hero") toggle()
    else if (actionIndex === 0) copyPassword()
    else if (actionIndex === 1) generateQr()
    else if (actionIndex === 2) startPasswordEdit()
  }

  function setSection(section, index) {
    cursorActive = true
    focusSection = section
    actionIndex = index === undefined ? 0 : index
  }

  readonly property bool heroHasCursor: cursorActive && focusSection === "hero"
  readonly property bool copyHasCursor: cursorActive && focusSection === "actions" && actionIndex === 0
  readonly property bool qrHasCursor: cursorActive && focusSection === "actions" && actionIndex === 1
  readonly property bool editHasCursor: cursorActive && focusSection === "actions" && actionIndex === 2

  // ---- Processes --------------------------------------------------------
  Process {
    id: statusProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    onExited: function(code) {
      if (code !== 0 && hotspotState !== "busy") hotspotState = "error"
    }
  }

  Process {
    id: toggleProc
    stdout: StdioCollector { id: toggleOut; waitForEnd: true }
    stderr: StdioCollector { id: toggleErr; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        var detail = String(toggleErr.text || toggleOut.text || "").replace(/\s+/g, " ").trim()
        root.lastError = detail ? detail.slice(0, 120) : ("exit " + code)
        root.hotspotState = "error"
      }
      Qt.callLater(function() {
        root.refresh()
        if (root.isOn) root.generateQr()
      })
    }
  }

  Process {
    id: qrProc
    stdout: StdioCollector { id: qrOut; waitForEnd: true; onStreamFinished: root.applyQr(text) }
    stderr: StdioCollector { id: qrErr; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) root.lastError = String(qrErr.text || "").trim().slice(0, 120) || ("QR failed: exit " + code)
      qrLoading = false
    }
  }

  Process {
    id: passProc
    stdinEnabled: true
    stdout: StdioCollector { id: passOut; waitForEnd: true }
    stderr: StdioCollector { id: passErr; waitForEnd: true }
    onStarted: function() {
      // Send the passphrase as a single line (newline-terminated); the helper
      // reads one line, so we never need to close stdin.
      passProc.write(root.pendingPassword + "\n")
    }
    onExited: function(code) {
      passwordBusy = false
      if (code !== 0) {
        passwordError = String(passErr.text || passOut.text || "").replace(/\s+/g, " ").trim().slice(0, 120) || ("exit " + code)
        return
      }
      editingPassword = false
      passwordDraft = ""
      root.refresh()
      if (root.isOn) root.generateQr()
    }
  }

  Timer {
    id: copyFlashTimer
    interval: 1200
    repeat: false
    onTriggered: root.copyFlash = false
  }

  Timer {
    interval: 4000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      if (isOn) generateQr()
      cursorActive = false
      focusSection = "hero"
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }

  onHotspotStateChanged: {
    if (isOn && qrSize === 0 && opened) Qt.callLater(generateQr)
  }

  // ---- Bar button -------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    active: root.isOn
    tooltipText: root.isOn
      ? ("Hotspot on: " + root.hotspotSsid + " · " + (root.hotspotPassword || "—"))
      : "Mobile hotspot: share this connection (Wi-Fi stays on)"

    onPressed: function(btn) {
      if (btn !== Qt.LeftButton) return
      if (root.opened) root.close()
      else root.open()
    }
  }

  // ---- Popup ------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingPassword || root.passwordBusy

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        if (dx !== 0 && root.focusSection === "actions") {
          root.actionIndex = Math.max(0, Math.min(root.actionCount - 1, root.actionIndex + (dx > 0 ? 1 : -1)))
        }
      }
      onActivateRequested: root.activate()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      // ---------- Hero: icon · name + state · toggle ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

        Text {
          id: heroIcon
          text: root.iconText
          color: root.isOn ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        RowLayout {
          id: heroActions
          spacing: Style.space(8)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter

          ToggleSwitch {
            id: powerSwitch
            checked: root.isOn
            busy: root.isBusy
            hasCursor: root.heroHasCursor
            foreground: root.foreground
            Layout.alignment: Qt.AlignVCenter
            onHovered: function(on) { if (on) root.setSection("hero") }
            onToggled: root.toggle()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.isOn ? "Turn hotspot off" : "Turn hotspot on"
              fontFamily: root.fontFamily
            }
          }
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
          anchors.rightMargin: heroActions.width > 0 ? heroActions.width + Style.space(12) : 0
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: root.hotspotSsid
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: root.statusLine()
            textFormat: Text.PlainText
            color: root.isOn ? root.urgent : Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
          }
        }
      }

      // ---------- QR card (only while broadcasting) ----------
      PanelSeparator {
        visible: root.isOn
        foreground: root.foreground
      }

      Column {
        visible: root.isOn
        width: parent.width
        spacing: Style.space(10)

        Item {
          width: parent.width
          implicitHeight: Math.max(qrTitle.implicitHeight, qrRefreshRow.implicitHeight)

          PanelSectionHeader {
            id: qrTitle
            text: "SCAN TO JOIN"
            foreground: root.foreground
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Row {
            id: qrRefreshRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PanelActionButton {
              iconText: "󰐲"
              tooltipText: "Regenerate QR"
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.qrHasCursor
              onHovered: function(on) { if (on) root.setSection("actions", 1) }
              onClicked: root.generateQr()
            }
          }
        }

        // White rounded canvas; only dark modules paint. Same rendering
        // approach as omarchy.wifiqr.
        Rectangle {
          id: qrCanvas
          readonly property int moduleSize: root.qrSize > 0
            ? Math.max(4, Math.floor(Style.space(240) / root.qrSize))
            : 0

          visible: root.showingQr
          width: root.qrSize * moduleSize
          height: width
          color: "white"
          radius: Style.cornerRadius
          anchors.horizontalCenter: parent.horizontalCenter

          Grid {
            anchors.fill: parent
            columns: root.qrSize

            Repeater {
              model: root.qrSize * root.qrSize

              Rectangle {
                required property int index
                readonly property int matrixRow: Math.floor(index / root.qrSize)
                readonly property int matrixColumn: index % root.qrSize

                width: qrCanvas.moduleSize
                height: qrCanvas.moduleSize
                color: root.qrRows[matrixRow].charAt(matrixColumn) === "1" ? "#111111" : "transparent"
              }
            }
          }
        }

        Text {
          visible: root.qrLoading
          text: "Generating QR code…"
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.horizontalCenter: parent.horizontalCenter
        }

        // SSID + password under the code, with copy.
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)

          Text {
            text: root.hotspotSsid
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Text {
            visible: !root.editingPassword
            text: root.hotspotPassword || "—"
            textFormat: Text.PlainText
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: passwordField
            visible: root.editingPassword
            width: Style.space(130)
            text: root.passwordDraft
            placeholderText: "New password (8+)"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            foreground: root.foreground
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(2)
            onTextChanged: if (visible && text !== root.passwordDraft) root.passwordDraft = text
            onAccepted: root.savePassword()
            Keys.onEscapePressed: root.cancelPasswordEdit()
          }

          PanelActionButton {
            visible: !root.editingPassword
            iconText: "󰏫"
            tooltipText: "Edit password"
            foreground: root.foreground
            fontFamily: root.fontFamily
            hasCursor: root.editHasCursor
            onHovered: function(on) { if (on) root.setSection("actions", 2) }
            onClicked: root.startPasswordEdit()
          }

          PanelActionButton {
            visible: root.editingPassword
            iconText: ""
            tooltipText: "Save password"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.savePassword()
          }

          PanelActionButton {
            visible: root.editingPassword
            iconText: "󰜺"
            tooltipText: "Cancel"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.cancelPasswordEdit()
          }

          PanelActionButton {
            iconText: root.copyFlash ? "" : ""
            tooltipText: "Copy password"
            foreground: root.foreground
            fontFamily: root.fontFamily
            hasCursor: root.copyHasCursor
            onHovered: function(on) { if (on) root.setSection("actions", 0) }
            onClicked: root.copyPassword()
          }
        }

        Text {
          visible: root.passwordError !== ""
          text: root.passwordError
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.horizontalCenter: parent.horizontalCenter
        }
      }

      // ---------- Details ----------
      PanelSeparator {
        foreground: root.foreground
      }

      GridLayout {
        width: parent.width
        columns: 2
        columnSpacing: Style.space(20)
        rowSpacing: Style.spacing.labelGap

        InfoLabel { text: "State" }
        DetailValue { text: root.statusLine() }

        InfoLabel { text: "Uplink" }
        DetailValue { text: root.hotspotUplink || "—" }

        InfoLabel { text: "Channel" }
        DetailValue { text: root.hotspotChannel ? ("ch " + root.hotspotChannel) : "—" }

        InfoLabel { text: "Clients" }
        DetailValue { text: root.isOn ? (root.hotspotClients || "0") : "—" }

        InfoLabel { text: "Security" }
        DetailValue { text: "WPA2 · " + (root.hotspotPassword || "—") }
      }

      Text {
        width: parent.width
        text: root.isOn ? "Your Wi-Fi connection stays on while the hotspot is active." : "Start the hotspot to share this connection — your Wi-Fi stays on."
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
    }
  }

  // ---- Local label/value components (mirroring omarchy.network) ---------
  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component DetailValue: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    horizontalAlignment: Text.AlignRight
    Layout.fillWidth: true
  }
}
