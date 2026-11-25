#!/bin/sh
# Renders a dialogue portrait with headless Chrome: tools/render_npc.sh <name> <seed> [pose] -> textures/npc/<name>.webp
set -e
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
TMP="$(mktemp -d)"
"$CHROME" --headless=new --disable-gpu --use-angle=swiftshader --enable-unsafe-swiftshader --hide-scrollbars \
  --allow-file-access-from-files --default-background-color=00000000 --window-size=512,512 \
  --virtual-time-budget=5000 --screenshot="$TMP/p.png" "file://$PWD/tools/npc_portrait.html?seed=$2&pose=${3:-stand}" 2>/dev/null
mkdir -p textures/npc
cwebp -quiet -q 80 -alpha_q 90 "$TMP/p.png" -o "textures/npc/$1.webp"
rm -r "$TMP"
echo "textures/npc/$1.webp"
