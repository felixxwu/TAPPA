#!/usr/bin/env bash
# Export the game as an Android App Bundle (.aab) for upload to the Google Play
# Console. This is the Play counterpart to build_android.sh (which produces the
# sideloadable .apk for itch.io): Play requires an AAB and a Gradle-based build,
# so it uses a dedicated "Android Play (AAB)" export preset with
# use_gradle_build=true / export_format=1 and the tappa.game package name.
#
#   ./build_android_play.sh            # release export -> build/android-play/rally.aab
#   ./build_android_play.sh --debug    # debug export
#
# Signing works exactly like build_android.sh: Godot reads the upload keystore
# from environment variables, so no keystore paths live in export_presets.cfg.
# For a release export set:
#   GODOT_ANDROID_KEYSTORE_RELEASE_PATH / _USER / _PASSWORD
# CI generates/restores a keystore and sets these — see
# .github/workflows/android-play.yml. It also needs a JDK + Android SDK and the
# Godot Android build template (Gradle build), which the GitHub Ubuntu runners
# provide — this is why the AAB build runs in CI rather than locally.
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

OUT_DIR="build/android-play"
AAB="$OUT_DIR/rally.aab"

# --- version stamping -------------------------------------------------------
# Same scheme as build_android.sh: version name 0.<commit count> (<short sha>)
# and a monotonically increasing integer versionCode (the commit count). Both
# files are backed up and restored on exit so the tree stays clean. The sed
# stamps every version/code / version/name line in export_presets.cfg, which
# covers both Android presets — harmless, as itch and Play use independent
# version-code spaces.
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

echo "=== exporting Android Play (AAB) preset ($MODE) ==="
"$GODOT" --headless "$MODE" "Android Play (AAB)" "$AAB"

if [[ ! -f "$AAB" ]]; then
  echo "error: export did not produce $AAB" >&2
  exit 1
fi

echo "done: $AAB ($(du -h "$AAB" | cut -f1)) — version ${VERSION}"
