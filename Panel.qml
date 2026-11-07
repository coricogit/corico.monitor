import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string backend: String(Qt.resolvedUrl("displayctl.py")).replace(/^file:\/\//, "")

  property var displays: []
  property string displaysJson: ""
  property string selectedName: ""
  property string applyError: ""
  property bool dragging: false

  // Brightness by monitor name. null means the monitor doesn't answer DDC.
  property var brightness: ({})
  property string pendingBrightnessMonitor: ""
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false

  // A refresh-rate change waiting to be kept. The deadline lives in the
  // backend, which reverts on its own, so reopening the panel finds it again.
  property real trialDeadline: 0
  property int trialSeconds: 0
  property string trialRate: ""
  readonly property bool trialActive: trialDeadline > 0

  property string queuedApply: ""

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  readonly property var activeDisplays: Model.enabledDisplays(displays)
  readonly property int enabledDisplayCount: activeDisplays.length
  readonly property var focusedDisplay: {
    for (var i = 0; i < activeDisplays.length; i++)
      if (activeDisplays[i].focused) return activeDisplays[i]
    return activeDisplays.length ? activeDisplays[0] : null
  }
  readonly property var selectedDisplay: {
    for (var i = 0; i < activeDisplays.length; i++)
      if (activeDisplays[i].name === selectedName) return activeDisplays[i]
    return focusedDisplay
  }

  readonly property var selectedBrightness: selectedDisplay ? brightness[selectedDisplay.name] : null
  readonly property bool brightnessAvailable: typeof selectedBrightness === "number"
  readonly property int brightnessPercent: brightnessAvailable ? selectedBrightness : 0

  readonly property var orientations: [
    { transform: 0, label: strings.t("orientation.horizontal") },
    { transform: 1, label: strings.t("orientation.verticalRight") },
    { transform: 3, label: strings.t("orientation.verticalLeft") }
  ]
  readonly property var refreshRates: Model.refreshRates(selectedDisplay)
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: selectedDisplay
    ? Model.availableScales(scalePresets, selectedDisplay.width, selectedDisplay.height)
    : scalePresets

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  // Cursor model shared by keyboard and mouse. Every section but "monitors" is
  // one row: h/l picks a monitor in "arrange", walks the pills in the pill
  // rows, and moves the slider in the slider rows, where selectedIndex is the
  // -1 sentinel. j/k walks the rows.
  property string focusSection: "orientation"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var visibleSections: {
    var list = []
    if (activeDisplays.length > 1) list.push("arrange")
    list.push("orientation")
    if (refreshRates.length > 1) list.push("refresh")
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize", "scale")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "orientation") return orientations.length
    if (section === "refresh") return refreshRates.length
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionHasPills(section) {
    return section === "orientation" || section === "refresh" || section === "scale"
  }

  function sectionFirstIndex(section) {
    return sectionHasPills(section) || section === "monitors" ? 0 : -1
  }

  function moveCursor(delta) {
    var sections = visibleSections
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inList = focusSection === "monitors"
    var max = sectionCount(focusSection) - 1

    if (delta > 0) {
      if (inList && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (inList && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        selectedIndex = prev === "monitors" ? sectionCount(prev) - 1 : sectionFirstIndex(prev)
      }
    }
  }

  function moveCursorH(delta) {
    if (focusSection === "arrange") {
      var names = activeDisplays.map(function(d) { return d.name })
      var at = selectedDisplay ? names.indexOf(selectedDisplay.name) : 0
      selectedName = names[(at + delta + names.length) % names.length]
    } else if (focusSection === "brightness") {
      if (selectedDisplay) setBrightness(selectedDisplay.name, brightnessPercent + delta * 5)
    } else if (focusSection === "textsize") {
      adjustTextSize(delta)
    } else if (sectionHasPills(focusSection)) {
      selectedIndex = Math.max(0, Math.min(sectionCount(focusSection) - 1, selectedIndex + delta))
    }
  }

  function activateCursor() {
    if (focusSection === "orientation") {
      if (orientations[selectedIndex]) setOrientation(orientations[selectedIndex].transform)
    } else if (focusSection === "refresh") {
      if (refreshRates[selectedIndex]) setRefreshRate(refreshRates[selectedIndex])
    } else if (focusSection === "scale") {
      if (scaleValues[selectedIndex]) setScale(scaleValues[selectedIndex])
    } else if (focusSection === "monitors") {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (sectionFirstIndex(focusSection) === -1) selectedIndex = -1
    else selectedIndex = Math.max(0, Math.min(sectionCount(focusSection) - 1, selectedIndex))
  }

  function hoverCursor(section, index) {
    if (root.reflowingText) return
    root.cursorActive = true
    root.focusSection = section
    root.selectedIndex = index
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height.
  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    if (focusedDisplay) root.setBrightness(focusedDisplay.name, Number(percent))
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: focusedDisplay ? brightness[focusedDisplay.name] : null,
      focusedMonitor: focusedDisplay ? focusedDisplay.name : "",
      displays: root.displays
    })
  }

  ShellIpc {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function readState(text) {
    var state
    try {
      state = JSON.parse(text)
    } catch (e) {
      return
    }
    root.trialDeadline = Number(state.trialDeadline) || 0
    root.updateTrialSeconds()

    // A drag holds the tiles, and an unchanged list needs no rebuild.
    var json = JSON.stringify(state.monitors)
    if (root.dragging || json === root.displaysJson) return
    root.displaysJson = json
    root.displays = Model.parseDisplays(json).displays
  }

  function updateTrialSeconds() {
    root.trialSeconds = Math.max(0, Math.ceil(root.trialDeadline - Date.now() / 1000))
  }

  // ---- Monitors ----
  function runApply(payload) {
    if (applyProc.running) {
      root.queuedApply = payload
      return
    }
    root.queuedApply = ""
    root.applyError = ""
    applyProc.command = ["/usr/bin/python3", root.backend, "apply", payload]
    applyProc.running = true
  }

  // `list` is what Model.placeMonitor returned. It shows at once and the next
  // state read corrects anything Hyprland didn't take.
  function applyLayout(list, trial) {
    var byName = {}
    list.forEach(function(d) { byName[d.name] = d })
    root.displays = root.displays.map(function(d) { return byName[d.name] || d })

    runApply(JSON.stringify({
      trial: !!trial,
      notice: strings.t("trial.reverted"),
      monitors: list
    }))
  }

  function changeSelected(changes, trial) {
    if (!selectedDisplay) return
    applyLayout(Model.placeMonitor(displays, selectedDisplay.name, changes), trial)
  }

  function setOrientation(transform) {
    if (selectedDisplay && selectedDisplay.transform !== transform)
      changeSelected({ transform: transform })
  }

  function setRefreshRate(rate) {
    if (!selectedDisplay || isCurrentRate(rate)) return
    root.trialRate = rate
    changeSelected({ refreshRate: Number(rate) }, true)
  }

  function isCurrentRate(rate) {
    return selectedDisplay && Math.abs(Number(rate) - selectedDisplay.refreshRate) < 0.01
  }

  function setScale(scale) {
    if (!selectedDisplay) return
    var clean = Number(Model.cleanScale(scale, selectedDisplay.width, selectedDisplay.height))
    if (clean > 0 && Math.abs(clean - selectedDisplay.scale) >= 0.001)
      changeSelected({ scale: clean })
  }

  function moveDisplay(name, x, y) {
    var list = Model.placeMonitor(displays, name, { x: x, y: y })
    if (!Model.sameLayout(list, activeDisplays)) applyLayout(list)
  }

  function resolveTrial(action) {
    root.trialDeadline = 0
    trialProc.command = ["/usr/bin/python3", root.backend, action]
    trialProc.running = true
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    // hyprctl keyword is rejected under the Lua config ("non-legacy parsers"),
    // so drive the monitor through the hl.monitor eval API instead.
    var output = '"' + name.replace(/[\\"]/g, "\\$&") + '"'
    actionProc.command = ["hyprctl", "eval", 'hl.monitor({ output = ' + output + ', disabled = ' + enabled + ' })']
    if (!actionProc.running) actionProc.running = true
  }

  function activeScaleIndex() {
    if (!selectedDisplay) return -1
    return Model.matchingScaleIndex(scaleValues, Model.normalizeScale(selectedDisplay.scale),
                                    selectedDisplay.width, selectedDisplay.height)
  }

  function effectiveScale(scale) {
    if (!selectedDisplay) return Model.normalizeScale(scale)
    return Model.cleanScale(scale, selectedDisplay.width, selectedDisplay.height)
  }

  // ---- Brightness ----
  function setBrightness(name, value) {
    var percent = Model.clampBrightness(value)
    storeBrightness(name, percent)
    root.pendingBrightnessMonitor = name
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", name, percent + "%"]
    setBrightnessProc.running = true
  }

  function storeBrightness(name, percent) {
    var next = Object.assign({}, root.brightness)
    next[name] = percent
    root.brightness = next
  }

  function previewBrightness(value) {
    if (!selectedDisplay) return
    storeBrightness(selectedDisplay.name, Model.clampBrightness(value))
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = Math.max(0, Math.min(textSizeStops.length - 1, currentTextIndex() + deltaSteps))
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    refresh()
    brightnessProc.running = true
  }

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      if (!brightnessProc.running) brightnessProc.running = true
      root.selectedName = root.focusedDisplay ? root.focusedDisplay.name : ""
      focusSection = visibleSections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      cursorActive = false
      root.applyError = ""
    }
  }

  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onRefreshRatesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open. Brightness is read at open-time alone:
  // DDC is slow, and only this panel and the brightness keys change it.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 500
    running: root.trialActive
    repeat: true
    onTriggered: {
      root.updateTrialSeconds()
      // The backend has reverted by now, so pick up what it restored.
      if (root.trialSeconds === 0) root.refresh()
    }
  }

  Process {
    id: stateProc
    command: ["/usr/bin/python3", root.backend, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readState(text)
    }
  }

  Process {
    id: brightnessProc
    command: ["/usr/bin/python3", root.backend, "brightness"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.brightness = JSON.parse(text)
        } catch (e) {
          root.brightness = ({})
        }
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyError = String(text || "").trim().slice(0, 200)
    }
    onRunningChanged: {
      if (running) return
      if (root.queuedApply !== "") root.runApply(root.queuedApply)
      else {
        root.displaysJson = ""
        root.refresh()
      }
    }
  }

  Process {
    id: trialProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) {
      root.displaysJson = ""
      root.refresh()
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: if (root.selectedDisplay) root.setBrightness(root.selectedDisplay.name, root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT re-read brightness after a set completes. The local value we just
    // wrote is authoritative; re-reading races the hardware and can return
    // nothing, which would make the slider bounce.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued)
        root.setBrightness(root.pendingBrightnessMonitor, root.pendingBrightnessPercent)
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      var focused = root.focusedDisplay
      if (!focused || typeof root.brightness[focused.name] !== "number") return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(focused.name, root.brightness[focused.name] + wheel.steps * 5)
      root.showBrightnessOsd(root.brightness[focused.name])
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(980))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (root.trialActive) return
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive && !root.trialActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/selected monitor ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: strings.t("title")
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.selectedDisplay
                  ? (root.selectedDisplay.name + " · " + root.selectedDisplay.model).toUpperCase()
                  : ""
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Refresh-rate confirmation ----------
          Rectangle {
            visible: root.trialActive
            width: parent.width
            height: trialInner.implicitHeight + Style.space(20)
            radius: Style.space(6)
            color: Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)

            Column {
              id: trialInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: strings.t("trial.prompt").arg(root.trialRate)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                width: parent.width
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                text: strings.t("trial.countdown").arg(Commons.I18n.formatNumber(root.trialSeconds))
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                elide: Text.ElideRight
              }

              Row {
                spacing: Style.spacing.xs

                Button {
                  text: strings.t("trial.keep")
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  bordered: true
                  onClicked: root.resolveTrial("keep")
                }

                Button {
                  text: strings.t("trial.revert")
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  bordered: true
                  onClicked: root.resolveTrial("revert")
                }
              }
            }
          }

          Text {
            visible: root.applyError !== ""
            textFormat: Text.PlainText
            text: root.applyError
            color: Commons.Color.accent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            width: parent.width
          }

          Column {
            width: parent.width
            spacing: Style.space(14)
            enabled: !root.trialActive
            opacity: root.trialActive ? 0.45 : 1

            // ---------- Arrangement ----------
            Column {
              visible: root.activeDisplays.length > 1
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: strings.t("arrangement")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              CursorSurface {
                id: arrangeRow
                width: parent.width
                height: canvas.height
                hasCursor: root.cursorActive && root.focusSection === "arrange"
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(arrangeRow)
                foreground: root.bar.foreground
                outline: true

                Item {
                  id: canvas
                  width: parent.width
                  height: Style.space(220)
                  clip: true

                  readonly property var rects: root.activeDisplays.map(Model.logicalRect)
                  readonly property var bounds: Model.boundsOf(rects)

                  // Room for every monitor in a row or a stack, plus a margin
                  // to drag one past the others. It depends on sizes alone, so
                  // tiles don't resize when they are rearranged.
                  readonly property real fit: {
                    var sumW = 0, sumH = 0, largest = 0
                    rects.forEach(function(r) {
                      sumW += r.w
                      sumH += r.h
                      largest = Math.max(largest, r.w, r.h)
                    })
                    if (!largest) return 0.1
                    return Math.min(width / (sumW + largest * 0.6), height / (sumH + largest * 0.6))
                  }
                  readonly property real originX: (width - bounds.w * fit) / 2 - bounds.x * fit
                  readonly property real originY: (height - bounds.h * fit) / 2 - bounds.y * fit

                  property var snapPreview: null

                  HoverHandler {
                    onHoveredChanged: if (hovered) root.hoverCursor("arrange", -1)
                  }

                  Rectangle {
                    visible: canvas.snapPreview !== null
                    x: visible ? canvas.originX + canvas.snapPreview.x * canvas.fit : 0
                    y: visible ? canvas.originY + canvas.snapPreview.y * canvas.fit : 0
                    width: visible ? canvas.snapPreview.w * canvas.fit : 0
                    height: visible ? canvas.snapPreview.h * canvas.fit : 0
                    radius: Style.space(3)
                    color: "transparent"
                    border.width: 1
                    border.color: Commons.Color.accent
                  }

                  // The model is a count, not the list, so tiles survive a
                  // layout change and glide to their new place.
                  Repeater {
                    model: root.activeDisplays.length

                    MonitorTile {
                      required property int index
                      display: root.activeDisplays[index] || null
                      area: canvas
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                text: strings.t("arrangement.hint")
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                width: parent.width
              }
            }

            // ---------- Orientation ----------
            PanelSeparator {
              foreground: root.bar.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: strings.t("orientation")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Grid {
                id: orientationRow
                width: parent.width
                columns: root.orientations.length
                spacing: Style.spacing.xs
                readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

                Repeater {
                  model: root.orientations

                  OptionPill {
                    required property var modelData
                    required property int index

                    section: "orientation"
                    optionIndex: index
                    width: orientationRow.cellWidth
                    text: modelData.label
                    active: root.selectedDisplay !== null && root.selectedDisplay.transform === modelData.transform
                    onClicked: root.setOrientation(modelData.transform)
                  }
                }
              }
            }

            // ---------- Refresh rate ----------
            PanelSeparator {
              visible: root.refreshRates.length > 1
              foreground: root.bar.foreground
            }

            Column {
              visible: root.refreshRates.length > 1
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: strings.t("refresh")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Grid {
                id: refreshRow
                width: parent.width
                columns: 5
                spacing: Style.spacing.xs
                readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

                Repeater {
                  model: root.refreshRates

                  OptionPill {
                    required property string modelData
                    required property int index

                    section: "refresh"
                    optionIndex: index
                    width: refreshRow.cellWidth
                    text: Commons.I18n.formatNumber(Number(modelData), modelData.indexOf(".") >= 0 ? 2 : 0)
                    active: root.isCurrentRate(modelData)
                    onClicked: root.setRefreshRate(modelData)
                  }
                }
              }
            }

            // ---------- Brightness ----------
            PanelSeparator {
              foreground: root.bar.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessValue.implicitHeight)

                PanelSectionHeader {
                  id: brightnessHeader
                  text: strings.t("brightness")
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: brightnessValue
                  visible: root.brightnessAvailable
                  textFormat: Text.PlainText
                  text: Commons.I18n.formatNumber(Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent)) + "%"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                visible: !root.brightnessAvailable
                textFormat: Text.PlainText
                text: strings.t("brightness.unavailable")
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                elide: Text.ElideRight
              }

              CursorSurface {
                id: brightnessRow
                visible: root.brightnessAvailable
                width: parent.width
                height: brightnessSlider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
                foreground: root.bar.foreground
                outline: true

                PanelSlider {
                  id: brightnessSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 1
                  maximum: 100
                  step: 1
                  value: root.brightnessPercent
                  integer: true
                  onMoved: function(v) { root.previewBrightness(v) }
                  onReleased: function(v) {
                    brightnessDebounce.stop()
                    if (root.selectedDisplay) root.setBrightness(root.selectedDisplay.name, v)
                  }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered) root.hoverCursor("brightness", -1)
                }
              }
            }

            // ---------- Scale ----------
            PanelSeparator {
              foreground: root.bar.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: strings.t("scale")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Grid {
                id: scaleRow
                width: parent.width
                columns: Math.max(1, root.scaleValues.length)
                spacing: Style.spacing.xs
                readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

                Repeater {
                  model: root.scaleValues

                  OptionPill {
                    required property string modelData
                    required property int index

                    section: "scale"
                    optionIndex: index
                    width: scaleRow.cellWidth
                    text: Commons.I18n.formatNumber(root.effectiveScale(modelData)) + "x"
                    active: root.activeScaleIndex() === index
                    onClicked: root.setScale(modelData)
                  }
                }
              }
            }

            // ---------- Text size ----------
            PanelSeparator {
              foreground: root.bar.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

                PanelSectionHeader {
                  id: textSizeHeader
                  text: strings.t("textSize")
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: textSizePx
                  textFormat: Text.PlainText
                  text: strings.t("textSize.everywhere") + " · " + Commons.I18n.formatNumber(textSizeSlider.dragging
                         ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                         : root.displayedTextPx()) + "px"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              CursorSurface {
                id: textSizeRow
                width: parent.width
                height: textSizeSlider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
                foreground: root.bar.foreground
                outline: true

                PanelSlider {
                  id: textSizeSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: root.textSizeStops.length - 1
                  step: 1
                  integer: true
                  tickCount: root.textSizeStops.length
                  value: root.currentTextIndex()
                  onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered) root.hoverCursor("textsize", -1)
                }
              }
            }

            // ---------- Monitors ----------
            PanelSeparator {
              visible: root.displays.length > 1
              foreground: root.bar.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(10)
              visible: root.displays.length > 1

              PanelSectionHeader {
                text: strings.t("displays")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Repeater {
                model: root.displays

                MonitorRow {
                  required property var modelData
                  required property int index

                  width: panelColumn.width
                  display: modelData
                  rowIndex: index
                }
              }
            }

            Item {
              width: parent.width
              height: Style.space(4)
            }
          }
        }
      }
    }
  }

  component OptionPill: Button {
    id: pill
    required property string section
    required property int optionIndex

    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.xs
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    hasCursor: root.cursorActive && root.focusSection === section && root.selectedIndex === optionIndex
    onHovered: function(isHovered) {
      if (isHovered) root.hoverCursor(pill.section, pill.optionIndex)
    }
  }

  // One monitor in the arrangement. Positions are logical pixels, as Hyprland
  // has them, and `area.fit` converts them to the canvas.
  component MonitorTile: Rectangle {
    id: tile
    required property var display
    required property Item area

    readonly property var rect: display ? Model.logicalRect(display) : ({ x: 0, y: 0, w: 0, h: 0 })
    readonly property bool isSelected: display && root.selectedDisplay
      && display.name === root.selectedDisplay.name
    property real dragX: 0
    property real dragY: 0
    property bool held: false

    x: area.originX + rect.x * area.fit + dragX
    y: area.originY + rect.y * area.fit + dragY
    z: held ? 2 : (isSelected ? 1 : 0)
    width: rect.w * area.fit
    height: rect.h * area.fit
    radius: Style.space(3)
    color: isSelected
      ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
      : Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
    border.width: isSelected ? 2 : 1
    border.color: isSelected ? Commons.Color.accent : Qt.darker(root.bar.foreground, 1.8)

    Behavior on x {
      enabled: !tile.held
      NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
    }
    Behavior on y {
      enabled: !tile.held
      NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
    }

    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(8)
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        text: tile.display ? tile.display.model : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        text: tile.display ? tile.display.name : ""
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        width: parent.width
      }
    }

    MouseArea {
      anchors.fill: parent
      preventStealing: true
      enabled: tile.display !== null
      cursorShape: tile.held ? Qt.ClosedHandCursor : Qt.OpenHandCursor

      property point grab: Qt.point(0, 0)

      // The rect as it would land, in logical pixels.
      function dropRect() {
        return {
          x: tile.rect.x + Math.round(tile.dragX / tile.area.fit),
          y: tile.rect.y + Math.round(tile.dragY / tile.area.fit),
          w: tile.rect.w,
          h: tile.rect.h
        }
      }

      function others() {
        return root.activeDisplays
          .filter(function(d) { return d.name !== tile.display.name })
          .map(Model.logicalRect)
      }

      function release() {
        tile.held = false
        tile.dragX = 0
        tile.dragY = 0
        tile.area.snapPreview = null
        root.dragging = false
      }

      onPressed: function(mouse) {
        root.selectedName = tile.display.name
        grab = mapToItem(tile.area, mouse.x, mouse.y)
      }

      onPositionChanged: function(mouse) {
        if (!pressed) return
        var point = mapToItem(tile.area, mouse.x, mouse.y)
        var dx = point.x - grab.x
        var dy = point.y - grab.y
        if (!tile.held && Math.hypot(dx, dy) < 4) return

        tile.held = true
        root.dragging = true
        var homeX = tile.area.originX + tile.rect.x * tile.area.fit
        var homeY = tile.area.originY + tile.rect.y * tile.area.fit
        tile.dragX = Math.max(-homeX, Math.min(tile.area.width - tile.width - homeX, dx))
        tile.dragY = Math.max(-homeY, Math.min(tile.area.height - tile.height - homeY, dy))

        var drop = dropRect()
        var spot = Model.snapPosition(drop, others())
        tile.area.snapPreview = { x: spot.x, y: spot.y, w: drop.w, h: drop.h }
      }

      onReleased: {
        if (!tile.held) return
        var drop = dropRect()
        var name = tile.display.name
        release()
        root.moveDisplay(name, drop.x, drop.y)
      }

      onCanceled: release()
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.focused
          ? strings.t("displays.focused").arg(monitorRow.display.name)
          : monitorRow.display.name
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.hoverCursor("monitors", monitorRow.rowIndex)
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}
