#!/usr/bin/env bash
# Export the game for iPhone as a signed App Store .ipa, for upload to TestFlight.
#
#   ./build_ios.sh            # release export -> build/ios/tappa.ipa
#   ./build_ios.sh --debug    # development-signed export
#
# Needs macOS with Xcode, Godot's iOS export template, and Apple signing set up: the
# distribution certificate in the keychain and the App Store provisioning profile
# installed. The team ID and profile are read from the environment so no account
# details live in export_presets.cfg:
#   APPLE_TEAM_ID                                         (required)
#   GODOT_APPLE_PLATFORM_PROVISIONING_PROFILE_UUID_RELEASE (read by Godot itself)
# CI sets these — see .github/workflows/deploy.yml → export-ios and
# features/release-pipeline.md.
set -euo pipefail

GODOT="${GODOT:-/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot}"
[[ -x "$GODOT" ]] || GODOT=/Applications/Godot.app/Contents/MacOS/Godot
if [[ ! -x "$GODOT" ]]; then
  echo "error: Godot binary not found at $GODOT (set \$GODOT to override)" >&2
  exit 2
fi
if [[ -z "${APPLE_TEAM_ID:-}" ]]; then
  echo "error: APPLE_TEAM_ID is not set (the 10-character Apple Developer team ID)" >&2
  exit 2
fi

MODE="--export-release"
case "${1:-}" in
  --debug) MODE="--export-debug" ;;
  --release|"") ;;
  *) echo "error: unknown flag $1 (known: --debug, --release)" >&2; exit 2 ;;
esac

cd "$(dirname "$0")"

OUT_DIR="build/ios"
IPA="$OUT_DIR/tappa.ipa"

# --- version stamping -------------------------------------------------------
# project.godot gets the same 0.<commit count> (<short sha>) as every build. Apple
# only accepts dotted numbers, so the bundle's own versions are 0.<commit count>
# (shown on the App Store) and <commit count> (the build number, which must rise
# with every TestFlight upload). Both files are restored on exit.
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
sed -i.tmp "s|^application/short_version=.*|application/short_version=\"0.${COMMITS}\"|; s|^application/version=.*|application/version=\"${COMMITS}\"|; s|^application/app_store_team_id=.*|application/app_store_team_id=\"${APPLE_TEAM_ID}\"|" export_presets.cfg && rm -f export_presets.cfg.tmp
echo "=== build version: ${VERSION} (iOS build ${COMMITS}) ==="
# ---------------------------------------------------------------------------

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "=== exporting iOS preset ($MODE) ==="
"$GODOT" --headless "$MODE" "iOS" "$IPA"

if [[ ! -f "$IPA" ]]; then
  echo "error: export did not produce $IPA" >&2
  exit 1
fi

echo "done: $IPA ($(du -h "$IPA" | cut -f1)) — version ${VERSION}"
