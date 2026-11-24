#!/usr/bin/env bash
# Prints the GS_FEATURES this CI run builds and smokes. Input: GS_FEATURES (the repo variable).
# Pull requests add `lockdone` (lead, 24-Nov) so the emulator proves the lock-screen Done path
# before the flag ships; a value that already has it (or is exactly `all`) is left as is. main and
# dogfood-latest keep the repo variable unchanged, so their smoke proves the flag-off path.
set -euo pipefail
f="${GS_FEATURES:-}"
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
  case ",$f," in
    ",all," | *",lockdone,"*) ;;
    ",,") f="lockdone" ;;
    *) f="$f,lockdone" ;;
  esac
fi
echo "$f"
