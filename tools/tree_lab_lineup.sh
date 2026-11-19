# Screenshots each named tree-lab preset with headless Chrome, then tiles them into one line-up image.
# Serve the repo first (python3 -m http.server 8941 from the repo root), then: tools/tree_lab_lineup.sh "Sitka spruce" "Alder" ...
# Writes tools/render_out/tree_lineup/; needs Pillow (pip install -r tools/geo/requirements.txt).
cd "$(dirname "$0")" && mkdir -p render_out/tree_lineup && cd render_out
C="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for p in "$@"; do
  f="tree_lineup/$(echo $p | tr ' ()' '___').png"
  "$C" --headless=new --use-angle=swiftshader --enable-unsafe-swiftshader --hide-scrollbars --window-size=1080,1000 --virtual-time-budget=20000 --user-data-dir=$PWD/chrome-prof --screenshot=$f "http://127.0.0.1:8941/tools/tree_lab.html?render=1&preset=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$p")" 2>/dev/null
done; wait
python3 - "$@" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
names=sys.argv[1:]; tiles=[]
for n in names:
    im=Image.open("tree_lineup/"+n.replace(" ","_").replace("(","_").replace(")","_")+".png").convert("RGB").crop((280,0,1080,1000))
    d=ImageDraw.Draw(im); d.rectangle([0,0,800,40],fill=(20,22,26)); d.text((12,10),n,fill="white",font=ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc",22)); tiles.append(im)
W=Image.new("RGB",(800*3,1000*((len(tiles)+2)//3)))
for i,t in enumerate(tiles): W.paste(t,((i%3)*800,(i//3)*1000))
W.save("tree_lineup/lineup.jpg",quality=88)
PY
