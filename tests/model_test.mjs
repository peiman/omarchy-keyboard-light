import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const source = readFileSync(join(root, "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const model = new Function(source + `
return {
  withDefaults, mapLux, ambientPercent, desiredPercent, smooth, isExternal,
  holdReleased, approach, fadeDuration, fadePercent, percentFromLevel, levelFromPercent,
  nearestPreset, stepPreset, parseProbe, statusLine, neutralize, ledNameOk, OVERRIDE_LUX
};
`)()

let failed = 0

function check(name, condition) {
  if (condition) {
    console.log("ok " + name)
    return
  }
  failed += 1
  console.log("FAIL " + name)
}

const dark = model.withDefaults({})
check("dark room is full", model.mapLux(0, dark.luxDark, dark.luxBright, 0, 100) === 100)
check("eight lux is still full", model.mapLux(8, 8, 180, 0, 100) === 100)
check("bright room is off", model.mapLux(180, 8, 180, 0, 100) === 0)
check("brighter room stays off", model.mapLux(400, 8, 180, 0, 100) === 0)
check("midpoint is half", model.mapLux(94, 8, 180, 0, 100) === 50)
check("custom ends are honored", model.mapLux(0, 8, 180, 10, 80) === 80)
check("crossed thresholds step at dark", model.mapLux(5, 20, 10, 0, 100) === 100)
check("crossed thresholds step past dark", model.mapLux(21, 20, 10, 0, 100) === 0)

check("idle forces off", model.desiredPercent(dark, 1, true, false, 0, true) === 0)
check("idle zero keeps the room", model.desiredPercent(
  Object.assign({}, dark, { idleSeconds: 0 }), 1, true, false, 0, true) === 100)
check("manual ignores the room", model.ambientPercent(
  Object.assign({}, dark, { auto: false, manualPercent: 40 }), 1, true, false, 0) === 40)
check("hold keeps the chosen level", model.ambientPercent(dark, 1, true, true, 25) === 25)
check("no sensor uses the manual level", model.ambientPercent(dark, null, false, false, 0) === 40)

check("smoothing takes the first sample", model.smooth(null, 12, 0.4) === 12)
check("smoothing keeps some of the last sample", Math.abs(model.smooth(10, 0, 0.5) - 5) < 0.001)

check("a brightness key is external", model.isExternal(128, 25, 255) === true)
check("our own step is not external", model.isExternal(26, 25, 255) === false)
check("an unknown baseline is not external", model.isExternal(25, -1, 255) === false)
check("hold releases after twenty lux", model.holdReleased(30, 8, model.OVERRIDE_LUX) === true)
check("hold stays inside twenty lux", model.holdReleased(20, 8, model.OVERRIDE_LUX) === false)

check("approach finishes inside one step", model.approach(96, 100, 8) === 100)
check("approach walks toward the target", model.approach(0, 100, 8) === 8)
check("a full fade lasts a second and a half", model.fadeDuration(0, 100) === 1500)
check("a short fade still eases", model.fadeDuration(0, 10) === 400)
check("fade starts at the current level", model.fadePercent(0, 100, 0, 1500) === 0)
check("fade ends at the target", model.fadePercent(100, 0, 1500, 1500) === 0)
check("fade is halfway at the midpoint", model.fadePercent(0, 100, 750, 1500) === 50)
check("level rounds from percent", model.levelFromPercent(50, 255) === 128)
check("percent rounds from level", model.percentFromLevel(255, 255) === 100)

check("idle preset snaps", model.nearestPreset(7) === 5)
check("idle preset steps up", model.stepPreset(5, 1) === 10)
check("idle preset stays at the end", model.stepPreset(300, 1) === 300)

const attack = '<img src="https://example.invalid/tracker">'
const clean = model.neutralize(attack)
check("markup brackets are gone", !clean.includes("<") && !clean.includes(">") && !clean.includes(attack))
check("status line cannot carry a tag", !model.statusLine(40, 3, "lux", attack).includes("<"))
check("device names stay plain ids", model.ledNameOk("kbd_backlight") && !model.ledNameOk(attack))

function probe(fields) {
  return Object.keys(fields).map(function(key) { return key + "\t" + fields[key] }).join("\n") + "\n"
}

const happy = model.parseProbe(probe({
  led: "kbd_backlight", max: "255", brightness: "25", lux: "2.027488", kind: "lux", locked: "0", lid: "0"
}))
check("probe reads this mac", happy.ok && happy.led === "kbd_backlight" && happy.max === 255 && happy.brightness === 25)
check("probe keeps fractional lux", happy.ok && Math.abs(happy.lux - 2.027488) < 0.0001)
check("probe sees an open lid", happy.ok && happy.locked === false && happy.lid === false)

const tagged = model.parseProbe(probe({
  led: attack, max: "255", brightness: "0", lux: "1", kind: "lux", locked: "0", lid: "0"
}))
check("probe rejects a tagged device name", tagged.ok === false)

const huge = model.parseProbe("led\tkbd_backlight\n" + "x".repeat(3000))
check("probe rejects a huge sample", huge.ok === false)

const over = model.parseProbe(probe({
  led: "kbd_backlight", max: "255", brightness: "999", lux: "", kind: "none", locked: "0", lid: "0"
}))
check("probe rejects a level past the maximum", over.ok === false)

const missing = model.parseProbe(probe({
  led: "", max: "", brightness: "", lux: "", kind: "none", locked: "0", lid: "0"
}))
check("probe allows a machine with no keyboard light", missing.ok && missing.led === "")

check("defaults match the mac curve", dark.luxDark === 8 && dark.luxBright === 180 && dark.idleSeconds === 5 && dark.auto === true)
check("zero idle is kept", model.withDefaults({ idleSeconds: 0 }).idleSeconds === 0)
check("auto false is kept", model.withDefaults({ auto: false }).auto === false)

if (failed) {
  console.log(failed + " failed")
  process.exit(1)
}
console.log("all passed")
