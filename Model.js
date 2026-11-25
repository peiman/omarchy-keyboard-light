.pragma library

// Pure decisions for the keyboard light. Sensor text and settings are
// untrusted: a device name is only accepted as a brightnessctl id, and
// nothing here is shown until it has been bounded.
var MAX_PROBE_CHARS = 2048
var OVERRIDE_LUX = 20
var IDLE_PRESETS = [0, 5, 10, 30, 60, 300]

function clamp(value, lo, hi) {
  var number = Number(value)
  if (!isFinite(number)) return lo
  return Math.max(lo, Math.min(hi, number))
}

function clampPercent(value) {
  return Math.round(clamp(value, 0, 100))
}

function whole(value, lo, hi) {
  var number = Number(value)
  if (!isFinite(number)) return null
  var rounded = Math.round(number)
  if (rounded < lo || rounded > hi) return null
  return rounded
}

function withDefaults(settings) {
  var source = settings && typeof settings === "object" ? settings : {}
  return {
    auto: source.auto !== false,
    manualPercent: clampPercent(source.manualPercent === undefined ? 40 : source.manualPercent),
    maxPercent: clampPercent(source.maxPercent === undefined ? 100 : source.maxPercent),
    minPercent: clampPercent(source.minPercent === undefined ? 0 : source.minPercent),
    luxDark: clamp(source.luxDark === undefined ? 8 : source.luxDark, 0, 100000),
    luxBright: clamp(source.luxBright === undefined ? 180 : source.luxBright, 0, 100000),
    idleSeconds: whole(source.idleSeconds === undefined ? 5 : source.idleSeconds, 0, 3600) || 0,
    fadeMs: whole(source.fadeMs === undefined ? 1500 : source.fadeMs, 200, 4000) || 1500,
    pollIntervalMs: whole(source.pollIntervalMs === undefined ? 1000 : source.pollIntervalMs, 500, 10000) || 1000,
    smoothing: clamp(source.smoothing === undefined ? 0.4 : source.smoothing, 0, 0.95)
  }
}

function pollMs(settings) {
  return withDefaults(settings).pollIntervalMs
}

// Dark rooms take the "in the dark" level. Bright rooms take the other one.
// Between the two thresholds the level falls in a straight line.
function mapLux(lux, dark, bright, minPercent, maxPercent) {
  var lo = clampPercent(minPercent)
  var hi = clampPercent(maxPercent)
  var sample = Number(lux)
  if (!isFinite(sample)) return lo
  var darkAt = Number(dark)
  var brightAt = Number(bright)
  if (!(brightAt > darkAt)) return sample <= darkAt ? hi : lo
  if (sample <= darkAt) return hi
  if (sample >= brightAt) return lo
  var t = (sample - darkAt) / (brightAt - darkAt)
  return hi + (lo - hi) * t
}

function ambientPercent(config, lux, hasSensor, hold, holdPercent) {
  var resolved = withDefaults(config)
  if (!resolved.auto || !hasSensor || !isFinite(Number(lux))) return resolved.manualPercent
  if (hold) return clampPercent(holdPercent)
  return mapLux(lux, resolved.luxDark, resolved.luxBright, resolved.minPercent, resolved.maxPercent)
}

function desiredPercent(config, lux, hasSensor, hold, holdPercent, idle) {
  var resolved = withDefaults(config)
  var ambient = ambientPercent(resolved, lux, hasSensor, hold, holdPercent)
  if (resolved.idleSeconds > 0 && idle) return 0
  return ambient
}

function smooth(previous, sample, keep) {
  var next = Number(sample)
  if (!isFinite(next)) return previous
  if (previous === null || previous === undefined || !isFinite(Number(previous))) return next
  var weight = clamp(keep, 0, 0.95)
  return Number(previous) * weight + next * (1 - weight)
}

function isExternal(current, commanded, maxBrightness) {
  var level = whole(current, 0, 1000000)
  var previous = whole(commanded, 0, 1000000)
  var max = whole(maxBrightness, 1, 1000000)
  if (level === null || previous === null || max === null) return false
  var deadband = Math.max(2, Math.round(max * 0.04))
  return Math.abs(level - previous) > deadband
}

function holdReleased(lux, holdLux, delta) {
  var sample = Number(lux)
  var held = Number(holdLux)
  var need = Number(delta)
  if (!isFinite(sample) || !isFinite(held) || !isFinite(need)) return false
  return Math.abs(sample - held) >= need
}

function approach(shown, target, step) {
  var from = Number(shown)
  var to = Number(target)
  var pace = Number(step)
  if (!isFinite(from)) return to
  if (!isFinite(to)) return from
  if (!isFinite(pace) || pace <= 0) pace = 1
  var delta = to - from
  if (Math.abs(delta) <= pace) return to
  return from + (delta > 0 ? pace : -pace)
}

// A full swing takes about a second and a half. Shorter moves keep a minimum
// so a small change still eases instead of popping.
var FULL_FADE_MS = 1500
var MIN_FADE_MS = 400

function fadeDuration(fromPercent, toPercent, fullMs) {
  var full = whole(fullMs === undefined || fullMs === null ? FULL_FADE_MS : fullMs, 200, 4000)
  if (full === null) full = FULL_FADE_MS
  var span = Math.abs(Number(toPercent) - Number(fromPercent)) / 100
  if (!isFinite(span) || span <= 0) return Math.min(full, MIN_FADE_MS)
  var shortest = Math.min(full, MIN_FADE_MS)
  return Math.max(shortest, Math.round(full * Math.min(1, span)))
}

function fadePercent(fromPercent, toPercent, elapsedMs, durationMs) {
  var from = Number(fromPercent)
  var to = Number(toPercent)
  var duration = Number(durationMs)
  if (!isFinite(from)) return to
  if (!isFinite(to)) return from
  if (!isFinite(duration) || duration <= 0) return to
  var t = Number(elapsedMs) / duration
  if (!isFinite(t) || t <= 0) return from
  if (t >= 1) return to
  var eased = t * t * (3 - 2 * t)
  return from + (to - from) * eased
}

function percentFromLevel(level, maxBrightness) {
  var max = whole(maxBrightness, 1, 1000000)
  var value = whole(level, 0, 1000000)
  if (max === null || value === null) return 0
  return clampPercent(value * 100 / max)
}

function levelFromPercent(percent, maxBrightness) {
  var max = whole(maxBrightness, 1, 1000000)
  if (max === null) return 0
  return Math.round(clampPercent(percent) / 100 * max)
}

function nearestPreset(seconds) {
  var value = whole(seconds, 0, 3600)
  if (value === null) value = 5
  var best = IDLE_PRESETS[0]
  var distance = Math.abs(value - best)
  for (var i = 1; i < IDLE_PRESETS.length; i++) {
    var next = Math.abs(value - IDLE_PRESETS[i])
    if (next < distance) {
      best = IDLE_PRESETS[i]
      distance = next
    }
  }
  return best
}

function stepPreset(seconds, direction) {
  var current = nearestPreset(seconds)
  var index = IDLE_PRESETS.indexOf(current)
  var next = index + (direction < 0 ? -1 : 1)
  if (next < 0) next = 0
  if (next >= IDLE_PRESETS.length) next = IDLE_PRESETS.length - 1
  return IDLE_PRESETS[next]
}

// Fullwidth substitutes cannot open a tag, so a probe field such as
// <img src="https://example.invalid/tracker"> cannot be read as markup.
function neutralize(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/&/g, "\uFF06")
    .replace(/</g, "\uFF1C")
    .replace(/>/g, "\uFF1E")
}

function ledNameOk(value) {
  return /^[A-Za-z0-9_.:-]{1,64}$/.test(String(value || ""))
}

function parseProbe(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  if (text.length === 0 || text.length > MAX_PROBE_CHARS) return { ok: false }
  var fields = {}
  var lines = text.split("\n")
  var count = 0
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue
    count += 1
    if (count > 8) return { ok: false }
    var tab = lines[i].indexOf("\t")
    if (tab <= 0) return { ok: false }
    var key = lines[i].substring(0, tab)
    var value = lines[i].substring(tab + 1).replace(/\s+$/g, "")
    if (fields[key] !== undefined) return { ok: false }
    fields[key] = value
  }
  var led = fields.led || ""
  if (led !== "" && !ledNameOk(led)) return { ok: false }
  var max = led === "" ? 0 : whole(fields.max, 1, 1000000)
  if (led !== "" && max === null) return { ok: false }
  var brightness = led === "" ? 0 : whole(fields.brightness, 0, max)
  if (led !== "" && brightness === null) return { ok: false }
  var kind = fields.kind || "none"
  if (kind !== "lux" && kind !== "raw" && kind !== "none") return { ok: false }
  var lux = null
  if (fields.lux) {
    var sample = Number(fields.lux)
    if (!isFinite(sample) || sample < 0 || sample > 10000000) return { ok: false }
    lux = sample
  }
  if (kind === "none") lux = null
  var locked = fields.locked === "1"
  var lid = fields.lid === "1"
  if (fields.locked !== "0" && fields.locked !== "1") return { ok: false }
  if (fields.lid !== "0" && fields.lid !== "1") return { ok: false }
  return {
    ok: true,
    led: led,
    max: max || 0,
    brightness: brightness || 0,
    lux: lux,
    kind: kind,
    locked: locked,
    lid: lid
  }
}

function statusLine(percent, lux, kind, mode) {
  var level = clampPercent(percent)
  var where = mode === "idle" || mode === "held" || mode === "manual" || mode === "auto" ? mode : "manual"
  if (lux === null || lux === undefined || !isFinite(Number(lux)) || kind === "none")
    return neutralize(level + "%  " + where)
  var unit = kind === "raw" ? "raw" : "lx"
  var shown = Number(lux) < 10 ? Number(lux).toFixed(1) : String(Math.round(Number(lux)))
  return neutralize(level + "%  " + shown + " " + unit + "  " + where)
}
