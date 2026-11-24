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
# The build's cut-2 flags match GS_FEATURES (CI env; repo variable, default empty = all off).
feat="$(timeout 30 adb logcat -d -s flutter:I | grep -o 'GymSupreme/features.*' | tail -1 || true)"
[ -n "$feat" ] || { echo "::error::no GymSupreme/features line" >&2; exit 1; }
echo "$feat"
# Native flags (N0): GS_FEATURES decoded from BuildConfig.DART_DEFINES (the same --dart-define list).
nfeat="$(timeout 30 adb logcat -d -s GymSupreme/features:I | grep -o 'native .*' | tail -1 || true)"
[ -n "$nfeat" ] || { echo "::error::no native GymSupreme/features line" >&2; exit 1; }
echo "GymSupreme/features $nfeat"
echo "features built into this APK (GS_FEATURES): '${GS_FEATURES:-}'"
# Same rule as lib/app/feature_flags.dart and core/flags/FeatureSet.kt: "all" only as the whole
# string, otherwise a comma list of trimmed names.
flag_on() {
  local x xs
  [ "${GS_FEATURES:-}" = "all" ] && return 0
  IFS=',' read -ra xs <<< "${GS_FEATURES:-}"
  for x in "${xs[@]}"; do
    x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"
    [ "$x" = "$1" ] && return 0
  done
  return 1
}
# Exactly these six flags, in this order, on both lines: an extra or renamed flag fails here.
flag_names="timers ghost rotation plates lockdone health"
for line in "${feat#GymSupreme/features }" "${nfeat#native }"; do
  got="$(grep -oE '[a-z]+=[01]' <<< "$line" | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//')"
  [ "$got" = "$flag_names" ] || { echo "::error::feature line names '$got', expected '$flag_names': $line" >&2; exit 1; }
done
for f in $flag_names; do
  want=0; flag_on "$f" && want=1
  grep -q " $f=$want" <<< " ${feat#GymSupreme/features }" || { echo "::error::feature $f should be $want (GS_FEATURES='${GS_FEATURES:-}'): $feat" >&2; exit 1; }
  grep -q " $f=$want" <<< " ${nfeat#native }" || { echo "::error::native feature $f should be $want (GS_FEATURES='${GS_FEATURES:-}'): $nfeat" >&2; exit 1; }
done
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
# e2e helpers (lib/app/e2e_driver.dart), used by the ask check and the e2e flows below.
e2e_lines() { timeout 30 adb logcat -d -s flutter:I | sed -n 's/.*GymSupreme\/e2e //p' | grep -F "\"nonce\":\"$NONCE\"" || true; }
e2e_cmd() { NONCE="$1-$RANDOM$RANDOM"; adb shell am start -W -n "$PKG/app.gymsupreme.MainActivity" --es gym_e2e "$1:$NONCE" > /dev/null; }
e2e_field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }
e2e_wait() { # e2e_wait <step> <seconds>: fails fast on an error or refused step
  local i
  for i in $(seq 1 "$2"); do
    if e2e_lines | grep -qE '"step":"(error|refused)"'; then echo "e2e failed:" >&2; e2e_lines | tail -n 12 >&2; exit 1; fi
    e2e_lines | grep -q "\"step\":\"$1\"" && return 0
    sleep 1
  done
  echo "e2e: no $1 step within $2 s" >&2; e2e_lines | tail -n 12 >&2; timeout 60 adb logcat -d | tail -n 60 >&2; exit 1
}

# Notification ask (t3x, 0.1.1): on a fresh install the app's one-time ask must show the system
# permission dialog on API 33+ (and resolve without one below 33). Runs BEFORE any pm grant.
ask_lines() { timeout 30 adb logcat -d -s GymSupreme/service:I | grep -E '"event":"notif_request' || true; }
adb logcat -c || true
e2e_cmd ask
if [ "$sdk" -ge 33 ]; then
  for i in $(seq 1 30); do ask_lines | grep -q '"event":"notif_request_shown"' && break; sleep 1; done
  ask_lines | grep -q '"event":"notif_request_shown"' || { echo "::error::API $sdk: the notification ask was never shown" >&2; e2e_lines | tail -n 5 >&2; exit 1; }
  sleep 2
  focus="$(adb shell dumpsys window | tr -d '\r' | grep -E 'mCurrentFocus|mFocusedApp' | head -2)"
  echo "ask focus: $focus"
  grep -qi 'permissioncontroller' <<< "$focus" || { echo "::error::API $sdk: permission dialog not in front" >&2; exit 1; }
  # Tap the real Allow button, as Ricki would (uiautomator gives its bounds).
  adb shell uiautomator dump /sdcard/ui.xml > /dev/null 2>&1 || true
  allow="$(adb shell cat /sdcard/ui.xml 2>/dev/null | tr -d '\r' | grep -o 'resource-id="com.android.permissioncontroller:id/permission_allow_button"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | grep -o 'bounds="[^"]*"' | head -1)"
  [ -n "$allow" ] || { echo "::error::API $sdk: no Allow button in the permission dialog" >&2; exit 1; }
  read -r x1 y1 x2 y2 <<< "$(grep -oE '[0-9]+' <<< "$allow" | tr '\n' ' ')"
  adb shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))
  for i in $(seq 1 20); do ask_lines | grep -q '"event":"notif_request".*"asked":true' && break; sleep 1; done
  ask_lines | grep -q '"event":"notif_request".*"result":true.*"asked":true\|"event":"notif_request".*"asked":true.*"result":true' \
    || { echo "::error::API $sdk: Allow did not resolve the ask as granted" >&2; ask_lines >&2; exit 1; }
fi
e2e_wait ok 30
e2e_lines | sed 's/^/ask: /'
e2e_lines | grep '"step":"ask"' | grep -q '"allowed":true' || { echo "::error::API $sdk: the ask did not end allowed" >&2; exit 1; }
if [ "$sdk" -lt 33 ] && ask_lines | grep -q '"event":"notif_request_shown"'; then
  echo "::error::API $sdk: a dialog was asked for below Android 13" >&2; exit 1
fi
ask_lines | sed 's/^/ask: /'

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
# The session's ongoing notification is id 2003 (WorkoutNotification.SESSION_ID); the service is foreground.
noti=""
for i in 1 2 3 4 5; do
  noti="$(adb shell dumpsys notification --noredact | tr -d '\r' | grep -E "pkg=$PKG .*id=2003" | head -1 || true)"
  [ -n "$noti" ] && break
  sleep 1
done
[ -n "$noti" ] || {
  echo "session: workout notification (id 2003) not posted" >&2
  adb shell dumpsys notification --noredact | tr -d '\r' | grep -E "pkg=$PKG" | head -n 10 >&2 || true
  adb shell dumpsys activity services "$PKG" | tr -d '\r' | grep -E 'ServiceRecord|isForeground' | head -n 10 >&2 || true
  svc_lines | grep -E 'service_|session_|rest_' | tail -n 10 >&2; exit 1; }
echo "session notification: $noti"
sfg="$(adb shell dumpsys activity services "$PKG" | tr -d '\r' | grep -E 'isForeground=true' | head -1 || true)"
[ -n "$sfg" ] || { echo "session: service is not foreground" >&2; exit 1; }
# L1 lock-screen Done (0.3): the selftest takes the notification's own Done PendingIntent, closes
# the activity (Flutter detaches), and 5 s later, with the screen off, fires it twice (double
# tap) and once more after the notification moved on (stale). lockdone on: exactly one set is
# logged, with Flutter gone. lockdone off: no buttons, and the receiver ignores the intent.
lockdone=0; flag_on lockdone && lockdone=1
# Pull requests always build with lockdone (tools/ci_features.sh): never smoke flag-off by accident.
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && { [ "$lockdone" != 1 ] || ! grep -q " lockdone=1" <<< " ${nfeat#native }"; }; then
  echo "::error::pull request build without lockdone on the native line: $nfeat" >&2; exit 1
fi
session_step lock_fire
lf="$(wait_for '"event":"selftest_session".*"step":"lock_fire"' 30)" || { echo "L1: lock_fire step did not run" >&2; svc_lines | tail -n 10 >&2; exit 1; }
echo "L1 lock_fire: $lf"
grep -q '"ok":true' <<< "$lf" || { echo "::error::L1: lock_fire failed: $lf" >&2; exit 1; }
if [ "$lockdone" = 1 ]; then
  grep -q '"actions":"Done|+1 rep' <<< "$lf" || { echo "::error::L1: no Done/+1 rep buttons with lockdone on: $lf" >&2; exit 1; }
  grep -q '"from_notification":true' <<< "$lf" || { echo "::error::L1: Done intent did not come from the notification" >&2; exit 1; }
else
  grep -q '"actions":""' <<< "$lf" || { echo "::error::L1: lockdone off but the notification has actions: $lf" >&2; exit 1; }
fi
adb shell input keyevent KEYCODE_SLEEP
lock_lines() { svc_lines | grep -o '{"event":"lock_action"[^}]*}' || true; }
for i in $(seq 1 45); do [ "$(lock_lines | wc -l)" -ge 3 ] && break; sleep 1; done
lock_lines | sed 's/^/L1 action: /'
[ "$(lock_lines | wc -l)" -eq 3 ] || { echo "::error::L1: expected 3 lock_action lines (first, double, stale)" >&2; svc_lines | tail -n 15 >&2; exit 1; }
if [ "$lockdone" = 1 ]; then
  [ "$(lock_lines | grep -c '"outcome":"applied"')" -eq 1 ] || { echo "::error::L1: not exactly one applied Done" >&2; exit 1; }
  lock_lines | grep '"outcome":"applied"' | grep -q '"dart_listening":false' || { echo "::error::L1: Flutter was still attached when Done applied" >&2; exit 1; }
  lock_lines | grep -v '"outcome":"applied"' | grep -qvE '"outcome":"(debounced|stale_rev)"' && { echo "::error::L1: a repeat tap was neither debounced nor stale" >&2; exit 1; }
  lock_lines | tail -1 | grep -q '"outcome":"stale_rev"' || { echo "::error::L1: the tap on the stale notification was not refused as stale_rev" >&2; exit 1; }
else
  [ "$(lock_lines | grep -c '"outcome":"flag_off"')" -eq 3 ] || { echo "::error::L1: lockdone off but an action was not ignored" >&2; exit 1; }
fi
lfg="$(adb shell dumpsys activity services "$PKG" | tr -d '\r' | grep -E 'isForeground=true' | head -1 || true)"
[ -n "$lfg" ] || { echo "::error::L1: the service did not stay foreground through the lock-screen Done" >&2; exit 1; }
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard || true
fatal_check "$PKG" "lock-screen done"
adb shell am force-stop "$PKG"
sleep 2
launch "$PKG" || { echo "session: relaunch after force-stop failed" >&2; exit 1; }
session_step pending
pending="$(wait_for '"event":"selftest_session".*"step":"pending".*"found":true' 30)" || {
  echo "session: journal not found after force-stop" >&2; svc_lines | grep -E 'selftest_session|journal' | tail -n 10 >&2; exit 1; }
echo "session resume: $pending"
# L1: after the kill and reopen the lock-screen set is in the journal, once, with the shown
# weight; Done on the last set did not finish the workout.
if [ "$lockdone" = 1 ]; then
  grep -q '"rev":1,"finished":false,"lockscreen_sets":1,"lock_load_g":20000,"lock_reps":10,"lock_completion":"tap_unchanged"' <<< "$pending" \
    || { echo "::error::L1: reopened journal does not hold exactly the one lock-screen set (20 kg x 10, rev 1, not finished): $pending" >&2; exit 1; }
else
  grep -q '"rev":0,"finished":false,"lockscreen_sets":0' <<< "$pending" || { echo "::error::L1: lockdone off but the journal moved: $pending" >&2; exit 1; }
fi
session_step finish
fin="$(wait_for '"event":"selftest_session".*"step":"finish".*"finished":true,"deleted":true' 30)" || {
  echo "session: finish + delete failed" >&2; svc_lines | grep -E 'selftest_session|session_|journal' | tail -n 10 >&2; exit 1; }
echo "session finish: $fin"
fatal_check "$PKG" session

# Starting weights (0.3 S1), before the flows below log anything: a 20 kg starting weight on a chest lift
# with no history must be the planned load and the live set's target; the workout is discarded
# and the weight cleared, so nothing is left behind for the flows below.
adb logcat -c || true
e2e_cmd start_weight
e2e_wait ok 90
e2e_lines | sed 's/^/e2e start_weight: /'
sw="$(e2e_lines | grep '"step":"start_weight"')"
for k in start_load_g plan_load_g target_load_g; do
  grep -q "\"$k\":20000" <<< "$sw" || { echo "::error::starting weight: $k is not 20000 g: $sw" >&2; exit 1; }
done
e2e_lines | grep '"step":"start_weight_done"' | grep -q '"discarded":true' || { echo "::error::starting weight drill: workout not discarded" >&2; exit 1; }
fatal_check "$PKG" "e2e start_weight"

# Phase-1 exit e2e (lib/app/e2e_driver.dart): the real Dart flow through LiveController, the
# SQLite store and the WorkoutService, driven by the gym_e2e launch extra (dogfood/debug only).
# Each command carries a nonce that the driver echoes in every line: only lines from THIS
# command count, so a failed `logcat -c` cannot produce a false pass.
adb logcat -c || true
e2e_cmd run
e2e_wait ok 120
e2e_lines | sed 's/^/e2e run: /'
fin="$(e2e_lines | grep '"step":"finish"')"
grep -q '"stored":true' <<< "$fin" && grep -q '"journal_gone":true' <<< "$fin" || { echo "e2e: finish not stored or journal left" >&2; exit 1; }
[ "$(e2e_field uuid <<< "$fin")" = "$(e2e_field history_top <<< "$fin")" ] || { echo "e2e: finished workout is not the newest history row" >&2; exit 1; }
fatal_check "$PKG" "e2e run"
# Crash-safe resume: start a workout, log a set, kill the process, relaunch, resume, finish.
adb logcat -c || true
e2e_cmd start_only
e2e_wait set1 60
started_uuid="$(e2e_lines | grep '"step":"start"' | e2e_field uuid)"
[ -n "$started_uuid" ] || { echo "e2e: no uuid from start_only" >&2; exit 1; }
adb shell am force-stop "$PKG"
sleep 2
adb logcat -c || true
e2e_cmd resume
e2e_wait ok 90
e2e_lines | sed 's/^/e2e resume: /'
e2e_lines | grep '"step":"recover"' | grep -q '"action":"offerResume"' || { echo "e2e: the killed workout was not offered for resume" >&2; exit 1; }
[ "$(e2e_lines | grep '"step":"finish"' | e2e_field uuid)" = "$started_uuid" ] || { echo "e2e: resumed a different workout than the one killed" >&2; exit 1; }
fatal_check "$PKG" "e2e resume"
# Discard (0.2.1 D2): start, log 2 sets, discard (pause, then delete the journal). The journal is
# gone, nothing is stored, the service accepts a fresh start (no already_running), and a
# force-stop + relaunch finds no Resume and no new workout.
count_of() { sed -n 's/.*"count":\([0-9]*\).*/\1/p' | head -1; }
adb logcat -c || true
e2e_cmd history
e2e_wait ok 30
count_before="$(e2e_lines | grep '"step":"history"' | count_of)"
[ -n "$count_before" ] || { echo "::error::API $sdk: discard: no history count" >&2; exit 1; }
adb logcat -c || true
e2e_cmd discard
e2e_wait ok 90
e2e_lines | sed 's/^/e2e discard: /'
d="$(e2e_lines | grep '"step":"discard"')"
grep -q '"ok":true' <<< "$d" && grep -q '"journal_gone":true' <<< "$d" && grep -q '"stored":false' <<< "$d" \
  || { echo "::error::API $sdk: discard incomplete: $d" >&2; exit 1; }
num_of() { sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p" | head -1; }  # one numeric JSON field, any key order
hist_before="$(num_of history_before <<< "$d")"
hist_after="$(num_of history_after <<< "$d")"
[ -n "$hist_before" ] && [ "$hist_before" = "$hist_after" ] && [ "$hist_after" = "$count_before" ] \
  || { echo "::error::API $sdk: discard changed the history count (was $count_before): $d" >&2; exit 1; }
e2e_lines | grep '"step":"restart"' | grep -q '"accepted":true' \
  || { echo "::error::API $sdk: a start after discard was not accepted" >&2; exit 1; }
discarded_uuid="$(e2e_field uuid <<< "$d")"
[ -n "$discarded_uuid" ] || { echo "::error::API $sdk: discard: no uuid" >&2; exit 1; }
svc_lines | grep '"event":"journal_delete"' | grep -F "$discarded_uuid" | grep -q '"ok":true' \
  || { echo "::error::API $sdk: no journal_delete ok=true for $discarded_uuid" >&2; svc_lines | grep -E 'journal|session_' | tail -n 12 >&2; exit 1; }
if svc_lines | grep -q '"event":"journal_delete_failed"'; then
  echo "::error::API $sdk: journal_delete_failed during the discard drill" >&2; svc_lines | grep journal_delete >&2; exit 1
fi
# No foreground service left for the discarded workout (a start still queued behind the pause
# must go idle, WorkoutService.cancelPendingStart). Absent output = not running = pass.
sleep 3
svcs="$(adb shell dumpsys activity services "$PKG" | tr -d '\r')"  # captured: grep -q + pipefail SIGPIPE
if grep -q 'isForeground=true' <<< "$svcs"; then
  echo "::error::API $sdk: a foreground service is still running after the discard" >&2
  adb shell dumpsys activity services "$PKG" | tr -d '\r' | head -n 30 >&2; exit 1
fi
fatal_check "$PKG" "e2e discard"
adb shell am force-stop "$PKG"
sleep 2
adb logcat -c || true
e2e_cmd history
e2e_wait ok 30
h="$(e2e_lines | grep '"step":"history"')"
[ "$(count_of <<< "$h")" = "$count_before" ] && grep -q '"pending_journal":false' <<< "$h" \
  || { echo "::error::API $sdk: after relaunch the discarded workout came back: $h" >&2; exit 1; }
fatal_check "$PKG" "after discard relaunch"
# Stale start (WorkoutService.onStartCommand): startSession + paused submit with no await between.
# The queued start callback must go idle (start_ignored stale=true), leaving no foreground service.
adb logcat -c || true
e2e_cmd stale_start
e2e_wait ok 60
e2e_lines | sed 's/^/e2e stale_start: /'
# Key-order independent: the event and the stale flag are matched on the same line separately.
stale_line() { svc_lines | grep -F '"event":"start_ignored"' | grep -F '"stale":true' | tail -1; }
for _ in $(seq 1 20); do [ -n "$(stale_line)" ] && break; sleep 1; done
[ -n "$(stale_line)" ] \
  || { echo "::error::API $sdk: no start_ignored stale=true after the back-to-back start+pause" >&2; svc_lines | grep -E 'start_ignored|service_|session_|journal' | tail -n 12 >&2; exit 1; }
# The logcat was cleared just before the command, so any service_started here belongs to it: the
# queued start must have gone idle (service_idle_start), never begun a session. (session_start is
# the journal write in LiveSession.start and always fires; service events carry no uuid.)
if svc_lines | grep -F '"event":"service_started"' | grep -qF '"mode":"session"'; then
  echo "::error::API $sdk: a session service began for the stale start" >&2
  svc_lines | grep -E 'start_ignored|service_|session_' | tail -n 12 >&2; exit 1
fi
sleep 2
svcs="$(adb shell dumpsys activity services "$PKG" | tr -d '\r')"  # captured: grep -q + pipefail SIGPIPE
if grep -q 'isForeground=true' <<< "$svcs"; then
  echo "::error::API $sdk: a foreground service is running after the stale start" >&2
  adb shell dumpsys activity services "$PKG" | tr -d '\r' | head -n 30 >&2; exit 1
fi
fatal_check "$PKG" "e2e stale_start"
# Delete (0.2.1 D3): two quick workouts, the second deleted. It must leave history (the driver
# checks history, not isStored, which stays true for deleted workouts), the export must hold its
# tombstone, and a force-stop + relaunch must not bring it back (recovery must not re-save it).
has_uuid() { grep -qF "\"$1\"" <<< "$2"; }  # has_uuid <uuid> <json line>
adb logcat -c || true
e2e_cmd delete
e2e_wait ok 120
e2e_lines | sed 's/^/e2e delete: /'
dl="$(e2e_lines | grep '"step":"delete"')"
deleted_uuid="$(e2e_field deleted <<< "$dl")"
kept_uuid="$(e2e_field kept <<< "$dl")"
[ -n "$deleted_uuid" ] && [ -n "$kept_uuid" ] || { echo "::error::API $sdk: delete: no uuids: $dl" >&2; exit 1; }
grep -q '"in_history":false' <<< "$dl" && grep -q '"kept_in_history":true' <<< "$dl" \
  || { echo "::error::API $sdk: the deleted workout is still in history (or the kept one is gone): $dl" >&2; exit 1; }
ex="$(e2e_lines | grep '"step":"export"')"
has_uuid "$deleted_uuid" "$ex" && grep -q '"format":2' <<< "$ex" \
  || { echo "::error::API $sdk: export lacks the tombstone: $ex" >&2; exit 1; }
fatal_check "$PKG" "e2e delete"
adb shell am force-stop "$PKG"
sleep 2
adb logcat -c || true
e2e_cmd history
e2e_wait ok 30
h="$(e2e_lines | grep '"step":"history"')"
has_uuid "$kept_uuid" "$h" && ! has_uuid "$deleted_uuid" "$h" \
  || { echo "::error::API $sdk: after relaunch history is wrong (deleted back, or kept lost): $h" >&2; exit 1; }
e2e_cmd export_check
e2e_wait ok 30
ex="$(e2e_lines | grep '"step":"export"')"
has_uuid "$deleted_uuid" "$ex" \
  || { echo "::error::API $sdk: tombstone lost after relaunch: $ex" >&2; exit 1; }
# uuids present (history is capped at 20 rows, the export is not): kept is exported, deleted is not
# among the exported workouts (it is only a tombstone).
wl="$(sed -n 's/.*"workout_uuids":\(\[[^]]*\]\).*/\1/p' <<< "$ex" | head -1)"
has_uuid "$kept_uuid" "$wl" && ! has_uuid "$deleted_uuid" "$wl" \
  || { echo "::error::API $sdk: export workouts wrong (kept missing or deleted present): $ex" >&2; exit 1; }
fatal_check "$PKG" "after delete relaunch"
# Live reorder (R1, 0.3.0): log a set, send the current exercise "later", kill the app. The journal
# must come back with the same order, the same current exercise and the logged set still inside its
# exercise (it moved with it), and Resume must show that exercise.
list_of() { sed -n "s/.*\"$1\":\(\[[^]]*\]\).*/\1/p" | head -1; }  # one JSON array field
adb logcat -c || true
e2e_cmd reorder
e2e_wait reorder 90
ro="$(e2e_lines | grep '"step":"reorder"')"
adb shell am force-stop "$PKG"
sleep 2
adb logcat -c || true
e2e_cmd reorder_check
e2e_wait ok 60
e2e_lines | sed 's/^/e2e reorder_check: /'
rr="$(e2e_lines | grep '"step":"reorder_resumed"')"
[ -n "$ro" ] && [ -n "$rr" ] || { echo "::error::API $sdk: reorder steps missing: $ro / $rr" >&2; exit 1; }
[ "$(list_of before <<< "$ro")" != "$(list_of order <<< "$ro")" ] \
  || { echo "::error::API $sdk: Do later did not change the order: $ro" >&2; exit 1; }
[ "$(list_of order <<< "$ro")" = "$(list_of order <<< "$rr")" ] \
  || { echo "::error::API $sdk: order changed across the kill: $ro / $rr" >&2; exit 1; }
[ "$(list_of done_per <<< "$ro")" = "$(list_of done_per <<< "$rr")" ] \
  || { echo "::error::API $sdk: logged sets moved across the kill: $ro / $rr" >&2; exit 1; }
[ "$(e2e_field current <<< "$ro")" = "$(e2e_field current <<< "$rr")" ] \
  || { echo "::error::API $sdk: current exercise changed across the kill: $ro / $rr" >&2; exit 1; }
[ "$(e2e_field view_exercise <<< "$rr")" = "$(e2e_field current_name <<< "$rr")" ] \
  || { echo "::error::API $sdk: Resume does not show the current exercise: $rr" >&2; exit 1; }
fatal_check "$PKG" "e2e reorder"
# Rest alert with notifications DENIED (t3x, 0.1.1): plan 6.2 says the service itself buzzes
# and plays the tone, so a refused permission must not silence the rest. API 33+ only (below
# 33 the permission does not exist). Revoking kills the app; the e2e run starts it again.
if [ "$sdk" -ge 33 ]; then
  adb shell pm revoke "$PKG" android.permission.POST_NOTIFICATIONS
  sleep 2
  adb logcat -c || true
  e2e_cmd run
  e2e_wait ok 120
  denied="$(timeout 30 adb logcat -d -s GymSupreme/service:I | grep -o '{"event":"rest_alert"[^}]*}' | tail -1 || true)"
  echo "rest alert, notifications denied: $denied"
  [ -n "$denied" ] || { echo "::error::API $sdk: no rest_alert with notifications denied" >&2; exit 1; }
  grep -q '"audio":"ok"' <<< "$denied" || { echo "::error::API $sdk: tone failed with notifications denied" >&2; exit 1; }
  grep -q '"vibrate":"ok' <<< "$denied" || { echo "::error::API $sdk: no vibration with notifications denied" >&2; exit 1; }
  # Captured first: grep -q stops early, and under pipefail the SIGPIPE to tr fails the pipe once
  # the output has more after the match (H1's Health Connect permission on API 34+).
  pkgd="$(adb shell dumpsys package "$PKG" | tr -d '\r')"
  grep -q 'POST_NOTIFICATIONS: granted=false' <<< "$pkgd" || { echo "::error::API $sdk: permission was not actually denied during the check" >&2; exit 1; }
  fatal_check "$PKG" "rest alert, notifications denied"
fi
# Restore drill (0.2 item 5b, review P1-7), API 34 only: Android Auto Backup through the local
# transport, uninstall (wipes app data), reinstall, restore, then the workouts logged above must
# come back through files/backup/gym-snapshot.db (the only file the rules back up).
if [ "$sdk" -eq 34 ]; then
  uuids_of() { sed -n 's/.*"uuids":\(\[[^]]*\]\).*/\1/p' | head -1; }
  adb logcat -c || true
  e2e_cmd history
  e2e_wait ok 30
  before="$(e2e_lines | grep '"step":"history"' | uuids_of)"
  echo "restore drill: before $before"
  [ -n "$before" ] && [ "$before" != "[]" ] || { echo "::error::restore drill: no workouts to back up" >&2; exit 1; }
  adb shell input keyevent KEYCODE_HOME   # onHide: checkpoint + snapshot
  sleep 5
  adb shell bmgr enable true
  adb shell bmgr list transports
  adb shell bmgr transport com.android.localtransport/.LocalTransport || true
  bk="$(adb shell bmgr backupnow "$PKG" 2>&1 | tr -d '\r')"
  echo "$bk"
  grep -q "$PKG.*Success\|Backup finished with result: Success" <<< "$bk" || { echo "::error::restore drill: backup did not succeed" >&2; exit 1; }
  adb uninstall "$PKG"
  adb install "$APK"
  rs="$(adb shell bmgr restore "$PKG" 2>&1 | tr -d '\r')"
  echo "$rs"
  grep -qiE "restoreFinished: 0|done" <<< "$rs" || echo "::warning::restore drill: bmgr restore output unrecognised (checking data anyway)"
  launch "$PKG" || { echo "::error::restore drill: app did not start after restore" >&2; exit 1; }
  adb logcat -c || true
  e2e_cmd history
  e2e_wait ok 30
  h="$(e2e_lines | grep '"step":"history"')"
  after="$(uuids_of <<< "$h")"
  echo "restore drill: after $after"
  [ "$after" = "$before" ] || { echo "::error::restore drill: workouts did not come back ($before -> $after)" >&2; exit 1; }
  # The workout deleted before the backup is still gone after the restore, and still a tombstone.
  ! has_uuid "$deleted_uuid" "$h" || { echo "::error::restore drill: the deleted workout came back: $h" >&2; exit 1; }
  e2e_cmd export_check
  e2e_wait ok 30
  ex="$(e2e_lines | grep '"step":"export"')"
  has_uuid "$deleted_uuid" "$ex" || { echo "::error::restore drill: tombstone lost in the restore: $ex" >&2; exit 1; }
  grep -q '"restore_failed":0' <<< "$h" && grep -q '"restore_pending":false' <<< "$h" || { echo "::error::restore drill: restore flagged failure/pending: $h" >&2; exit 1; }
  fatal_check "$PKG" "restore drill"
fi
echo "smoke ok on API $sdk"
