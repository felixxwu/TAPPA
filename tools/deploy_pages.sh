#!/usr/bin/env bash
# Publish build/web (from ./build_web.sh) to Cloudflare Pages at https://tappa.felixwu.me.
#
#   tools/deploy_pages.sh             # stage build/pages, upload the big files to R2, deploy
#   tools/deploy_pages.sh --dry-run   # stage only, and print the upload/deploy commands
#
# Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID (or a `wrangler login`).
# Every engine file goes under /b/<build-id>/, so a new build never reuses a cached URL.
# Pages rejects files over 25 MiB, so those (index.wasm, index.pck, which holds the
# level bake) go to the R2 bucket instead, gzipped, since Cloudflare doesn't compress
# them on the way out; cloudflare/functions/b/[[path]].js serves them from the same
# origin. See features/release-pipeline.md.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  "") ;;
  *) echo "error: unknown flag $1 (known: --dry-run)" >&2; exit 2 ;;
esac

WEB="build/web"
OUT="build/pages"
BUCKET="tappa-builds"
LIMIT=$((25 * 1024 * 1024))
WRANGLER=(npx --yes wrangler@4)
[[ -f "$WEB/index.html" ]] || { echo "error: $WEB/index.html missing; run ./build_web.sh first" >&2; exit 1; }

BUILD_ID="$(date -u +%Y%m%d%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
run() { if $DRY_RUN; then echo "+ $*"; else "$@"; fi; }

GZ="build/pages-r2"
rm -rf "$OUT" "$GZ"
mkdir -p "$OUT/b/$BUILD_ID" "$GZ"
cp cloudflare/_headers docs/sign-in.html docs/privacy-policy.html "$OUT/"
# Without a 404.html, Pages answers unknown paths with index.html, which would be cached forever under /b/.
echo "Not found" > "$OUT/404.html"

for f in "$WEB"/index.*; do
  name="$(basename "$f")"
  case "$name" in
    *.import) ;;
    index.html|*.png) cp "$f" "$OUT/" ;;
    *)
      if (( $(wc -c < "$f") > LIMIT )); then
        gzip -9 -c "$f" > "$GZ/$name"
        run "${WRANGLER[@]}" r2 object put "$BUCKET/b/$BUILD_ID/$name" --file "$GZ/$name" \
          --content-encoding gzip --remote
      else
        cp "$f" "$OUT/b/$BUILD_ID/"
      fi ;;
  esac
done

# Point Godot's loader at /b/<id>/: it fetches <executable>.js/.wasm/.pck and the audio worklets.
P="b/$BUILD_ID"
sed -i.tmp \
  -e "s|\"executable\":\"index\"|\"executable\":\"$P/index\"|" \
  -e "s|\"index\\.pck\":|\"$P/index.pck\":|" \
  -e "s|\"index\\.wasm\":|\"$P/index.wasm\":|" \
  -e "s|src=\"index\\.js\"|src=\"$P/index.js\"|" \
  "$OUT/index.html" && rm -f "$OUT/index.html.tmp"
for want in "\"executable\":\"$P/index\"" "\"$P/index.pck\":" "\"$P/index.wasm\":" "src=\"$P/index.js\""; do
  grep -qF "$want" "$OUT/index.html" || { echo "error: index.html rewrite missed $want (Godot's shell changed?)" >&2; exit 1; }
done

echo "=== staged $OUT as build $BUILD_ID ==="
( cd cloudflare && run "${WRANGLER[@]}" pages deploy --project-name tappa --branch main --commit-dirty=true )
