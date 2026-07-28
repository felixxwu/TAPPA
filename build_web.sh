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
#
# The preset also sets variant/extensions_support=false. That flag selects Godot's
# GDExtension-capable web template, which is built with Emscripten DYNAMIC LINKING
# (MAIN_MODULE/SIDE_MODULE): it emits a small index.wasm loader plus a large
# index.side.wasm, and pulls Emscripten's runtime dynamic linker into index.js.
# This project ships no .gdextension libraries (the only addon is GUT, pure
# GDScript, excluded from the export), so that machinery bought nothing. Turning it
# off (2026-07) cut build/web from 65.6 MB to 55.4 MB — index.js 5.55 MB -> 0.32 MB
# (the dynamic linker) and the wasm pair 42.6 MB -> 37.7 MB. Only turn it back on if
# a real GDExtension is added to the web export.
#
# TRANSPORT COMPRESSION AND CACHING — deliberately NOT done here (verified
# 2026-07-28). The shipped build is served by itch.io (html.itch.zone, behind
# Cloudflare); GitHub Pages only hosts docs/index.html, a redirect to the itch
# page, and never serves the game. Measured response headers on the live build:
#
#   index.wasm  content-encoding: gzip   content-length: 9,925,878  (from 37.7 MB)
#   index.pck   content-encoding: gzip   content-length: 9,282,176  (from 17.3 MB)
#   index.js    content-encoding: gzip   content-length:    82,293
#
# So the host already negotiates gzip on application/wasm and on the PCK, and
# there is nothing to fix. Do NOT pre-compress into build/web: butler uploads
# the directory verbatim, so an index.wasm.gz would ship as an extra 9 MB FILE
# nobody requests — it would grow the download, not shrink it. (Brotli is not
# offered by the host; that would be worth ~1.7 MB more but is not ours to set.)
#
# Caching is likewise the host's, and it is already safe: itch serves each
# upload from a build-unique path (html.itch.zone/html/<upload>-<build>/...),
# so every asset URL is inherently version-stamped and a redeploy can never be
# masked by a cached response. Observed cache-control ranges from max-age=0 to
# max-age=2678374 (~31 days) depending on CDN state. No service worker is used
# (see todo/mobile-web-performance.md §2.12 — CUT: a worker caching a 37 MB
# wasm can pin players to a stale build, a worse failure than a slow load).
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
