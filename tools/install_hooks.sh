#!/usr/bin/env bash
# Installs the pre-push secret scan. Linked worktrees share the main clone's hooks.
set -euo pipefail
top="$(git rev-parse --show-toplevel)"
hooks="$(git rev-parse --git-common-dir)/hooks"
mkdir -p "$hooks"
cat > "$hooks/pre-push" <<HOOK
#!/usr/bin/env bash
# Public repo: no push without a clean secret scan (tools/secret_scan.sh).
exec "\$(git rev-parse --show-toplevel)/tools/secret_scan.sh"
HOOK
chmod +x "$hooks/pre-push"
echo "pre-push hook installed in $hooks (repo $top)"
