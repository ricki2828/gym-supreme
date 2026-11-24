#!/usr/bin/env bash
# Health Connect drill (0.3 H1), after tools/emulator_smoke.sh on the same emulator.
# `health` on (pull requests, tools/ci_features.sh):
#  - API 34+ (Health Connect is part of Android): grant WRITE_EXERCISE with pm grant (the
#    permission screen cannot be tapped in CI), then the e2e `health` command turns the switch on
#    and finishes, edits, deletes, undoes and backfills one workout through HealthSync. Kotlin must
#    answer `ok` to every write (finish, edit, undo, backfill) and to the delete. Read-back is not
#    possible: the app declares no read permission (the gate allows exactly WRITE_EXERCISE).
#  - API 29/33 (no Health Connect app on the image): the switch stays off, nothing is written,
#    nothing crashes.
# `health` off (main): HealthSync does not exist; the command logs sync=false.
# Usage: tools/emulator_health.sh <package>
set -euo pipefail
PKG="${1:?package}"
. "$(dirname "$0")/emulator_common.sh"
sdk="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
flag_on() {
  local x
  for x in $(tr ',' ' ' <<< "${GS_FEATURES:-}"); do
    [ "$x" = "all" ] && return 0
    [ "$x" = "$1" ] && return 0
  done
  return 1
}
health=0; flag_on health && health=1
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ "$health" != 1 ]; then
  echo "::error::pull request build without health (GS_FEATURES='${GS_FEATURES:-}')" >&2; exit 1
fi

svc_lines() { timeout 30 adb logcat -d -s GymSupreme/service:I || true; }
e2e_lines() { timeout 30 adb logcat -d -s flutter:I | sed -n 's/.*GymSupreme\/e2e //p' | grep -F "\"nonce\":\"$NONCE\"" || true; }
e2e_cmd() { NONCE="$1-$RANDOM$RANDOM"; adb shell am start -W -n "$PKG/app.gymsupreme.MainActivity" --es gym_e2e "$1:$NONCE" > /dev/null; }
e2e_wait() { # e2e_wait <step> <seconds>
  local i
  for i in $(seq 1 "$2"); do
    if e2e_lines | grep -qE '"step":"(error|refused)"'; then echo "::error::API $sdk health: e2e failed" >&2; e2e_lines | tail -n 12 >&2; exit 1; fi
    e2e_lines | grep -q "\"step\":\"$1\"" && return 0
    sleep 1
  done
  echo "::error::API $sdk health: no $1 step within $2 s" >&2; e2e_lines | tail -n 12 >&2; timeout 60 adb logcat -d | tail -n 60 >&2; exit 1
}
str_of() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }
step() { e2e_lines | grep "\"step\":\"$1\"" | tail -1; }

if [ "$health" = 1 ] && [ "$sdk" -ge 34 ]; then
  echo "pm grant WRITE_EXERCISE: $(adb shell pm grant "$PKG" android.permission.health.WRITE_EXERCISE 2>&1 | tr -d '\r' || true)"
fi
adb logcat -c || true
e2e_cmd health
e2e_wait ok 150
e2e_lines | sed 's/^/H1 e2e: /'
svc_lines | grep -oE '\{"event":"health_[a-z_]+"[^}]*\}' | sed 's/^/H1 native: /' || true

if [ "$health" = 0 ]; then
  step health | grep -q '"sync":false' || { echo "::error::API $sdk health: flag off but HealthSync ran" >&2; exit 1; }
  ! svc_lines | grep -q '"event":"health_write"' || { echo "::error::API $sdk health: flag off but Kotlin wrote" >&2; exit 1; }
  fatal_check "$PKG" "health drill (flag off)"
  echo "H1 API $sdk: flag off, nothing sent"
  exit 0
fi

st="$(step health_status)"
avail="$(str_of availability <<< "$st")"
echo "H1 API $sdk: status $st"
writes_ok() { svc_lines | grep -F '"event":"health_write"' | grep -c '"outcome":"ok"' || true; }
if [ "$sdk" -lt 34 ]; then
  case "$avail" in notInstalled|needsUpdate|unsupported|available) ;; *) echo "::error::API $sdk health: unexpected availability '$avail'" >&2; exit 1 ;; esac
  if [ "$avail" != "available" ]; then
    grep -q '"enabled":false' <<< "$st" || { echo "::error::API $sdk health: switch on without Health Connect" >&2; exit 1; }
    [ "$(writes_ok)" -eq 0 ] || { echo "::error::API $sdk health: wrote without Health Connect" >&2; exit 1; }
    fatal_check "$PKG" "health drill (no Health Connect)"
    echo "H1 API $sdk: Health Connect $avail, switch stays off, nothing written, no crash"
    exit 0
  fi
fi
[ "$avail" = "available" ] || { echo "::error::API $sdk health: Health Connect not available on API 34+ ($avail)" >&2; exit 1; }
if ! grep -q '"granted":true' <<< "$st"; then
  echo "::warning::API $sdk health: pm grant did not grant WRITE_EXERCISE; the write is not proven on this image" >&2
  fatal_check "$PKG" "health drill (not granted)"
  exit 0
fi
grep -q '"enabled":true' <<< "$st" || { echo "::error::API $sdk health: granted but the switch did not turn on" >&2; exit 1; }
w="$(writes_ok)"
d="$(svc_lines | grep -F '"event":"health_delete"' | grep -c '"outcome":"ok"' || true)"
bf="$(step health_backfill)"
echo "H1 API $sdk: Kotlin writes ok=$w (want 4: finish, edit, undo, backfill), deletes ok=$d (want 1); backfill $bf"
[ "$w" -eq 4 ] && [ "$d" -eq 1 ] || { echo "::error::API $sdk health: Health Connect calls not all ok" >&2; svc_lines | grep -F '"event":"health_' >&2 || true; exit 1; }
grep -q '"outcome":"ok"' <<< "$bf" && grep -q '"failed":0' <<< "$bf" || { echo "::error::API $sdk health: backfill not ok: $bf" >&2; exit 1; }
fatal_check "$PKG" "health drill"
echo "H1 API $sdk: Health Connect write, edit rewrite, delete, undo rewrite and backfill all ok"
