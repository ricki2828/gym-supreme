# Sourced by the emulator scripts. Boot wait, launch, marker log, fatal check.
boot_wait() {
  adb wait-for-device
  until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
  # Hosted-runner emulators are still starting GMS when adb is up; a GMS ANR dialog can steal
  # the first launch.
  sleep 15
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
}
# launch <pkg>: explicit start, retried once; true when the process is up.
launch() {
  local pkg="$1" i
  for i in 1 2; do
    adb shell am start -W -n "$pkg/app.gymsupreme.MainActivity" > /dev/null || true
    sleep 12
    adb shell pidof "$pkg" > /dev/null && return 0
    echo "launch $i of $pkg did not come up; closing system dialogs"
    adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
    sleep 5
  done
  if [ "$(timeout 10 adb get-state 2>/dev/null | tr -d '\r')" != "device" ]; then
    echo "emulator went away during launch (runner infra, not an app crash); re-run the job" >&2
  fi
  return 1
}
# marker_line: the newest install-marker log line (MainActivity.InstallMarker).
marker_line() { timeout 30 adb logcat -d -s GymSupreme/install:I | grep 'install marker=' | tail -1 || true; }
# marker_first: the first marker line since the last logcat -c. An activity recreate logs a
# second line with fresh=false (seen once on API 34), so "fresh install" checks read the first.
marker_first() { timeout 30 adb logcat -d -s GymSupreme/install:I | grep 'install marker=' | head -1 || true; }
# fatal_check <pkg> <phase>: fails on any crash of OUR process in logcat: a Java/Kotlin
# exception (AndroidRuntime), a native crash (tombstone ">>> pkg <<<" from DEBUG/crash_dump) or
# an unhandled Dart error (`E flutter` with Unhandled Exception or [FATAL]; plain engine
# E-level diagnostics such as GPU fallbacks on swiftshader are not failures).
fatal_check() {
  local log; log="$(timeout 60 adb logcat -d)" || { echo "logcat read failed during $2" >&2; exit 1; }
  if "$(dirname "${BASH_SOURCE[0]}")/app_fatal.sh" "$1" <<< "$log" > /tmp/fatal.log; then
    echo "fatal exception during $2:" >&2; cat /tmp/fatal.log >&2; exit 1
  fi
  if grep -F ">>> $1 <<<" <<< "$log" > /tmp/fatal.log; then
    echo "native crash during $2:" >&2; grep -E ' F (DEBUG|libc) ' <<< "$log" | tail -n 60 >&2; exit 1
  fi
  if grep -E ' E flutter .*(Unhandled Exception|\[FATAL)' <<< "$log" > /tmp/fatal.log; then
    echo "unhandled Dart error during $2:" >&2; cat /tmp/fatal.log >&2; exit 1
  fi
}
