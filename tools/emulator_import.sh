#!/usr/bin/env bash
# Import drill (0.3 I1), self-contained: runs after tools/emulator_smoke.sh on the same emulator.
#  1. Picker: the driver opens the real import picker (GymHostApi.pickImportFile); we check the
#     native import_pick_shown line, back out, and check the cancel reaches native and Dart.
#  2. Round trip: fresh install -> four workouts, two deleted -> export (gzip+base64 in e2e log
#     chunks, since the dogfood build has no run-as and uninstall wipes the app's files) ->
#     uninstall -> install -> import that bundle (gym_e2e extra) -> history digest equal, the
#     deleted workout still absent -> import again adds 0.
# The picker cannot be tapped through to a file in CI, so step 2 feeds the same bundle the
# picker would return to the same engine calls the Diagnostics Import button makes.
# Usage: tools/emulator_import.sh <apk> <package>
set -euo pipefail
APK="${1:?apk}"; PKG="${2:?package}"
. "$(dirname "$0")/emulator_common.sh"
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"

svc_lines() { timeout 30 adb logcat -d -s GymSupreme/service:I || true; }
e2e_lines() { timeout 30 adb logcat -d -s flutter:I | sed -n 's/.*GymSupreme\/e2e //p' | grep -F "\"nonce\":\"$NONCE\"" || true; }
e2e_cmd() { NONCE="$(cut -c1-12 <<< "$1")-$RANDOM$RANDOM"; adb shell am start -W -n "$PKG/app.gymsupreme.MainActivity" --es gym_e2e "$1:$NONCE" > /dev/null; }
e2e_wait() { # e2e_wait <step> <seconds>
  local i
  for i in $(seq 1 "$2"); do
    if e2e_lines | grep -qE '"step":"(error|refused)"'; then echo "::error::API $sdk import: e2e failed" >&2; e2e_lines | tail -n 12 >&2; exit 1; fi
    e2e_lines | grep -q "\"step\":\"$1\"" && return 0
    sleep 1
  done
  echo "::error::API $sdk import: no $1 step within $2 s" >&2; e2e_lines | tail -n 12 >&2; timeout 60 adb logcat -d | tail -n 60 >&2; exit 1
}
num_of() { sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p" | head -1; }
str_of() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }
fresh_install() {
  adb uninstall "$PKG" > /dev/null 2>&1 || true
  adb install "$APK" > /dev/null
  if [ "$sdk" -ge 33 ]; then adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS; fi
  launch "$PKG" || { echo "::error::API $sdk import: app did not start" >&2; exit 1; }
}

fresh_install

# 1. Picker opens, BACK resolves it as cancelled on both sides.
adb logcat -c || true
e2e_cmd pick
for i in $(seq 1 30); do svc_lines | grep -q '"event":"import_pick_shown"' && break; sleep 1; done
svc_lines | grep -q '"event":"import_pick_shown"' || { echo "::error::API $sdk import: picker never shown" >&2; e2e_lines | tail -n 5 >&2; exit 1; }
sleep 3
focus="$(adb shell dumpsys window | tr -d '\r' | grep -E 'mCurrentFocus|mFocusedApp' | head -2)"
echo "pick focus: $focus"
grep -qi 'documentsui' <<< "$focus" || echo "::warning::API $sdk import: picker focus not DocumentsUI ($focus)"
adb shell input keyevent KEYCODE_BACK
e2e_wait ok 30
svc_lines | grep '"event":"import_pick"' | grep -q '"result":"cancelled"' || { echo "::error::API $sdk import: no cancelled import_pick line" >&2; svc_lines | grep import_pick >&2; exit 1; }
e2e_lines | grep '"step":"pick"' | grep -q '"result":"null"' || { echo "::error::API $sdk import: Dart did not get null from the cancelled pick" >&2; e2e_lines >&2; exit 1; }
echo "import picker ok"
fatal_check "$PKG" "import picker"

# 2. Round trip through uninstall.
deleted=()
for round in 1 2; do  # each round: two quick workouts, the second deleted -> 2 kept, 2 deleted
  adb logcat -c || true
  e2e_cmd delete
  e2e_wait ok 120
  u="$(e2e_lines | grep '"step":"delete"' | str_of deleted)"
  [ -n "$u" ] || { echo "::error::API $sdk import: no deleted uuid" >&2; exit 1; }
  deleted+=("$u")
done
adb logcat -c || true
e2e_cmd export_dump
e2e_wait ok 30
dump="$(e2e_lines | grep '"step":"export_dump"')"
n="$(num_of chunks <<< "$dump")"; chars="$(num_of chars <<< "$dump")"
d_before="$(num_of digest <<< "$dump")"; c_before="$(num_of count <<< "$dump")"
[ -n "$n" ] && [ "$c_before" = 2 ] || { echo "::error::API $sdk import: bad export_dump: $dump" >&2; exit 1; }
b64=""
for i in $(seq 0 $((n - 1))); do
  part="$(e2e_lines | grep '"step":"chunk"' | grep "\"i\":$i[,}]" | str_of data)"
  [ -n "$part" ] || { echo "::error::API $sdk import: chunk $i of $n missing" >&2; exit 1; }
  b64="$b64$part"
done
[ "${#b64}" = "$chars" ] || { echo "::error::API $sdk import: bundle is ${#b64} chars, expected $chars" >&2; exit 1; }
echo "export: $c_before workouts, digest $d_before, $chars base64 chars in $n chunks"
fatal_check "$PKG" "import export_dump"

fresh_install
adb logcat -c || true
e2e_cmd "import.$b64"
e2e_wait ok 60
imp="$(e2e_lines | grep '"step":"import"')"
echo "import: $imp"
[ "$(num_of added <<< "$imp")" = 2 ] && [ "$(num_of preview_added <<< "$imp")" = 2 ] \
  || { echo "::error::API $sdk import: expected 2 workouts added: $imp" >&2; exit 1; }
[ "$(num_of digest <<< "$imp")" = "$d_before" ] && [ "$(num_of count <<< "$imp")" = "$c_before" ] \
  || { echo "::error::API $sdk import: history after import differs from before uninstall: $imp (before digest $d_before)" >&2; exit 1; }
adb logcat -c || true
e2e_cmd export_check
e2e_wait ok 30
ex="$(e2e_lines | grep '"step":"export"')"
for u in "${deleted[@]}"; do
  ! grep -qF "\"$u\"" <<< "$ex" || { echo "::error::API $sdk import: deleted workout $u came back: $ex" >&2; exit 1; }
done
adb logcat -c || true
e2e_cmd "import.$b64"
e2e_wait ok 60
again="$(e2e_lines | grep '"step":"import"')"
[ "$(num_of added <<< "$again")" = 0 ] && [ "$(num_of skipped_existing <<< "$again")" = 2 ] && [ "$(num_of digest <<< "$again")" = "$d_before" ] \
  || { echo "::error::API $sdk import: re-import was not a no-op: $again" >&2; exit 1; }
fatal_check "$PKG" "import round trip"
echo "import drill ok on API $sdk"
