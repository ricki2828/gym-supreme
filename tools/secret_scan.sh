#!/usr/bin/env bash
# Secret scan for a PUBLIC repo: run in CI on every push/PR and by the pre-push hook
# (tools/install_hooks.sh). Scans the full git history with gitleaks (pinned image) and refuses
# tracked keystores, key files and local.properties. Needs docker.
# Usage: tools/secret_scan.sh [repo-dir]
set -euo pipefail
dir="$(cd "${1:-.}" && git rev-parse --show-toplevel)"
cd "$dir"
banned="$(git ls-files | grep -E '\.(jks|keystore|p12|pem|key)$|(^|/)local\.properties$|(^|/)key\.properties$|(^|/)\.env$' || true)"
if [ -n "$banned" ]; then echo "::error::tracked secret-bearing files:"; echo "$banned"; exit 1; fi
# The git dir of a linked worktree lives outside the tree; gitleaks reads history through it.
common="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
docker run --rm -u "$(id -u):$(id -g)" -v "$dir:/repo:ro" -v "$common:$common:ro" -w /repo \
  ghcr.io/gitleaks/gitleaks:v8.21.2 detect --source /repo --redact --no-banner -v --exit-code 1
echo "secret scan ok"
