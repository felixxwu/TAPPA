#!/usr/bin/env bash
# One-time setup: point git at the repo's tracked hooks in .githooks/.
# Safe to re-run. Git hooks live in .git/hooks (untracked), so we use
# core.hooksPath to keep them versioned and shared instead.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

chmod +x .githooks/* 2>/dev/null || true
git config core.hooksPath .githooks

echo "Installed: core.hooksPath -> .githooks"
echo "The pre-commit hook now keeps the data/*.json cache lockfiles fresh and staged."
