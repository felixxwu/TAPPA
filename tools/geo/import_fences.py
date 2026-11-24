"""Writes the `fences` key of tools/levels/hafren_5km.json from OSM fences/hedges plus hand-authored lines."""
import json, sys, xml.etree.ElementTree as ET
from pathlib import Path
from pyproj import Transformer

HERE = Path(__file__).parent
LEVEL = HERE.parent / "levels" / "hafren_5km.json"
OSM = HERE / "data/hafren_5km/osm.xml"
AUTHORED = HERE / "hafren_fences_authored.json"
HALF, TOL, MIN_LEN = 2500.0, 0.3, 3.0


def rdp(p, tol):
    if len(p) < 3:
        return p
    (x1, z1), (x2, z2) = p[0], p[-1]
    dx, dz = x2 - x1, z2 - z1
    n = (dx * dx + dz * dz) ** 0.5 or 1e-9
    d = [abs(dz * (x - x1) - dx * (z - z1)) / n for x, z in p[1:-1]]
    i = max(range(len(d)), key=d.__getitem__)
    if d[i] <= tol:
        return [p[0], p[-1]]
    return rdp(p[:i + 2], tol)[:-1] + rdp(p[i + 1:], tol)


def clip_seg(a, b):
    t0, t1, dx, dz = 0.0, 1.0, b[0] - a[0], b[1] - a[1]
    for p, q in ((-dx, a[0] + HALF), (dx, HALF - a[0]), (-dz, a[1] + HALF), (dz, HALF - a[1])):
        if p == 0:
            if q < 0:
                return None
            continue
        t = q / p
        if p < 0:
            t0 = max(t0, t)
        else:
            t1 = min(t1, t)
    if t0 >= t1:
        return None
    return (a[0] + t0 * dx, a[1] + t0 * dz), (a[0] + t1 * dx, a[1] + t1 * dz)


def clip(pts):
    out, cur = [], []
    for a, b in zip(pts, pts[1:]):
        s = clip_seg(a, b)
        if s is None:
            if len(cur) > 1:
                out.append(cur)
            cur = []
            continue
        if cur and (abs(cur[-1][0] - s[0][0]) > 1e-6 or abs(cur[-1][1] - s[0][1]) > 1e-6):
            out.append(cur)
            cur = []
        if not cur:
            cur = [s[0]]
        cur.append(s[1])
    if len(cur) > 1:
        out.append(cur)
    return out


def osm_lines():
    to_bng = Transformer.from_crs(4326, 27700, always_xy=True)
    root = ET.parse(OSM).getroot()
    nodes = {n.get("id"): (float(n.get("lon")), float(n.get("lat"))) for n in root.iter("node")}
    res = []
    for w in root.iter("way"):
        kind = next((t.get("v") for t in w.iter("tag") if t.get("k") == "barrier" and t.get("v") in ("fence", "hedge")), None)
        if not kind:
            continue
        pts = []
        for nd in w.iter("nd"):
            e, n = to_bng.transform(*nodes[nd.get("ref")])
            pts.append((e - 285500, 287400 - n))
        for seg in clip(pts):
            seg = rdp(seg, TOL)
            if sum(((a[0]-b[0])**2 + (a[1]-b[1])**2) ** .5 for a, b in zip(seg, seg[1:])) >= MIN_LEN:
                res.append({"kind": kind, "pts": [[round(x, 1), round(z, 1)] for x, z in seg]})
    return res


def length(fs):
    return sum(((a[0]-b[0])**2 + (a[1]-b[1])**2) ** .5 for f in fs for a, b in zip(f["pts"], f["pts"][1:])) / 1000


if __name__ == "__main__":
    osm = osm_lines()
    auth = json.load(open(AUTHORED)) if AUTHORED.exists() else []
    allf = osm + auth
    lvl = json.load(open(LEVEL))
    if allf:
        lvl["fences"] = allf
    else:
        lvl.pop("fences", None)
    json.dump(lvl, open(LEVEL, "w"), separators=(",", ":"))
    print(f"osm {len(osm)} lines {length(osm):.2f} km; authored {len(auth)} lines {length(auth):.2f} km", file=sys.stderr)
