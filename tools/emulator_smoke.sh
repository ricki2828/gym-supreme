#!/usr/bin/env bash
# Install the APK, launch it, assert the process is alive, MainActivity logged its install
# marker and nothing fatal hit logcat. Lane B extends this with the WorkoutService start (S5).
# Usage: tools/emulator_smoke.sh <apk> <package>
set -euo pipefail
APK="${1:?apk}"; PKG="${2:?package}"
. "$(dirname "$0")/emulator_common.sh"
boot_wait
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
adb logcat -c || true
adb install -r "$APK"
if ! launch "$PKG"; then
  echo "process $PKG is not running after launch" >&2; timeout 60 adb logcat -d | tail -n 200; exit 1
fi
fatal_check "$PKG" launch
line="$(marker_line)"
[ -n "$line" ] || { echo "no install-marker log line from MainActivity" >&2; timeout 60 adb logcat -d | tail -n 100; exit 1; }
echo "$line"
echo "smoke ok on API $sdk"
