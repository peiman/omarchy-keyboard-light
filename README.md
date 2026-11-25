# Keyboard light

An [Omarchy](https://omarchy.org) shell plugin that drives the keyboard backlight the way a Mac does.

- In a dark room the keys come on. In a bright room they go off. Between 8 and 180 lux the level falls in a straight line. Those two points are the defaults and can be changed.
- After you stop typing the light fades out. The next key or touch brings it back. The default wait is 5 seconds. A video that keeps the screen awake does not keep the keys lit.
- A full change eases over 1.5 seconds. The Fade slider in the panel runs from 0.2 seconds to 4 seconds. A smaller change takes less of that time.
- Ctrl and the display-brightness keys (or a real keyboard-brightness key) set a level by hand. Automatic control waits until the room light moves by about 20 lux, then takes over again.
- While the screen is locked, or the lid is closed, the plugin stops writing so Omarchy can turn the keys off.

It talks to `brightnessctl` and reads the ambient sensor from sysfs. There is no daemon, no network access, and no extra package. `brightnessctl` is already part of Omarchy.

The defaults were chosen for Apple Silicon MacBooks, whose sensor reports calibrated lux on `in_illuminance_input`. A machine whose sensor only exposes `in_illuminance_raw` still works; the panel's "use the reading" buttons are how you set the two thresholds for that sensor. With no sensor at all, the plugin is a manual level plus the idle timeout.

## Install

```bash
omarchy plugin add https://github.com/peiman/omarchy-keyboard-light --enable
```

The button lands on the right side of the bar. Move it with:

```bash
omarchy bar move io.github.peiman.keyboard-light --section right
```

## Use

| Action | Result |
| --- | --- |
| Click the icon | Open the panel |
| Right-click | Follow the room, or stop |
| Scroll | Set a level by hand |
| j / k | Move between rows |
| h / l | Adjust the row |
| a | Follow the room, or stop |
| Enter | On a threshold, use the current reading |

The icon fades with the keys.

## Remove

```bash
omarchy plugin remove io.github.peiman.keyboard-light --yes
```

The keys stay at whatever level they had. Removal does not edit anything outside the plugin's own bar entry.

## Requirements

- Omarchy with the Quickshell bar
- `brightnessctl`
- A keyboard LED at `/sys/class/leds/*kbd_backlight*`

An ambient sensor is optional. Apple Silicon exposes it as `aop-sensors-als`.

## License

MIT. See [LICENSE](LICENSE).
