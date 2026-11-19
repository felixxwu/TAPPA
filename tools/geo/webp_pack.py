# Rewrites a packed level save's heightmap and cover as lossless WebP images (heightWebp / coverWebp), the compact form the game reads.
# Usage: python webp_pack.py <packed.json> [out.json]   (after pack_level.js)
import sys, json, base64, io, numpy as np
from PIL import Image

def b64_webp(img):
    buf = io.BytesIO(); img.save(buf, "WEBP", lossless=True, method=6, exact=True)
    return base64.b64encode(buf.getvalue()).decode()

def rle_decode(b, length):
    out = np.zeros(length, np.uint8); i = o = 0
    while i < len(b):
        t = b[i]; i += 1; n = s = 0
        while True:
            v = b[i]; i += 1; n |= (v & 127) << s; s += 7
            if not v & 128: break
        out[o:o + n] = t; o += n
    return out

def height_image(dm):
    n = int(round(len(dm) ** 0.5)); u = (np.asarray(dm, np.int16).astype(np.int32) + 32768).astype(np.uint16).reshape(n, n)
    return Image.fromarray(np.dstack([u >> 8, u & 255, np.zeros_like(u)]).astype(np.uint8))

def convert(L):
    if isinstance(L.get("heightmap"), str):
        L["heightWebp"] = b64_webp(height_image(np.frombuffer(base64.b64decode(L.pop("heightmap")), "<i2")))
    size = L.get("size", 600)
    if "coverRle" in L:
        L["coverWebp"] = b64_webp(Image.fromarray(rle_decode(base64.b64decode(L.pop("coverRle")), size * size).reshape(size, size)))
    return L

if __name__ == "__main__":
    L = convert(json.load(open(sys.argv[1])))
    json.dump(L, open(sys.argv[2] if len(sys.argv) > 2 else sys.argv[1], "w"), separators=(",", ":"))
