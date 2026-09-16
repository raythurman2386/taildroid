import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property bool adbInstalled: false
  property bool scrcpyInstalled: false
  property string adbPath: ""
  property string scrcpyPath: ""
  property var devices: []
  property var tailscalePeers: []
  property var bluetoothDevices: []
  property bool refreshing: false
  property string statusText: "Checking…"
  property string actionStatus: ""
  property string lastError: ""
  property string controllingSerial: ""
  property int _desired: -1
  readonly property bool sessionRunning: scrcpyProcess.running
  readonly property bool controlling: _desired === -1 ? sessionRunning : (_desired === 1)
  // Status polls must not swallow the header switch. Only in-flight control
  // actions count as busy, matching how ToggleSwitch is documented to behave.
  readonly property bool busy: actionProcess.running || (_desired === 0 && sessionRunning)
  readonly property int refreshIntervalSec: Model.intSetting(settings, "refreshIntervalSec", 15, 5, 120)
  readonly property int adbPort: Model.intSetting(settings, "adbPort", 5555, 1, 65535)
  readonly property string preferredPeer: String(Model.setting(settings, "preferredPeer", ""))
  readonly property string preferredSerial: String(Model.setting(settings, "preferredSerial", ""))
  readonly property var selectedDevice: Model.pickDevice(devices, controllingSerial || preferredSerial)
  readonly property bool hasReadyDevice: !!(selectedDevice && selectedDevice.state === "device")
  readonly property var onlinePeer: {
    for (var i = 0; i < tailscalePeers.length; i++) {
      if (tailscalePeers[i].online && tailscalePeers[i].ip) return tailscalePeers[i]
    }
    return null
  }

  property string _statusOutput: ""
  property string _statusError: ""
  property string _actionOutput: ""
  property string _actionError: ""
  property string _pendingAction: ""
  property bool _startAfterConnect: false
  property string _scrcpyError: ""

  function helperPath() {
    var raw = Qt.resolvedUrl("phone.py").toString()
    if (raw.indexOf("file://") === 0) raw = raw.substring(7)
    return decodeURIComponent(raw)
  }

  function elideStatus(text) {
    return Model.elide(Model.maskText(text), 180)
  }

  function setAction(text) {
    actionStatus = Model.maskText(text)
    if (text) actionStatusTimer.restart()
  }

  function missingToolsText() {
    var missing = []
    if (!adbInstalled) missing.push("android-tools")
    if (!scrcpyInstalled) missing.push("scrcpy")
    return "Install " + missing.join(" and ") + " with omarchy pkg add"
  }

  function statusFrom(parsed) {
    var ready = Model.pickDevice(parsed.devices || [], controllingSerial || preferredSerial)
    var peer = null
    var peers = parsed.tailscale || []
    for (var i = 0; i < peers.length; i++) {
      if (peers[i].online && peers[i].ip) { peer = peers[i]; break }
    }
    if (!(parsed.adb === true) || !(parsed.scrcpy === true)) {
      var missing = []
      if (parsed.adb !== true) missing.push("android-tools")
      if (parsed.scrcpy !== true) missing.push("scrcpy")
      return "Install " + missing.join(" and ") + " with omarchy pkg add"
    }
    if (sessionRunning) return "Mouse and keyboard are on the phone"
    if (ready && ready.state === "device") return "Ready — Super+Shift+I to take control"
    if (peer) return peer.name + " is on Tailscale — connect wireless debugging"
    return "No phone on ADB yet"
  }

  function refresh() {
    if (statusProcess.running) return
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    statusProcess.command = ["python3", helperPath(), "status", preferredPeer]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseJson(raw)
    if (!parsed || parsed.ok !== true) {
      lastError = elideStatus((parsed && parsed.error) ? parsed.error : "Failed to read phone status")
      statusText = lastError
      return
    }
    adbInstalled = parsed.adb === true
    scrcpyInstalled = parsed.scrcpy === true
    adbPath = String(parsed.adbPath || "")
    scrcpyPath = String(parsed.scrcpyPath || "")
    devices = parsed.devices || []
    tailscalePeers = parsed.tailscale || []
    bluetoothDevices = parsed.bluetooth || []
    if (parsed.adbError) lastError = elideStatus(parsed.adbError)
    statusText = statusFrom(parsed)
  }

  function runAction(args, pending) {
    if (actionProcess.running) return
    _actionOutput = ""
    _actionError = ""
    _pendingAction = pending || ""
    actionProcess.command = ["python3", helperPath()].concat(args)
    actionProcess.running = true
  }

  function connectAddress(addr) {
    if (!adbInstalled) {
      lastError = missingToolsText()
      return
    }
    setAction("Connecting " + Model.maskHostPort(addr) + "…")
    runAction(["connect", addr], "connect")
  }

  function connectTailscale() {
    if (!adbInstalled) {
      lastError = missingToolsText()
      return
    }
    setAction("Connecting over Tailscale…")
    runAction(["connect-tailscale", preferredPeer, String(adbPort)], "connect")
  }

  function pair(addr, code) {
    var host = String(addr || "").trim()
    var pin = String(code || "").trim()
    if (!host || !pin) {
      lastError = "Enter the wireless pairing address and six-digit code, then Pair"
      return
    }
    setAction("Pairing " + host + "…")
    runAction(["pair", host, pin], "pair")
  }

  function disconnectDevice(serial) {
    if (!serial) return
    setAction("Disconnecting " + Model.maskHostPort(serial) + "…")
    runAction(["disconnect", serial], "disconnect")
  }

  function startControl(device) {
    var target = device || selectedDevice
    if (sessionRunning) return
    if (!scrcpyInstalled || !adbInstalled) {
      lastError = missingToolsText()
      return
    }
    if (!target || target.state !== "device") {
      if (onlinePeer && !_startAfterConnect) {
        _startAfterConnect = true
        connectTailscale()
        return
      }
      lastError = "No authorized Android device. Pair wireless debugging or plug in USB."
      _startAfterConnect = false
      return
    }
    _startAfterConnect = false
    _desired = 1
    controllingSerial = target.serial
    lastError = ""
    _scrcpyError = ""
    scrcpyProcess.command = Model.scrcpyCommand(scrcpyPath || "scrcpy", target, settings)
    scrcpyProcess.running = true
    statusText = "Mouse and keyboard are on the phone"
    setAction("Taking control of " + Model.displayDeviceName(target))
  }

  function stopControl() {
    if (!sessionRunning && !scrcpyProcess.running) {
      _desired = -1
      return
    }
    _desired = 0
    scrcpyProcess.running = false
    setAction("Releasing the phone")
  }

  function toggleControl() {
    if (controlling) stopControl()
    else startControl(selectedDevice)
  }

  function handleActionExit(exitCode) {
    var stdout = String(actionStdout.text || _actionOutput || "")
    var stderr = String(actionStderr.text || _actionError || "")
    var parsed = Model.parseJson(stdout)
    var pending = _pendingAction
    var shouldStart = _startAfterConnect && pending === "connect"
    _pendingAction = ""
    if (exitCode !== 0 || !parsed || parsed.ok !== true) {
      _startAfterConnect = false
      lastError = elideStatus((parsed && parsed.error) || stderr || stdout || "Phone command failed")
      actionStatus = lastError
      return
    }
    lastError = ""
    setAction(parsed.message || "OK")
    delayedRefresh.restart()
    if (shouldStart) delayedStart.restart()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedStart
    interval: 900
    repeat: false
    onTriggered: {
      if (root.hasReadyDevice) root.startControl(root.selectedDevice)
      else {
        root._startAfterConnect = false
        root.lastError = "Tailscale connected, but ADB is not authorized yet. Accept the prompt on the phone, then try again."
      }
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else {
        root.lastError = root.elideStatus(stderr || stdout || "Could not read phone status")
        root.statusText = root.lastError
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true; onStreamFinished: root._actionOutput = text }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) { root.handleActionExit(exitCode) }
  }

  Process {
    id: scrcpyProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: false }
    stderr: SplitParser {
      onRead: function(data) {
        var line = String(data || "")
        if (line.toLowerCase().indexOf("error") >= 0 || line.toLowerCase().indexOf("failed") >= 0)
          root._scrcpyError = root.elideStatus(line)
      }
    }
    onExited: function(exitCode) {
      root._desired = -1
      if (exitCode !== 0 && root._scrcpyError)
        root.lastError = root._scrcpyError
      else if (exitCode !== 0)
        root.lastError = "scrcpy exited (" + exitCode + ")"
      root.delayedRefresh.restart()
    }
    onRunningChanged: {
      if (!running && root._desired === 0) root._desired = -1
    }
  }
}
