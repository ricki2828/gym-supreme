#!/usr/bin/env bash
# Schema v1 -> v2 migration install-over (0.2.1). A pinned 0.2.0 dogfood APK (schema v1) is
# installed fresh and logs one workout through the e2e driver; the workout uuids are read with
# the `history` command. This build (schema v2: workout.deleted_at_ms / edited_at_ms) then goes
# over it with `adb install -r`. Passes when the history uuids are identical afterwards, the app
# booted with no "newer database" / failed-migration state, and PRAGMA user_version is 2.
# The existing tools/emulator_install_over.sh (dogfood-latest, already v2) stays as well.
# Usage: tools/emulator_migration_over.sh <base-0.2.0.apk> <new.apk> <package>
set -euo pipefail
BASE="${1:?base apk (0.2.0)}"; NEW="${2:?new apk}"; PKG="${3:?package}"
. "$(dirname "$0")/emulator_common.sh"
# e2e helpers: same wire format as tools/emulator_smoke.sh (a nonce per command). Commands and
# the `history` shape are the ones 0.2.0 (3076e4c) has: run, history; uuids newest-first.
e2e_lines() { timeout 30 adb logcat -d -s flutter:I | sed -n 's/.*GymSupreme\/e2e //p' | grep -F "\"nonce\":\"$NONCE\"" || true; }
e2e_cmd() { NONCE="$1-$RANDOM$RANDOM"; adb shell am start -W -n "$PKG/app.gymsupreme.MainActivity" --es gym_e2e "$1:$NONCE" > /dev/null; }
e2e_wait() { # e2e_wait <step> <seconds>
  local i
  for i in $(seq 1 "$2"); do
    if e2e_lines | grep -qE '"step":"(error|refused)"'; then echo "e2e failed:" >&2; e2e_lines | tail -n 12 >&2; exit 1; fi
    e2e_lines | grep -q "\"step\":\"$1\"" && return 0
    sleep 1
  done
  echo "e2e: no $1 step within $2 s" >&2; e2e_lines | tail -n 12 >&2; timeout 60 adb logcat -d | tail -n 60 >&2; exit 1
}
uuids_of() { sed -n 's/.*"uuids":\(\[[^]]*\]\).*/\1/p' | head -1; }
history_line() { adb logcat -c || true; e2e_cmd history; e2e_wait ok 30; e2e_lines | grep '"step":"history"'; }
newer_db_check() { # no boot "newer database" / failed-migration state in this logcat
  local log hits; log="$(timeout 60 adb logcat -d)"; hits="$(mktemp)"
  if grep -E 'is newer than this build|GymSupreme/db FAILED|GymSupreme/boot failed|SqliteException' <<< "$log" > "$hits"; then
    echo "::error::$1: newer-database or failed-migration state at boot:" >&2; cat "$hits" >&2; rm -f "$hits"; exit 1
  fi
  rm -f "$hits"
}

boot_wait
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
adb uninstall "$PKG" > /dev/null 2>&1 || true
adb logcat -c || true
adb install "$BASE"
echo "migration base: $(basename "$BASE") (0.2.0, schema v1)"
launch "$PKG" || { echo "0.2.0 base did not start" >&2; exit 1; }
fatal_check "$PKG" "0.2.0 launch"
if [ "$sdk" -ge 33 ]; then adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS; fi
# Log a real workout on 0.2.0 (start, 2 sets, finish, stored) through the e2e driver.
adb logcat -c || true
e2e_cmd run
e2e_wait ok 120
fin="$(e2e_lines | grep '"step":"finish"')"
grep -q '"stored":true' <<< "$fin" || { echo "::error::0.2.0 e2e run did not store a workout: $fin" >&2; exit 1; }
before_line="$(history_line)"
before="$(uuids_of <<< "$before_line")"
# 0.2.0 predates schema v2 and its history line has no schema_version key: proves the base is v1.
! grep -q '"schema_version"' <<< "$before_line" || { echo "::error::base is not schema v1 (history has schema_version): $before_line" >&2; exit 1; }
echo "migration before (0.2.0): uuids $before"
[ -n "$before" ] && [ "$before" != "[]" ] || { echo "::error::migration: no workout on 0.2.0 to carry over" >&2; exit 1; }
fatal_check "$PKG" "0.2.0 workout"
adb shell am force-stop "$PKG"
sleep 2
adb logcat -c || true
if ! out="$(adb install -r "$NEW" 2>&1)"; then
  echo "$out" >&2; echo "::error::this build does not install over 0.2.0 (signer or version mismatch?)" >&2; exit 1
fi
echo "$out"
launch "$PKG" || { echo "::error::this build did not start over a schema v1 db" >&2; timeout 60 adb logcat -d | tail -n 80 >&2; exit 1; }
fatal_check "$PKG" "launch over 0.2.0 data"
newer_db_check "launch over 0.2.0 data"
after_line="$(history_line)"
after="$(uuids_of <<< "$after_line")"
echo "migration after  (this build): uuids $after"
[ "$after" = "$before" ] || { echo "::error::migration: workouts changed over the update ($before -> $after)" >&2; exit 1; }
sv="$(sed -n 's/.*"schema_version":\([0-9]*\).*/\1/p' <<< "$after_line" | head -1)"
echo "migration schema_version after: ${sv:-missing}"
[ "$sv" = "2" ] || { echo "::error::migration: PRAGMA user_version is '${sv:-missing}', expected 2" >&2; exit 1; }
grep -q '"restore_failed":0' <<< "$after_line" || { echo "::error::migration: restore_failed set: $after_line" >&2; exit 1; }
fatal_check "$PKG" "after migration"
newer_db_check "after migration"
# Leave a clean device: the smoke that follows expects a fresh install (notification ask, grants).
adb uninstall "$PKG" > /dev/null
echo "migration install-over ok: ${before} kept, schema v1 -> v2"
