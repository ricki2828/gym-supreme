#!/usr/bin/env bash
# Widget-driven UI flow on the CI emulator (integration_test/ui_flow_test.dart, UI lane).
# flutter test installs the debug dogfood build itself, so POST_NOTIFICATIONS cannot be granted
# beforehand: a background loop grants it as soon as the package exists, so the app's one-time
# ask never blocks the taps (the ask itself is checked by tools/emulator_smoke.sh).
# Usage: tools/ui_e2e.sh <device>   (env GS_FEATURES, BUILD_SHA)
set -euo pipefail
DEV="${1:?device}"
PKG=app.gymsupreme.dogfood.debug
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
(
  for _ in $(seq 1 900); do
    if adb shell pm list packages "$PKG" 2>/dev/null | grep -q "package:$PKG"; then
      adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null && exit 0
    fi
    sleep 1
  done
) &
grant=$!
trap 'kill "$grant" 2>/dev/null || true' EXIT
flutter test integration_test/ui_flow_test.dart --flavor dogfood -d "$DEV" \
  --dart-define=GS_FEATURES="${GS_FEATURES:-}" --dart-define=BUILD_SHA="${BUILD_SHA:-local}" \
  2>&1 | tee /tmp/ui_e2e.log
grep -q 'GymSupreme/ui-e2e {"step":"ok"' /tmp/ui_e2e.log || { echo "::error::no ui-e2e ok line" >&2; exit 1; }
