#!/usr/bin/env bash
# T1 proof ladder step 2 (0.3 plan): a timer block run by the WorkoutService with the screen off,
# Flutter detached and the device forced into Doze idle. The app must already be installed and
# the notification permission granted (tools/emulator_smoke.sh runs first).
# Usage: tools/emulator_emom.sh <package> <rounds> <period_ms> <lead_in_ms>
# timers ON (GS_FEATURES): pass = rounds emom_minute + 1 block_end cue for this workout, each index
# once, none missed, max late <= 1000 ms, and the mid-block re-submit kept the anchor (timer_kept).
# timers OFF: the block is logged as ignored and no cue fires.
# Evidence is the GymSupreme/service log (the same JSON lines go to the spike log file).
set -euo pipefail
PKG="${1:?package}"; ROUNDS="${2:?rounds}"; PERIOD="${3:?period_ms}"; LEAD="${4:?lead_in_ms}"
. "$(dirname "$0")/emulator_common.sh"
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
flag_on() { # same rule as lib/app/feature_flags.dart and core/flags/FeatureSet.kt
  local x xs
  [ "${GS_FEATURES:-}" = "all" ] && return 0
  IFS=',' read -ra xs <<< "${GS_FEATURES:-}"
  for x in "${xs[@]}"; do
    x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"
    [ "$x" = "$1" ] && return 0
  done
  return 1
}
timers=0; flag_on timers && timers=1
# Pull requests always build with timers (tools/ci_features.sh): never smoke flag-off by accident.
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ "$timers" != 1 ]; then
  echo "::error::pull request build without timers (GS_FEATURES='${GS_FEATURES:-}')" >&2; exit 1
fi
nfeat="$(timeout 30 adb logcat -d -s GymSupreme/features:I | grep -o 'native .*' | tail -1 || true)"
echo "T1 features: GS_FEATURES='${GS_FEATURES:-}' timers=$timers, last native line: ${nfeat:-none in buffer}"
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
restore() {
  adb shell dumpsys deviceidle unforce > /dev/null 2>&1 || true
  adb shell dumpsys battery reset > /dev/null 2>&1 || true
  adb shell input keyevent KEYCODE_WAKEUP || true
  adb shell wm dismiss-keyguard > /dev/null 2>&1 || true
}
trap restore EXIT

if [ "$sdk" -ge 33 ]; then adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS || true; fi
# 16 MB ring buffer: the 20-minute nightly reads every line back at the end (review P2, PR #56).
adb logcat -G 16M || true
adb logcat -c || true
adb shell am start -W -n "$PKG/app.gymsupreme.MainActivity" --es gym_selftest_session "emom:$ROUNDS:$PERIOD:$LEAD" > /dev/null
st="$(wait_for '"event":"selftest_session".*"step":"emom:' 40)" || { echo "::error::T1: emom step did not run" >&2; svc_lines | tail -n 20 >&2; exit 1; }
echo "T1 emom start: $st"
grep -q '"ok":true' <<< "$st" || { echo "::error::T1: emom step failed: $st" >&2; exit 1; }
uuid="$(sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p' <<< "$st" | head -1)"
[ -n "$uuid" ] || { echo "::error::T1: no uuid in the emom step line" >&2; exit 1; }
# Screen off (explicit sleep, not the power toggle), on battery, forced into deep idle (Doze).
sleep 2
adb shell input keyevent KEYCODE_SLEEP
adb shell dumpsys battery unplug || true
adb shell dumpsys deviceidle enable deep > /dev/null 2>&1 || true
echo "T1 force-idle: $(adb shell dumpsys deviceidle force-idle 2>&1 | tr -d '\r' | tr '\n' ' ')"
deep="$(adb shell dumpsys deviceidle get deep | tr -d '\r')"
wake="$(adb shell dumpsys power | tr -d '\r' | grep -m1 -oE 'mWakefulness=[A-Za-z]+' || true)"
echo "T1 idle state: deep=$deep screen=$wake"
# The proof is screen off + Doze: fail rather than pass a run that never got there.
[ "$deep" = "IDLE" ] || { echo "::error::T1: device not in deep idle (deep=$deep)" >&2; exit 1; }
case "$wake" in mWakefulness=Asleep|mWakefulness=Dozing) ;; *) echo "::error::T1: screen not off ($wake)" >&2; exit 1 ;; esac

total=$((ROUNDS + 1))
end_s=$(( (LEAD + ROUNDS * PERIOD) / 1000 ))
cue_lines() { svc_lines | grep -F '"event":"cue"' | grep -F "\"set_id\":\"$uuid:0\"" || true; }
if [ "$timers" = 1 ]; then
  for i in $(seq 1 $((end_s + 90))); do
    [ "$(cue_lines | wc -l)" -ge "$total" ] && break
    sleep 1
  done
  # A few more seconds: a duplicate would show up after the last expected cue.
  sleep 5
else
  sleep $(( (LEAD + PERIOD) / 1000 + 10 ))
fi
deep_end="$(adb shell dumpsys deviceidle get deep | tr -d '\r')"
echo "T1 idle state at end: deep=$deep_end"
[ "$deep_end" = "IDLE" ] || { echo "::error::T1: device left deep idle during the block (deep=$deep_end)" >&2; exit 1; }
svc_lines | grep -E '"event":"(timer_[a-z_]+|emom_reapply)"' | sed 's/^.*GymSupreme\/service: */T1 log: /' || true
restore

if [ "$timers" = 0 ]; then
  [ "$(cue_lines | wc -l)" -eq 0 ] || { echo "::error::T1: timers off but cues fired" >&2; cue_lines >&2; exit 1; }
  svc_lines | grep -F '"event":"timer_ignored"' | grep -qF "\"set_id\":\"$uuid:0\"" \
    || { echo "::error::T1: timers off but no timer_ignored line for the block" >&2; exit 1; }
  svc_lines | grep -qF '"event":"timer_armed"' && { echo "::error::T1: timers off but a block was armed" >&2; exit 1; }
  echo "T1 API $sdk: timers off, block ignored, 0 cues"
else
  svc_lines | grep -F '"event":"emom_reapply"' | grep -q '"ok":true' || { echo "::error::T1: the mid-block re-submit failed" >&2; exit 1; }
  svc_lines | grep -F '"event":"timer_kept"' | grep -qF "\"set_id\":\"$uuid:0\"" || { echo "::error::T1: the re-submitted block was not kept (re-anchored?)" >&2; exit 1; }
  [ "$(svc_lines | grep -F '"event":"timer_armed"' | grep -cF "\"set_id\":\"$uuid:0\"")" -eq 1 ] || { echo "::error::T1: the block was armed more than once" >&2; exit 1; }
  cue_lines | python3 "$(dirname "$0")/emom_check.py" "$ROUNDS" "API $sdk"
fi

# Clean up as the session smoke does: kill, relaunch, finish + delete the selftest journal.
adb shell am force-stop "$PKG"
sleep 2
launch "$PKG" || { echo "::error::T1: relaunch for clean-up failed" >&2; exit 1; }
adb shell am start -W -n "$PKG/app.gymsupreme.MainActivity" --es gym_selftest_session finish > /dev/null
fin="$(wait_for '"event":"selftest_session".*"step":"finish".*"finished":true,"deleted":true' 30)" || {
  echo "::error::T1: finish + delete after the emom run failed" >&2; svc_lines | grep -E 'selftest_session|journal' | tail -n 10 >&2; exit 1; }
echo "T1 finish: $fin"
fatal_check "$PKG" "T1 emom"
