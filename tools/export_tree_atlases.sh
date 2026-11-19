#!/usr/bin/env bash
# Re-renders the game's tree textures (textures/tree*.png|webp) from GAME_TREES in tools/tree_lab.html.
# Usage, from the repo root: tools/export_tree_atlases.sh [sprite height px, default 512]
# Needs Google Chrome (WebGL runs on its software renderer) and cwebp (brew install webp).
set -euo pipefail
res=${1:-512}
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
out=$(mktemp -d)
"$chrome" --headless=new --use-angle=swiftshader --enable-unsafe-swiftshader --allow-file-access-from-files \
  --virtual-time-budget=60000 --dump-dom "file://$PWD/tools/tree_lab.html?export=$res" 2>/dev/null > "$out/dom.html"
python3 - "$out" <<'PY'
import base64, html, json, re, sys
out = sys.argv[1]
m = re.search(r'<pre id="gameTrees">(.*?)</pre>', open(f"{out}/dom.html").read(), re.S)
if not m: sys.exit("tree_lab produced no atlases")
for name, url in json.loads(html.unescape(m.group(1))).items():
    open(f"{out}/{name.rsplit('.', 1)[0]}.png", "wb").write(base64.b64decode(url.split(",", 1)[1]))
    print(name)
PY
for f in "$out"/*.png; do
  n=$(basename "$f" .png)
  if [[ -e textures/$n.png ]]; then cp "$f" "textures/$n.png"; else cwebp -quiet -q 90 -alpha_q 100 "$f" -o "textures/$n.webp"; fi
done
ls -la textures/tree*.png textures/tree*.webp
