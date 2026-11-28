#!/usr/bin/env bash
# Fails if a headless crate (assets, physics) pulls in a GPU, window, audio or browser dependency.
set -euo pipefail
cd "$(dirname "$0")/.."
tree=$(cargo tree -p assets -p physics -e normal --prefix none)
if bad=$(grep -E '^(wgpu|winit|cpal|web-sys) ' <<<"$tree"); then
  echo "headless crates depend on: $bad" >&2
  exit 1
fi
echo "dep_guard ok"
