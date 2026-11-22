#!/usr/bin/env bash
# Permission gate (plan 7, R1) on the BUILT APK's merged manifest, not the source manifest:
# plugins and Flutter's debug/profile manifests merge in (debug builds always carry INTERNET for
# the Flutter tool, so run this on release builds only).
# - Exact allowlist over uses-permission AND uses-permission-sdk-23: anything new (INTERNET,
#   location, Health Connect, CAMERA, AD_ID...) fails until it is added here on purpose.
# - Every allowlisted permission must be present.
# - BLUETOOTH_SCAN must carry usesPermissionFlags=neverForLocation.
# Usage: tools/check_manifest_permissions.sh <apk> <build-tools-dir> <package>
set -euo pipefail
APK="${1:?apk}"; BT="${2:?build-tools dir}"; PKG="${3:?package}"
allowed="android.permission.BLUETOOTH_CONNECT
android.permission.BLUETOOTH_SCAN
android.permission.FOREGROUND_SERVICE
android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE
android.permission.FOREGROUND_SERVICE_SPECIAL_USE
android.permission.POST_NOTIFICATIONS
android.permission.VIBRATE
android.permission.WAKE_LOCK"
# Allowed but not required: androidx.core adds it when a dependency registers receivers.
optional="$PKG.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
dump="$("$BT/aapt" dump permissions "$APK")"
perms="$(sed -n "s/^uses-permission\(-sdk-23\)\{0,1\}: name='\([^']*\)'.*/\2/p" <<< "$dump" | sort -u)"
echo "permissions in $(basename "$APK"):"; sed 's/^/  /' <<< "$perms"
unknown="$(grep -E '^uses-permission' <<< "$dump" | grep -v "name='" || true)"
[ -z "$unknown" ] || { echo "::error::unparsed permission lines: $unknown"; exit 1; }
extra="$(comm -23 <(echo "$perms") <(printf '%s\n%s\n' "$allowed" "$optional" | sort))"
missing="$(comm -13 <(echo "$perms") <(sort <<< "$allowed"))"
[ -z "$extra" ] || { echo "::error::permission(s) not on the allowlist: $(echo $extra)"; exit 1; }
[ -z "$missing" ] || { echo "::error::required permission(s) missing: $(echo $missing)"; exit 1; }
# neverForLocation = 0x10000 on uses-permission BLUETOOTH_SCAN.
"$BT/aapt2" dump xmltree --file AndroidManifest.xml "$APK" | python3 -c '
import re, sys
blocks = re.split(r"\n\s*E: ", sys.stdin.read())
scan = [b for b in blocks if b.startswith("uses-permission") and "android.permission.BLUETOOTH_SCAN\"" in b]
ok = len(scan) == 1 and re.search(r"usesPermissionFlags\([^)]*\)=(65536|0x0*10000)\b", scan[0])
print("\n".join(scan) or "no BLUETOOTH_SCAN element")
sys.exit(0 if ok else "::error::BLUETOOTH_SCAN lacks usesPermissionFlags=neverForLocation (0x10000)")'
echo "permission gate ok"
