#!/usr/bin/env bash
# Export the game as an HTML5/web build and zip it for upload to itch.io.
#
#   ./build_web.sh            # release export -> build/web/, zipped to build/rally-web.zip
#   ./build_web.sh --debug    # debug export (larger, with debug symbols)
#
# The zip's main file is index.html (required by itch.io). The "Web" export
# preset is single-threaded (thread_support=false) so the build needs no
# SharedArrayBuffer / cross-origin isolation: it boots on any browser (incl. old
# / low-memory phones) and you do NOT need to enable itch.io's "SharedArrayBuffer
# support" option. Terrain generation runs on a frame-budgeted main-thread queue
# on web (see features/terrain.md) so chunk loading stays smooth without threads.
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

# --- version stamping -------------------------------------------------------
# The build version is derived automatically from git: 0.<number of commits>,
# with the short SHA appended for traceability (e.g. "0.61 (b154d5c)"). It is
# monotonic and needs no manual upkeep — every commit bumps the counter.
#
# We stamp it into project.godot's application/config/version JUST for the
# export so it gets baked into the .pck and the in-game HUD can read it via
# ProjectSettings. project.godot is restored on exit (via the trap) so the
# working tree is never left modified.
COMMITS="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
VERSION="0.${COMMITS} (${SHA})"

# A leftover project.godot.bak means a PREVIOUS run died before its restore trap
# fired (or one is running concurrently). Overwriting it here would clobber the
# real, unmodified project.godot with an already-version-stamped copy — so refuse
# to start and let the user reconcile it, rather than silently corrupting the file.
if [[ -e project.godot.bak ]]; then
  echo "error: project.godot.bak already exists — a previous build_web.sh may have" \
    "aborted before restoring project.godot. Inspect it: if project.godot looks" \
    "correct, 'rm project.godot.bak'; otherwise 'mv project.godot.bak project.godot'." >&2
  exit 1
fi

restore_project_godot() { [[ -f project.godot.bak ]] && mv -f project.godot.bak project.godot; }
trap restore_project_godot EXIT

cp project.godot project.godot.bak
# Replace the existing config/version line (sed -i.tmp is portable across the
# GNU/BSD split); the .bak copy above is the source of truth for the revert.
sed -i.tmp "s|^config/version=.*|config/version=\"${VERSION}\"|" project.godot && rm -f project.godot.tmp
echo "=== build version: ${VERSION} ==="
# ---------------------------------------------------------------------------

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

echo "done: $ZIP ($(du -h "$ZIP" | cut -f1)) — version ${VERSION}"
