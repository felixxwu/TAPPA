#!/usr/bin/env bash
# Export the game as an HTML5/web build and zip it for upload to itch.io.
#
#   ./build_web.sh            # release export -> build/web/, zipped to build/rally-web.zip
#   ./build_web.sh --debug    # debug export (larger, with debug symbols)
#
# The zip's main file is index.html (required by itch.io). Note: the "Web"
# export preset uses thread_support=true, so on itch.io you must enable the
# "SharedArrayBuffer support" option or the game won't start.
set -euo pipefail

GODOT="${GODOT:-/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot}"
if [[ ! -x "$GODOT" ]]; then
  echo "error: Godot binary not found at $GODOT (set \$GODOT to override)" >&2
  exit 2
fi

MODE="--export-release"
case "${1:-}" in
  --debug) MODE="--export-debug" ;;
  --release|"") ;;
  *) echo "error: unknown flag $1 (known: --debug, --release)" >&2; exit 2 ;;
esac

cd "$(dirname "$0")"

OUT_DIR="build/web"
ZIP="build/rally-web.zip"

# Clean previous output so stale files never end up in the zip.
rm -rf "$OUT_DIR" "$ZIP"
mkdir -p "$OUT_DIR"

echo "=== exporting Web preset ($MODE) ==="
"$GODOT" --headless "$MODE" "Web" "$OUT_DIR/index.html"

if [[ ! -f "$OUT_DIR/index.html" ]]; then
  echo "error: export did not produce $OUT_DIR/index.html" >&2
  exit 1
fi

echo "=== zipping -> $ZIP ==="
( cd "$OUT_DIR" && zip -q -r "../../$ZIP" . -x ".*" )

echo "done: $ZIP ($(du -h "$ZIP" | cut -f1))"
