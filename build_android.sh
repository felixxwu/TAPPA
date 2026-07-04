#!/usr/bin/env bash
# Export the game as an Android APK (for upload to itch.io as the "android"
# channel).
#
#   ./build_android.sh            # release export -> build/android/rally.apk
#   ./build_android.sh --debug    # debug export
#
# Signing: Godot reads the keystore from environment variables, so no keystore
# paths live in export_presets.cfg. For a release export set:
#   GODOT_ANDROID_KEYSTORE_RELEASE_PATH / _USER / _PASSWORD
# (for --debug, the GODOT_ANDROID_KEYSTORE_DEBUG_* equivalents). CI generates /
# restores a keystore and sets these — see .github/workflows/deploy.yml. It
# also needs a JDK + Android SDK (apksigner); the GitHub Ubuntu runners ship
# both, which is why this build runs in CI rather than locally.
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

OUT_DIR="build/android"
APK="$OUT_DIR/rally.apk"

# --- version stamping -------------------------------------------------------
# Same scheme as build_web.sh: version name 0.<commit count> (<short sha>),
# stamped into project.godot for the HUD. Android additionally needs a
# monotonically increasing integer versionCode, for which the commit count
# serves directly — stamped into the Android preset in export_presets.cfg.
# Both files are backed up and restored on exit so the tree stays clean.
COMMITS="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
VERSION="0.${COMMITS} (${SHA})"

for f in project.godot export_presets.cfg; do
  if [[ -e "$f.bak" ]]; then
    echo "error: $f.bak already exists — a previous build script may have aborted" \
      "before restoring $f. Inspect it: if $f looks correct, 'rm $f.bak';" \
      "otherwise 'mv $f.bak $f'." >&2
    exit 1
  fi
done

restore_backups() {
  [[ -f project.godot.bak ]] && mv -f project.godot.bak project.godot
  [[ -f export_presets.cfg.bak ]] && mv -f export_presets.cfg.bak export_presets.cfg
}
trap restore_backups EXIT

cp project.godot project.godot.bak
cp export_presets.cfg export_presets.cfg.bak
sed -i.tmp "s|^config/version=.*|config/version=\"${VERSION}\"|" project.godot && rm -f project.godot.tmp
sed -i.tmp "s|^version/code=.*|version/code=${COMMITS}|; s|^version/name=.*|version/name=\"${VERSION}\"|" export_presets.cfg && rm -f export_presets.cfg.tmp
echo "=== build version: ${VERSION} (versionCode ${COMMITS}) ==="
# ---------------------------------------------------------------------------

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "=== exporting Android preset ($MODE) ==="
"$GODOT" --headless "$MODE" "Android" "$APK"

if [[ ! -f "$APK" ]]; then
  echo "error: export did not produce $APK" >&2
  exit 1
fi

echo "done: $APK ($(du -h "$APK" | cut -f1)) — version ${VERSION}"
