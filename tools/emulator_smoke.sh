#!/usr/bin/env bash
# Install the APK, launch it, assert the process is alive, MainActivity logged its install
# marker and nothing fatal hit logcat; then S5, the WorkoutService self-test (see below).
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
# The bundled SQLite loads (lib/app/db_probe.dart, printed at startup on the flutter tag).
db="$(timeout 30 adb logcat -d -s flutter:I | grep -E 'GymSupreme/db (ok|FAILED)' | tail -1 || true)"
case "$db" in *"GymSupreme/db ok"*) echo "$db";; *) echo "::error::SQLite did not load on API $sdk: ${db:-no GymSupreme/db line}" >&2; exit 1;; esac

# S5: the WorkoutService starts as a specialUse foreground service from the visible activity,
# shows its notification and fires a self-test cue 3 s in, then stops itself after 20 s. The
# dogfood build has no run-as, so the evidence is the GymSupreme/service log (one JSON line per
# event; the same lines go to the spike log file).
svc_lines() { timeout 30 adb logcat -d -s GymSupreme/service:I || true; }
wait_for() { # wait_for <grep -E pattern> <seconds>: prints the newest matching line
  local i out
  for i in $(seq 1 "$2"); do
    out="$(svc_lines | grep -E "$1" | tail -1)"
    [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 1
  done
  return 1
}
if [ "$sdk" -ge 33 ]; then adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS; fi
adb shell am start -W -n "$PKG/app.gymsupreme.MainActivity" --ez gym_selftest true > /dev/null
started="$(wait_for '"event":"service_started".*"mode":"selftest"' 30)" || {
  echo "S5: no service_started line within 30 s" >&2; svc_lines | tail -n 20 >&2; timeout 60 adb logcat -d | tail -n 100 >&2; exit 1; }
echo "S5 start: $started"
grep -Eq '"outcome":"ok"|fallback=manifest_types:ok' <<< "$started" || { echo "S5: foreground start failed" >&2; exit 1; }
if grep -q 'fallback=manifest_types:ok' <<< "$started"; then echo "::warning::S5 API $sdk used manifest_types fallback (specialUse alone was refused)"; fi
fg="$(adb shell dumpsys activity services "$PKG" | tr -d '\r' | grep -E 'isForeground=true' | head -1 || true)"
[ -n "$fg" ] || { echo "S5: service is not foreground" >&2; adb shell dumpsys activity services "$PKG" | tail -n 40 >&2; exit 1; }
echo "S5 foreground: $fg"
echo "S5 types: $(adb shell dumpsys activity services "$PKG" | tr -d '\r' | grep -oE '(foregroundServiceType|types)=[^ ]+' | sort -u | tr '\n' ' ' || true)"
noti="$(adb shell dumpsys notification --noredact | tr -d '\r' | grep -E "pkg=$PKG .*id=2001" | head -1 || true)"
[ -n "$noti" ] || { echo "S5: workout notification not posted" >&2; adb shell dumpsys notification --noredact | grep -A3 "$PKG" | head -n 40 >&2; exit 1; }
echo "S5 notification: $noti"
cue="$(wait_for '"event":"cue".*"kind":"selftest"' 20)" || { echo "S5: self-test cue did not fire" >&2; svc_lines | tail -n 20 >&2; exit 1; }
echo "S5 cue: $cue"
stopped="$(wait_for '"event":"service_stopped".*"reason":"selftest_done"' 40)" || { echo "S5: service did not stop itself" >&2; svc_lines | tail -n 20 >&2; exit 1; }
echo "S5 stop: $stopped"
fatal_check "$PKG" service

# Session path (phase-1 exit: rest alert covered, crash-safe resume). A schema-v1 snapshot goes
# through LiveSession as Dart sends it: journal line, service start, 3 s rest, alert. Then the
# process is killed and relaunched: the journal must be found. Then finish + delete.
session_step() { adb shell am start -W -n "$PKG/app.gymsupreme.MainActivity" --es gym_selftest_session "$1" > /dev/null; }
session_step start
s_start="$(wait_for '"event":"selftest_session".*"step":"start".*"ok":true' 30)" || {
  echo "session: start refused" >&2; svc_lines | grep -E 'selftest_session|session_|journal' | tail -n 10 >&2; exit 1; }
echo "session start: $s_start"
alert="$(wait_for '"event":"rest_alert"' 30)" || { echo "session: no rest alert within 30 s" >&2; svc_lines | tail -n 20 >&2; exit 1; }
echo "session rest alert: $alert"
noti="$(adb shell dumpsys notification --noredact | tr -d '\r' | grep -E "pkg=$PKG .*id=2001" | head -1 || true)"
[ -n "$noti" ] || { echo "session: workout notification not posted" >&2; exit 1; }
adb shell am force-stop "$PKG"
sleep 2
launch "$PKG" || { echo "session: relaunch after force-stop failed" >&2; exit 1; }
session_step pending
pending="$(wait_for '"event":"selftest_session".*"step":"pending".*"found":true' 30)" || {
  echo "session: journal not found after force-stop" >&2; svc_lines | grep -E 'selftest_session|journal' | tail -n 10 >&2; exit 1; }
echo "session resume: $pending"
session_step finish
fin="$(wait_for '"event":"selftest_session".*"step":"finish".*"finished":true,"deleted":true' 30)" || {
  echo "session: finish + delete failed" >&2; svc_lines | grep -E 'selftest_session|session_|journal' | tail -n 10 >&2; exit 1; }
echo "session finish: $fin"
fatal_check "$PKG" session
echo "smoke ok on API $sdk"
