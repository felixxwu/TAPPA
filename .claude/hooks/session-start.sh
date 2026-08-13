#!/bin/bash
# SessionStart hook: install Godot (headless), pinned to match CI's version
# (see GODOT_VERSION below and .github/workflows/deploy.yml), so the GUT test
# suite and the web export can run in Claude Code on the web sessions.
#
# The project's run_tests.sh / build_web.sh read $GODOT (falling back to a macOS
# path that doesn't exist here), so we install the Linux build and export $GODOT
# for the session via $CLAUDE_ENV_FILE.
set -euo pipefail

# Remote/web only — local dev boxes already have their own Godot at the path
# baked into run_tests.sh, and we don't want to override it there.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

GODOT_VERSION="4.6.3"
GODOT_BIN="/usr/local/bin/godot"

# Idempotent: only download if the right version isn't already installed (the
# container caches state after the hook completes, so resumes skip the download).
# `godot --headless --version` prints a dotted string like
# "4.6.3.stable.official.<hash>" (NOT the hyphenated "4.6.3-stable" release-tag
# form used in the download URL below) — anchor on the full dotted version
# followed by a literal "." so "4.6.30" or "4.7" can't false-positive match.
GODOT_VERSION_DOTS="${GODOT_VERSION//./\\.}"
if ! "$GODOT_BIN" --headless --version 2>/dev/null | grep -q "^${GODOT_VERSION_DOTS}\."; then
  echo "Installing Godot ${GODOT_VERSION} (headless) -> ${GODOT_BIN}"
  url="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
  tmp="$(mktemp -d)"
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "$tmp/godot.zip" "$url"
  unzip -q "$tmp/godot.zip" -d "$tmp"
  mv "$tmp/Godot_v${GODOT_VERSION}-stable_linux.x86_64" "$GODOT_BIN"
  chmod +x "$GODOT_BIN"
  rm -rf "$tmp"
fi

# Point run_tests.sh / build_web.sh at the installed binary for this session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export GODOT=\"${GODOT_BIN}\"" >> "$CLAUDE_ENV_FILE"
fi

"$GODOT_BIN" --headless --version
