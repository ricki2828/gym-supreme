#!/usr/bin/env bash
# Permission gate (plan 7, R1): the built APK's merged manifest must not gain INTERNET, any
# location permission or a Health Connect permission, and must keep the workout-service ones.
# Reads the APK, not the source manifest: plugins and Flutter's debug/profile manifests merge in
# (debug builds always carry INTERNET for the Flutter tool, so run this on release builds only).
# Usage: tools/check_manifest_permissions.sh <apk> <aapt>
set -euo pipefail
APK="${1:?apk}"; AAPT="${2:?aapt path}"
perms="$("$AAPT" dump permissions "$APK" | sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p" | sort -u)"
echo "permissions in $(basename "$APK"):"; echo "$perms" | sed 's/^/  /'
bad="$(echo "$perms" | grep -E 'INTERNET|LOCATION|^android\.permission\.health\.|ACCESS_NETWORK_STATE' || true)"
if [ -n "$bad" ]; then echo "::error::forbidden permission(s) in the manifest: $bad"; exit 1; fi
for need in POST_NOTIFICATIONS FOREGROUND_SERVICE_SPECIAL_USE FOREGROUND_SERVICE_CONNECTED_DEVICE BLUETOOTH_CONNECT; do
  echo "$perms" | grep -qx "android.permission.$need" || { echo "::error::android.permission.$need missing"; exit 1; }
done
echo "permission gate ok"
