#!/usr/bin/env bash
# Export the game as a native Windows .exe (for upload to itch.io as the
# "windows" channel, installed/updated via the itch desktop app).
#
#   ./build_windows.sh            # release export -> build/windows/tappa.exe
#   ./build_windows.sh --debug    # debug export
#
# The preset uses binary_format/embed_pck=true, so the export is a single
# self-contained tappa.exe (no separate .pck to ship). It is unsigned; that's
# fine for itch — the itch app launches the .exe directly and never trips
# SmartScreen (which only warns on browser-downloaded unsigned binaries).
#
# Cross-exporting from macOS/Linux works with the stock Godot export templates
# (the Windows template ships in the same .tpz), which is why CI runs this on
# the Ubuntu runner alongside the web/Android exports — see
# .github/workflows/deploy.yml.
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

OUT_DIR="build/windows"
EXE="$OUT_DIR/tappa.exe"

# --- version stamping -------------------------------------------------------
# Same scheme as build_web.sh: version name 0.<commit count> (<short sha>),
# stamped into project.godot for the HUD. Backed up and restored on exit so
# the tree stays clean. Windows needs no monotonic versionCode (unlike
# Android), so export_presets.cfg is left untouched.
COMMITS="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
VERSION="0.${COMMITS} (${SHA})"

if [[ -e project.godot.bak ]]; then
  echo "error: project.godot.bak already exists — a previous build script may have" \
    "aborted before restoring project.godot. Inspect it: if project.godot looks" \
    "correct, 'rm project.godot.bak'; otherwise 'mv project.godot.bak project.godot'." >&2
  exit 1
fi

restore_backups() {
  [[ -f project.godot.bak ]] && mv -f project.godot.bak project.godot
}
trap restore_backups EXIT

cp project.godot project.godot.bak
sed -i.tmp "s|^config/version=.*|config/version=\"${VERSION}\"|" project.godot && rm -f project.godot.tmp
echo "=== build version: ${VERSION} ==="
# ---------------------------------------------------------------------------

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "=== exporting Windows Desktop preset ($MODE) ==="
"$GODOT" --headless "$MODE" "Windows Desktop" "$EXE"

if [[ ! -f "$EXE" ]]; then
  echo "error: export did not produce $EXE" >&2
  exit 1
fi

echo "done: $EXE ($(du -h "$EXE" | cut -f1)) — version ${VERSION}"
