#!/bin/sh
# Read the keyboard LED and the ambient light sensor. No arguments.
# Paths come from sysfs globs. The service accepts the output only after
# Model.parseProbe bounds every field.

set -eu

led=""
max=""
brightness=""
for candidate in /sys/class/leds/*kbd_backlight*; do
  [ -d "$candidate" ] || continue
  [ -r "$candidate/brightness" ] || continue
  [ -r "$candidate/max_brightness" ] || continue
  led=$(basename "$candidate")
  max=$(tr -d '[:space:]' < "$candidate/max_brightness")
  brightness=$(tr -d '[:space:]' < "$candidate/brightness")
  break
done

best=""
kind="none"
for candidate in /sys/bus/iio/devices/iio:device*; do
  [ -d "$candidate" ] || continue
  [ -r "$candidate/name" ] || continue
  [ -r "$candidate/in_illuminance_input" ] || continue
  name=$(tr -d '[:space:]' < "$candidate/name")
  case "$name" in
    *als*|*ALS*)
      best=$candidate
      kind="lux"
      break
      ;;
  esac
done

if [ -z "$best" ]; then
  for candidate in /sys/bus/iio/devices/iio:device*; do
    [ -d "$candidate" ] || continue
    [ -r "$candidate/in_illuminance_input" ] || continue
    best=$candidate
    kind="lux"
    break
  done
fi

if [ -z "$best" ]; then
  for candidate in /sys/bus/iio/devices/iio:device*; do
    [ -d "$candidate" ] || continue
    [ -r "$candidate/in_illuminance_raw" ] || continue
    best=$candidate
    kind="raw"
    break
  done
fi

lux=""
if [ -n "$best" ]; then
  if [ "$kind" = "lux" ]; then
    lux=$(tr -d '[:space:]' < "$best/in_illuminance_input")
  else
    raw=$(tr -d '[:space:]' < "$best/in_illuminance_raw")
    scale=1
    if [ -r "$best/in_illuminance_scale" ]; then
      scale=$(tr -d '[:space:]' < "$best/in_illuminance_scale")
    fi
    lux=$(awk -v raw="$raw" -v scale="$scale" 'BEGIN { printf "%.6f", raw * scale }')
  fi
fi

locked=0
if command -v timeout >/dev/null 2>&1 && command -v omarchy-shell >/dev/null 2>&1; then
  state=$(timeout 1 omarchy-shell lock isLocked 2>/dev/null || true)
  [ "$state" = "true" ] && locked=1
fi

lid=0
if command -v timeout >/dev/null 2>&1 && command -v omarchy-hw-laptop-closed >/dev/null 2>&1; then
  if timeout 1 omarchy-hw-laptop-closed >/dev/null 2>&1; then
    lid=1
  fi
fi

printf 'led\t%s\n' "$led"
printf 'max\t%s\n' "$max"
printf 'brightness\t%s\n' "$brightness"
printf 'lux\t%s\n' "$lux"
printf 'kind\t%s\n' "$kind"
printf 'locked\t%s\n' "$locked"
printf 'lid\t%s\n' "$lid"
