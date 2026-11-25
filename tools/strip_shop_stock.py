#!/usr/bin/env python3
"""Strips stock-tied dressing (bay paint, kerb stops, price tags and boards) from exported shop .glb files, in place.

Usage: strip_shop_stock.py [--dry] models/shops/*.glb
"""
import json, struct, sys

def srgb(c):
    f = lambda v: round(v * 255)  # the lab's exporter writes the sRGB values straight into baseColorFactor
    return "#%02x%02x%02x" % tuple(f(v) for v in c[:3])

def mul(a, b):
    return [sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4)) for c in range(4) for r in range(4)]

def local(n):
    if "matrix" in n:
        return n["matrix"]
    t, q, s = n.get("translation", [0, 0, 0]), n.get("rotation", [0, 0, 0, 1]), n.get("scale", [1, 1, 1])
    x, y, z, w = q
    r = [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
         2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
         2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0]
    return [r[0] * s[0], r[1] * s[0], r[2] * s[0], 0, r[4] * s[1], r[5] * s[1], r[6] * s[1], 0,
            r[8] * s[2], r[9] * s[2], r[10] * s[2], 0, t[0], t[1], t[2], 1]

def classify(color, dims, y_lo, y_hi):
    d = sorted(dims)
    thin = d[0] <= 0.025
    if color in ("#eeeeee", "#e8c830") and thin and y_hi <= 0.1 and y_lo >= 0.0:
        return "bay line"
    if color == "#777777" and abs(dims[1] - 0.12) < 0.005 and abs(dims[2] - 0.14) < 0.005 and y_hi <= 0.14:
        return "kerb stop"
    if color == "#f4efdc":
        return "price tag backing"
    return None

def process(path, dry):
    f = open(path, "rb").read()
    jl = struct.unpack("<I", f[12:16])[0]
    j = json.loads(f[20:20 + jl])
    nodes = j["nodes"]
    world, parent = {}, {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            parent[c] = i
    def wm(i):
        if i not in world:
            m = local(nodes[i])
            world[i] = mul(wm(parent[i]), m) if i in parent else m
        return world[i]
    found = []
    for i, n in enumerate(nodes):
        if "mesh" not in n:
            continue
        prim = j["meshes"][n["mesh"]]["primitives"][0]
        acc = j["accessors"][prim["attributes"]["POSITION"]]
        mat = j["materials"][prim["material"]]["pbrMetallicRoughness"]["baseColorFactor"] if "material" in prim else [1, 1, 1]
        m = wm(i)
        lo, hi = acc["min"], acc["max"]
        ys, dims = [], []
        for ax in range(3):
            sc = sum(m[ax * 4 + k] ** 2 for k in range(3)) ** 0.5
            dims.append((hi[ax] - lo[ax]) * sc)
        for cx in (lo, hi):
            for cy in (lo, hi):
                for cz in (lo, hi):
                    ys.append(m[1] * cx[0] + m[5] * cy[1] + m[9] * cz[2] + m[13])
        # dims are along the local axes; for rotated boxes the thin axis is still one of them
        kind = classify(srgb(mat), dims, min(ys), max(ys))
        if kind:
            found.append((i, kind, srgb(mat), [round(d, 3) for d in dims], round(min(ys), 3), round(max(ys), 3)))
    # post under a price tag: thin dark post 0.05 x 0.9 x 0.05 sitting on the ground, next to a removed backing
    backs = [x for x in found if x[1] == "price tag backing"]
    for i, n in enumerate(nodes):
        if "mesh" not in n or any(x[0] == i for x in found):
            continue
        prim = j["meshes"][n["mesh"]]["primitives"][0]
        acc = j["accessors"][prim["attributes"]["POSITION"]]
        color = srgb(j["materials"][prim["material"]]["pbrMetallicRoughness"]["baseColorFactor"])
        m = wm(i)
        dims = [(acc["max"][a] - acc["min"][a]) * sum(m[a * 4 + k] ** 2 for k in range(3)) ** 0.5 for a in range(3)]
        if color == "#444444" and all(abs(d - e) < 0.005 for d, e in zip(dims, [0.05, 0.9, 0.05])) and abs(m[13] - 0.49) < 0.01:
            found.append((i, "price post", color, [round(d, 3) for d in dims], 0.04, 0.94))
    for x in found:
        print(f"  {path.split('/')[-1]}: node {x[0]} {x[1]} {x[2]} dims {x[3]} y {x[4]}..{x[5]}")
    if not dry and found:
        gone = {x[0] for x in found}
        for n in nodes:
            if "children" in n:
                n["children"] = [c for c in n["children"] if c not in gone]
        for i in gone:
            nodes[i].pop("mesh", None)
        js = json.dumps(j, separators=(",", ":")).encode()
        js += b" " * (-len(js) % 4)
        rest = f[20 + jl:]
        out = f[:8] + struct.pack("<I", 12 + 8 + len(js) + len(rest)) + struct.pack("<I", len(js)) + b"JSON" + js + rest
        open(path, "wb").write(out)
    from collections import Counter
    print(f"{path}: {dict(Counter(x[1] for x in found))}")

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--dry"]
    for p in args:
        process(p, "--dry" in sys.argv)
