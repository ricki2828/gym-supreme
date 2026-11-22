#!/usr/bin/env bash
# S4 install-over: build N-1 (the previous main dogfood APK, same key) is installed and launched,
# then build N goes over it with `adb install -r` (no uninstall, no -d). Passes when the install
# succeeds and the app's install marker (files/install_marker.txt, written on the first launch
# of a fresh install) survives: same id, fresh=false. A signer mismatch fails the install.
# Usage: tools/emulator_install_over.sh <prev.apk> <new.apk> <package>
set -euo pipefail
PREV="${1:?prev apk}"; NEW="${2:?new apk}"; PKG="${3:?package}"
. "$(dirname "$0")/emulator_common.sh"
id_of() { sed -n 's/.*install marker=\([^ ]*\) .*/\1/p' <<< "$1"; }
boot_wait
adb uninstall "$PKG" > /dev/null 2>&1 || true
adb logcat -c || true
adb install "$PREV"
launch "$PKG" || { echo "build N-1 did not start" >&2; exit 1; }
fatal_check "$PKG" "build N-1 launch"
before="$(marker_first)"; echo "N-1: $before"
case "$before" in *"fresh=true"*) ;; *) echo "N-1 did not write a fresh marker" >&2; exit 1 ;; esac
adb shell am force-stop "$PKG"
adb logcat -c || true
if ! out="$(adb install -r "$NEW" 2>&1)"; then
  echo "$out" >&2; echo "::error::build N does not install over build N-1 (signer or version mismatch?)" >&2; exit 1
fi
echo "$out"
launch "$PKG" || { echo "build N did not start after install-over" >&2; exit 1; }
fatal_check "$PKG" "build N launch"
after="$(marker_line)"; echo "N:   $after"
case "$after" in *"fresh=false"*) ;; *) echo "::error::install marker lost: data not kept over the update" >&2; exit 1 ;; esac
[ "$(id_of "$before")" = "$(id_of "$after")" ] || { echo "::error::install marker id changed" >&2; exit 1; }
echo "install-over ok: marker $(id_of "$after") kept"
