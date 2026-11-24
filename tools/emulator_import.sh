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
  # API 34's restore drill (emulator_smoke.sh) leaves Auto Backup on with the local transport, so
  # an install restores that data. Clear it: this drill needs a really empty app.
  adb shell pm clear "$PKG" > /dev/null || { echo "::error::API $sdk import: pm clear failed" >&2; exit 1; }
  if [ "$sdk" -ge 33 ]; then adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS; fi
  launch "$PKG" || { echo "::error::API $sdk import: app did not start" >&2; exit 1; }
  fatal_check "$PKG" "import launch"
}

adb shell bmgr enable false > /dev/null 2>&1 || true  # no restore-at-install from the smoke's backup
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

# 2. Round trip through uninstall. Every capture below ends in `|| true` so a miss reaches its
# ::error:: line instead of dying silently under set -e/pipefail; fatal_check runs before every
# `logcat -c` so no crash line is wiped unread.
grab() { e2e_lines | grep "\"step\":\"$1\"" || true; }
deleted=()
for round in 1 2; do  # each round: two quick workouts, the second deleted -> 2 kept, 2 deleted
  adb logcat -c || true
  e2e_cmd delete
  e2e_wait ok 120
  u="$(grab delete | str_of deleted || true)"
  [ -n "$u" ] || { echo "::error::API $sdk import: no deleted uuid" >&2; exit 1; }
  deleted+=("$u")
  fatal_check "$PKG" "import setup $round"
done
adb logcat -c || true
e2e_cmd export_dump
e2e_wait ok 30
dump="$(grab export_dump)"
n="$(num_of chunks <<< "$dump" || true)"; chars="$(num_of chars <<< "$dump" || true)"
d_before="$(num_of digest <<< "$dump" || true)"; c_before="$(num_of count <<< "$dump" || true)"
[ -n "$n" ] && [ "$c_before" = 2 ] || { echo "::error::API $sdk import: bad export_dump: $dump" >&2; exit 1; }
b64=""
for i in $(seq 0 $((n - 1))); do
  part="$(grab chunk | grep "\"i\":$i[,}]" | str_of data || true)"
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
imp="$(grab import)"
echo "import: $imp"
[ "$(num_of added <<< "$imp" || true)" = 2 ] && [ "$(num_of preview_added <<< "$imp" || true)" = 2 ] \
  || { echo "::error::API $sdk import: expected 2 workouts added: $imp" >&2; exit 1; }
[ "$(num_of digest <<< "$imp" || true)" = "$d_before" ] && [ "$(num_of count <<< "$imp" || true)" = "$c_before" ] \
  || { echo "::error::API $sdk import: history after import differs from before uninstall: $imp (before digest $d_before)" >&2; exit 1; }
fatal_check "$PKG" "import"
# Workouts deleted on the old install are not in the export, so they cannot come back; this
# guards the export side. The tombstone skip itself is checked next.
adb logcat -c || true
e2e_cmd export_check
e2e_wait ok 30
ex="$(grab export)"
for u in "${deleted[@]}"; do
  ! grep -qF "\"$u\"" <<< "$ex" || { echo "::error::API $sdk import: deleted workout $u came back: $ex" >&2; exit 1; }
done
# Tombstone: delete one imported workout here, import the same bundle again: it stays deleted.
adb logcat -c || true
e2e_cmd delete_one
e2e_wait ok 30
del="$(grab delete_one)"
gone="$(str_of deleted <<< "$del" || true)"; d_del="$(num_of digest <<< "$del" || true)"
[ -n "$gone" ] && [ "$(num_of count <<< "$del" || true)" = 1 ] || { echo "::error::API $sdk import: delete_one failed: $del" >&2; exit 1; }
fatal_check "$PKG" "import delete_one"
adb logcat -c || true
e2e_cmd "import.$b64"
e2e_wait ok 60
again="$(grab import)"
echo "re-import: $again"
[ "$(num_of added <<< "$again" || true)" = 0 ] && [ "$(num_of skipped_existing <<< "$again" || true)" = 1 ] \
  && [ "$(num_of skipped_deleted <<< "$again" || true)" = 1 ] && [ "$(num_of count <<< "$again" || true)" = 1 ] \
  && [ "$(num_of digest <<< "$again" || true)" = "$d_del" ] \
  || { echo "::error::API $sdk import: re-import was not a no-op or resurrected $gone: $again" >&2; exit 1; }
fatal_check "$PKG" "import round trip"
echo "import drill ok on API $sdk"
