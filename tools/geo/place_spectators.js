// Scatters spectator groups ({x, z, r, n}) over the 5 km level: near buildings, inside road bends and by junctions,
// every circle overlapping the road edge so the game fills it with people right up to the verge.
// Usage: node tools/geo/place_spectators.js [level.json]. Rewrites only the `spectators` key, bytes elsewhere untouched.
const fs = require("fs");
const file = process.argv[2] || __dirname + "/../levels/hafren_5km.json";
const raw = fs.readFileSync(file, "utf8");
const lvl = JSON.parse(raw);
const half = lvl.size / 2;

let s = 12345;
const rnd = () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296);
const between = (a, b) => a + (b - a) * rnd();
const r1 = (v) => Math.round(v * 10) / 10;

const roadSegs = [];
const junctions = [];
const corners = [];
for (const ch of lvl.roads) {
  for (let i = 0; i + 1 < ch.length; i++) roadSegs.push([ch[i].x, ch[i].z, ch[i + 1].x, ch[i + 1].z, Math.max(ch[i].w, ch[i + 1].w)]);
  for (let i = 1; i + 1 < ch.length; i++) {
    const a = ch[i - 1], b = ch[i], c = ch[i + 1];
    const d1 = Math.atan2(b.z - a.z, b.x - a.x), d2 = Math.atan2(c.z - b.z, c.x - b.x);
    let t = d2 - d1;
    t = Math.atan2(Math.sin(t), Math.cos(t));
    if (Math.abs(t) > 0.5 && Math.hypot(b.x - a.x, b.z - a.z) > 6) {
      const bx = Math.cos(d2) - Math.cos(d1 + Math.PI), bz = Math.sin(d2) - Math.sin(d1 + Math.PI);
      const m = Math.hypot(bx, bz) || 1;
      corners.push({ x: b.x, z: b.z, w: b.w, ix: bx / m, iz: bz / m, sharp: Math.abs(t) });
    }
  }
}
const ends = lvl.roads.flatMap((ch) => [ch[0], ch[ch.length - 1]]);
const allNodes = lvl.roads.flat();
for (const e of ends) {
  if (allNodes.filter((n) => Math.hypot(n.x - e.x, n.z - e.z) < 0.75).length > 1 && !junctions.some((j) => Math.hypot(j.x - e.x, j.z - e.z) < 5)) junctions.push(e);
}

const segDist = (px, pz, [x1, z1, x2, z2]) => {
  const dx = x2 - x1, dz = z2 - z1;
  const t = Math.max(0, Math.min(1, ((px - x1) * dx + (pz - z1) * dz) / (dx * dx + dz * dz || 1)));
  return Math.hypot(px - x1 - t * dx, pz - z1 - t * dz);
};
const CELL = 100, segGrid = new Map();
roadSegs.forEach((sg) => {
  const x0 = Math.floor((Math.min(sg[0], sg[2]) - 40) / CELL), x1 = Math.floor((Math.max(sg[0], sg[2]) + 40) / CELL);
  const z0 = Math.floor((Math.min(sg[1], sg[3]) - 40) / CELL), z1 = Math.floor((Math.max(sg[1], sg[3]) + 40) / CELL);
  for (let i = x0; i <= x1; i++) for (let j = z0; j <= z1; j++) { const k = i + "," + j; (segGrid.get(k) || segGrid.set(k, []).get(k)).push(sg); }
});
const nearSegs = (x, z) => segGrid.get(Math.floor(x / CELL) + "," + Math.floor(z / CELL)) || [];
const roadClear = (x, z) => {
  let m = 1e9;
  for (const sg of nearSegs(x, z)) m = Math.min(m, segDist(x, z, sg) - sg[4]);
  return m;
};
const ONTO_ROAD = 2;
// Moves a circle of radius r so it sits on the side of the nearest road that (x, z) is on, overlapping its edge by ONTO_ROAD.
const snapToEdge = (x, z, r) => {
  let best = null;
  for (const sg of nearSegs(x, z)) {
    const d = segDist(x, z, sg) - sg[4];
    if (!best || d < best.d) best = { d, sg };
  }
  if (!best) return null;
  const [x1, z1, x2, z2, w] = best.sg, dx = x2 - x1, dz = z2 - z1;
  const t = Math.max(0, Math.min(1, ((x - x1) * dx + (z - z1) * dz) / (dx * dx + dz * dz || 1)));
  const fx = x1 + t * dx, fz = z1 + t * dz, m = Math.hypot(x - fx, z - fz);
  if (m < 1e-3) return null;
  const k = w + r - ONTO_ROAD;
  return [fx + (x - fx) / m * k, fz + (z - fz) / m * k];
};

const bin = Buffer.from(lvl.treesBin, "base64");
const tg = new Map();
for (let o = 0; o + 7 <= bin.length; o += 7) {
  const x = bin.readUInt16LE(o) / 10 - half, z = bin.readUInt16LE(o + 2) / 10 - half;
  const k = Math.floor(x / 20) + "," + Math.floor(z / 20);
  (tg.get(k) || tg.set(k, []).get(k)).push(x, z);
}
const treeCount = (x, z, r) => {
  let n = 0;
  for (let i = Math.floor((x - r) / 20); i <= Math.floor((x + r) / 20); i++)
    for (let j = Math.floor((z - r) / 20); j <= Math.floor((z + r) / 20); j++) {
      const a = tg.get(i + "," + j) || [];
      for (let q = 0; q < a.length; q += 2) if (Math.hypot(a[q] - x, a[q + 1] - z) < r) n++;
    }
  return n;
};

const rectDist = (b, x, z) => {
  const dx = x - b.x, dz = z - b.z, c = Math.cos(b.rot), sn = Math.sin(b.rot);
  const u = Math.abs(dx * c + dz * sn) - b.L / 2, v = Math.abs(-dx * sn + dz * c) - b.W / 2;
  return Math.hypot(Math.max(u, 0), Math.max(v, 0)) + Math.min(Math.max(u, v), 0);
};

const placed = [];
const fits = (x, z, r) =>
  Math.abs(x) + r < half && Math.abs(z) + r < half &&
  roadClear(x, z) > r - ONTO_ROAD - 0.5 &&
  lvl.buildings.every((b) => rectDist(b, x, z) > 2) &&
  placed.every((p) => Math.hypot(p.x - x, p.z - z) > p.r + r + 1);
// Trees per m2 inside the circle; lower is more open.
const density = (x, z, r) => treeCount(x, z, r) / (Math.PI * r * r);
const MAX_DENSITY = 0.02;

const kinds = {
  building: { hot: 6, small: 40, anchors: lvl.buildings.filter((b) => roadClear(b.x, b.z) < 80), at: (b) => [b.x + between(-25, 25), b.z + between(-25, 25)] },
  corner: { hot: 5, small: 45, anchors: corners, at: (c) => { const p = between(-4, 4); return [c.x + c.ix * (c.w + 3) - c.iz * p, c.z + c.iz * (c.w + 3) + c.ix * p]; } },
  junction: { hot: 2, small: 18, anchors: junctions, at: (j) => { const a = rnd() * 6.283, d = j.w + between(4, 16); return [j.x + Math.cos(a) * d, j.z + Math.sin(a) * d]; } },
};
const counts = {};
for (const [kind, K] of Object.entries(kinds)) {
  counts[kind] = { groups: 0, people: 0 };
  const anchors = K.anchors.map((a) => [rnd(), a]).sort((p, q) => (p[1].sharp || 0) * 0 + p[0] - q[0]).map((p) => p[1]);
  if (kind === "corner") anchors.sort((a, b) => b.sharp - a.sharp + (rnd() - 0.5) * 0.6);
  const todo = [...Array(K.hot).fill("hot"), ...Array(K.small).fill("small")];
  for (const type of todo) {
    let best = null;
    for (let t = 0; t < 400; t++) {
      const a = anchors[Math.floor(rnd() * Math.min(anchors.length, kind === "corner" ? 120 : anchors.length))];
      const r = type === "hot" ? between(10, 16) : between(4, 7);
      const at = snapToEdge(...K.at(a), r);
      if (!at) continue;
      const [x, z] = at;
      if (!fits(x, z, r)) continue;
      const d = density(x, z, r);
      if (d > MAX_DENSITY) continue;
      if (!best || d < best.d) best = { x: r1(x), z: r1(z), r: r1(r), d };
      if (t > 60 && best) break;
    }
    if (!best) continue;
    best.n = type === "hot" ? Math.round(between(30, 60)) : Math.round(between(6, 16));
    best.kind = kind;
    placed.push(best);
    counts[kind].groups++;
    counts[kind].people += best.n;
  }
}
console.log(counts, "total", placed.length, "groups", placed.reduce((a, p) => a + p.n, 0), "people");

const val = JSON.stringify(placed.map(({ x, z, r, n }) => ({ x, z, r, n })));
let out;
const m = raw.match(/,"spectators":\[[^\]]*\]/);
if (m) out = raw.replace(m[0], () => ',"spectators":' + val);
else {
  const lp = raw.match(/"logPiles":\[[^\]]*\]/);
  out = raw.replace(lp[0], () => lp[0] + ',"spectators":' + val);
}
fs.writeFileSync(file, out);
