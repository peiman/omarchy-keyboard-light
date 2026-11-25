import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// One instance for the whole shell. It owns the keyboard LED so a widget on
// each monitor cannot race the same write. brightnessctl is argv-only: the
// device name is a sysfs basename that Model.parseProbe already accepted.
Item {
  id: root

  property var settings: ({})

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string scriptPath: pluginDir + "/probe.sh"
  readonly property var config: Model.withDefaults(settings)

  property bool probed: false
  property string ledName: ""
  property int maxBrightness: 0
  property bool hasSensor: false
  property string sensorKind: "none"
  property var rawLux: null
  property var smoothedLux: null
  property real shownPercent: 0
  property real targetPercent: 0
  property int lastWritten: -1
  property int commanded: -1
  property int inflight: -1
  property int queued: -1
  property bool ignoreWrite: false
  property bool seeded: false
  property bool suspended: false
  property bool wakeProbe: false
  property bool userIdle: false
  property bool hold: false
  property int holdPercent: 0
  property var holdLux: null
  property int externalSerial: 0
  property int externalPercent: 0
  property bool loggedReady: false
  property bool warned: false
  property int appliedFadeMs: 1500
  property real fadeFrom: 0
  property real fadeTo: 0
  property double fadeStartMs: 0
  property int fadeDurationMs: 1500

  readonly property bool available: ledName !== ""
  readonly property int percent: Math.round(shownPercent)

  function warnOnce(text) {
    if (warned) return
    warned = true
    console.warn("io.github.peiman.keyboard-light: " + text)
  }

  function poll() {
    if (!probeProc.running) probeProc.running = true
  }

  function applyProbe(parsed) {
    if (!parsed || !parsed.ok) return
    var hadLed = ledName !== ""
    probed = true
    if (!parsed.led) {
      ledName = ""
      hasSensor = false
      if (hadLed) pollTimer.restart()
      return
    }
    if (!hadLed) pollTimer.restart()
    ledName = parsed.led
    maxBrightness = parsed.max
    sensorKind = parsed.kind
    hasSensor = parsed.lux !== null && parsed.kind !== "none"
    if (hasSensor) {
      rawLux = parsed.lux
      smoothedLux = Model.smooth(smoothedLux, parsed.lux, config.smoothing)
    }
    if (!loggedReady) {
      loggedReady = true
      console.log("keyboard-light: " + ledName + " sensor=" + sensorKind)
    }

    var waking = wakeProbe
    wakeProbe = false

    if (parsed.locked || parsed.lid) {
      suspended = true
      fadeTimer.stop()
      return
    }

    if (suspended) {
      suspended = false
      seeded = true
      lastWritten = parsed.brightness
      shownPercent = Model.percentFromLevel(parsed.brightness, parsed.max)
    }

    if (!seeded) {
      seeded = true
      lastWritten = parsed.brightness
      shownPercent = Model.percentFromLevel(parsed.brightness, parsed.max)
    }

    // A fade writes a new level every step. A sample caught between two steps
    // is our own write, not a brightness key.
    var baseline = inflight >= 0 ? commanded : lastWritten
    if (!fadeTimer.running && inflight < 0 && Model.isExternal(parsed.brightness, baseline, parsed.max)) {
      acceptExternal(parsed.brightness)
      return
    }

    if (hold && Model.holdReleased(smoothedLux, holdLux, Model.OVERRIDE_LUX))
      hold = false

    retarget()
    if (waking && !fadeTimer.running) writePercent(shownPercent)
  }

  function acceptExternal(level) {
    fadeTimer.stop()
    var pct = Model.percentFromLevel(level, maxBrightness)
    shownPercent = pct
    targetPercent = pct
    lastWritten = level
    if (writeProc.running) {
      ignoreWrite = true
      queued = level
    } else {
      queued = -1
    }
    if (config.auto && hasSensor) {
      hold = true
      holdPercent = pct
      holdLux = smoothedLux
      return
    }
    hold = false
    externalPercent = pct
    externalSerial += 1
  }

  function retarget() {
    if (suspended || ledName === "" || !seeded) return
    var next = Model.desiredPercent(config, smoothedLux, hasSensor, hold, holdPercent, userIdle)
    targetPercent = next
    if (fadeTimer && fadeTimer.running && Math.abs(fadeTo - next) < 0.6) return
    beginFade(next)
  }

  function beginFade(next) {
    if (Math.abs(shownPercent - next) < 0.6) {
      shownPercent = next
      if (fadeTimer) fadeTimer.stop()
      writePercent(next)
      return
    }
    fadeFrom = shownPercent
    fadeTo = next
    fadeStartMs = Date.now()
    fadeDurationMs = Model.fadeDuration(shownPercent, next, config.fadeMs)
    if (fadeTimer && !fadeTimer.running) fadeTimer.start()
  }

  // Time-based so a full swing stays near a second and a half even though a
  // brightnessctl write itself returns in a couple of milliseconds. The old
  // 8% steps finished in under half a second and read as a blink.
  function stepFade() {
    if (suspended || ledName === "") {
      fadeTimer.stop()
      return
    }
    var next = Model.fadePercent(fadeFrom, fadeTo, Date.now() - fadeStartMs, fadeDurationMs)
    shownPercent = next
    writePercent(next)
    if (next === fadeTo) fadeTimer.stop()
  }

  function writePercent(percent) {
    if (suspended || ledName === "" || !Model.ledNameOk(ledName)) return
    writeLevel(Model.levelFromPercent(percent, maxBrightness))
  }

  function writeLevel(level) {
    if (level === lastWritten || level === inflight) return
    if (writeProc.running) {
      queued = level
      return
    }
    queued = -1
    commanded = level
    inflight = level
    writeProc.command = ["brightnessctl", "-q", "-d", ledName, "set", String(level)]
    writeProc.running = true
  }

  function applyImmediate(percent) {
    var pct = Model.clampPercent(percent)
    fadeTimer.stop()
    hold = false
    shownPercent = pct
    targetPercent = pct
    writePercent(pct)
  }

  function clearHold() {
    hold = false
    retarget()
  }

  function noteIdle(idle) {
    var waking = userIdle && !idle
    userIdle = !!idle
    if (config.idleSeconds <= 0) {
      userIdle = false
      waking = false
    }
    if (waking) {
      wakeProbe = true
      poll()
      return
    }
    retarget()
  }

  // settings is applied before later properties exist, so this waits a turn.
  onSettingsChanged: Qt.callLater(root.applySettings)

  function applySettings() {
    if (!root.config) return
    if (root.config.idleSeconds <= 0) root.userIdle = false
    if (root.hold && Model.holdReleased(root.smoothedLux, root.holdLux, Model.OVERRIDE_LUX))
      root.hold = false
    var fadeChanged = root.appliedFadeMs !== root.config.fadeMs
    root.appliedFadeMs = root.config.fadeMs
    if (fadeChanged && fadeTimer && fadeTimer.running) {
      root.beginFade(root.fadeTo)
      return
    }
    root.retarget()
  }

  Timer {
    id: pollTimer
    interval: root.probed && root.ledName === "" ? 10000 : root.config.pollIntervalMs
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Timer {
    id: fadeTimer
    interval: 30
    repeat: true
    onTriggered: root.stepFade()
  }

  // Input idle, not "something asked the screen to stay on". A video can keep
  // the display awake while the keys still go dark, which is how a Mac behaves.
  IdleMonitor {
    id: idleMonitor
    enabled: root.available && root.config && root.config.idleSeconds > 0
    timeout: Math.max(1, root.config ? root.config.idleSeconds : 5)
    respectInhibitors: false
    onIsIdleChanged: root.noteIdle(isIdle)
  }

  Process {
    id: probeProc
    command: [root.scriptPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProbe(Model.parseProbe(text))
    }
  }

  Process {
    id: writeProc
    onExited: function(code) {
      var ignore = root.ignoreWrite
      var level = root.commanded
      root.ignoreWrite = false
      root.inflight = -1
      if (!ignore && code === 0) root.lastWritten = level
      else if (!ignore) root.warnOnce("brightnessctl exited " + code)
      if (root.queued >= 0) {
        var next = root.queued
        root.queued = -1
        if (next !== root.lastWritten) root.writeLevel(next)
      }
    }
  }
}
