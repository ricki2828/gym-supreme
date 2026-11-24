#!/usr/bin/env bash
# Prints the GS_FEATURES this CI run builds and smokes. Input: GS_FEATURES (the repo variable).
# Pull requests add `lockdone` (lead, 24-Nov) and `timers` (cut T1, 24-Nov) so the emulator proves
# those paths before the flags ship; a value that already has a flag (or is exactly `all`) is left
# as is. main and dogfood-latest keep the repo variable unchanged, so their smoke proves the
# flag-off path. The T1 nightly (timers-nightly.yml) adds `timers` itself.
set -euo pipefail
f="${GS_FEATURES:-}"
add() {
  case ",$f," in
    ",all," | *",$1,"*) ;;
    ",,") f="$1" ;;
    *) f="$f,$1" ;;
  esac
}
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ "${CI_FORCE_TIMERS:-}" = "1" ]; then
  [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && add lockdone
  add timers
fi
echo "$f"
