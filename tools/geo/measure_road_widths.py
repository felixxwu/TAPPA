# Sets each Hafren road's half-width from the satellite image; roads hidden under trees or edited by hand get a typical width of their class.
# Usage (from tools/geo): python measure_road_widths.py  -> rewrites ../levels/hafren_5km.json, then re-run pack_level.js
import json, math, sys, hashlib
import numpy as np
from PIL import Image
from scipy import ndimage as nd
Image.MAX_IMAGE_PIXELS = None

GEO = 'data/hafren_5km/'
LEVEL = '../levels/hafren_5km.json'
OUT = sys.argv[1] if len(sys.argv) > 1 else LEVEL

lvl = json.load(open(LEVEL))
gen = json.load(open(GEO + 'level.json'))['roads']
key = lambda c: tuple((round(p['x'], 1), round(p['z'], 1)) for p in c)
gen_keys = {key(c) for c in gen} | {key(c)[::-1] for c in gen}
gen_w = {(round(p['x'], 1), round(p['z'], 1)): p['w'] for c in gen for p in c}
class_of = lambda p: gen_w.get((round(p['x'], 1), round(p['z'], 1)), p['w'])

rgb = np.asarray(Image.open(GEO + 'satellite_5km.jpg').convert('RGB'))
R, G, B = (rgb[..., i].astype(np.float32) for i in range(3))
score = (R + G + B) / 3 - 2 * np.maximum(0, G - (R + B) / 2)
del R, G, B, rgb
score = nd.uniform_filter(score, 2)
chm = np.load(GEO + 'dsm_5km.npy') - np.load(GEO + 'dtm_5km.npy')
chm = nd.maximum_filter(chm, 5)

T = np.arange(-12, 12.001, 0.25)

def measure(x, z, nx, nz):
    if chm[int(z + 2500), int(x + 2500)] > 3: return None
    px, pz = (x + nx * T + 2500) * 2, (z + nz * T + 2500) * 2
    s = nd.map_coordinates(score, [pz, px], order=1)
    near = np.abs(T) <= 4
    i = int(np.argmax(np.where(near, s, -1e9)))
    bg = np.median(s[np.abs(T) >= 6])
    if s[i] - bg < 35: return None
    thr = bg + 0.5 * (s[i] - bg)
    a = b = i
    while a > 0 and s[a - 1] > thr: a -= 1
    while b < len(T) - 1 and s[b + 1] > thr: b += 1
    if a == 0 or b == len(T) - 1: return None
    w = (b - a + 1) * 0.25
    return w if 1.5 <= w <= 14 else None

ends = np.array([(p['x'], p['z']) for c in lvl['roads'] for p in (c[0], c[-1])])
near_end = lambda x, z: np.min(np.hypot(ends[:, 0] - x, ends[:, 1] - z)) < 15
groups = {}  # (chain, original half-width) -> [samples tried, widths measured]
for ci, c in enumerate(lvl['roads']):
    for p, q in zip(c, c[1:]):
        L = math.dist((p['x'], p['z']), (q['x'], q['z']))
        if L < 1: continue
        tx, tz = (q['x'] - p['x']) / L, (q['z'] - p['z']) / L
        cls = max(class_of(p), class_of(q))
        g = groups.setdefault((ci, cls), [0, []])
        for k in range(int(L // 5) + 1):
            f = (k * 5 + 2.5) / L
            if f > 1: break
            x, z = p['x'] + f * (q['x'] - p['x']), p['z'] + f * (q['z'] - p['z'])
            if near_end(x, z): continue
            g[0] += 1
            w = measure(x, z, -tz, tx)
            if w is not None: g[1].append(w)

edited = {ci for ci, c in enumerate(lvl['roads']) if key(c) not in gen_keys}
measured = {}
for (ci, cls), (n, ws) in groups.items():
    if ci in edited or len(ws) < 6 or len(ws) < 0.2 * n: continue
    measured[(ci, cls)] = float(np.median(ws))

by_cls = {}
for (ci, cls), w in measured.items(): by_cls.setdefault(cls, []).append(w)
allw = [w for v in by_cls.values() for w in v]
print('edited chains', len(edited), 'groups', len(groups), 'measured', len(measured))
for cls, v in sorted(by_cls.items()):
    print(f'class w={cls}: n={len(v)} full width median {np.median(v):.2f} IQR {np.percentile(v,25):.2f}-{np.percentile(v,75):.2f}')

def invented(ci, cls):
    v = by_cls.get(cls) if len(by_cls.get(cls, [])) >= 5 else allw
    lo, hi = np.percentile(v, 25), np.percentile(v, 75)
    h = int(hashlib.md5(f'{ci}/{cls}'.encode()).hexdigest()[:8], 16) / 0xffffffff
    return lo + h * (hi - lo)

half = {}
for g in groups:
    half[g] = round((measured[g] if g in measured else invented(*g)) / 2, 1)

for ci, c in enumerate(lvl['roads']):
    old = [class_of(p) for p in c]
    for i, p in enumerate(c):
        adj = [max(old[j], old[j + 1]) for j in (i - 1, i) if 0 <= j < len(c) - 1]
        p['w'] = max(half.get((ci, a), p['w']) for a in adj) if adj else p['w']

json.dump(lvl, open(OUT, 'w'), separators=(',', ':'))
from collections import Counter
print('new half-widths', sorted(Counter(p['w'] for c in lvl['roads'] for p in c).items()))
