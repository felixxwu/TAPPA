// Packs make_level.py's unpacked save into the level editor lab's format using the lab's own pack/unpack, checking the
// round trip, and clears every tree and ground-cover cell off the road (measured against every road of the lab's own road network).
// A save with no `gravelPatches` gets one at every dead end (a turning area) and every building (a yard reaching to the nearest road);
// delete the key to have them made again. A building added later that stands in no patch gets its yard on the next run, since the
// game levels the ground in a yard to the road through it. Trees and cover are cleared off every patch.
// The level's `size` (square, metres; missing = 600) sets the cover grid. Usage: node pack_level.js ../level_editor_lab.html data/<name>/level.json ../levels/<name>.json
// Re-running it on an already packed save (one path) just clears the road again in place.
const fs = require("fs"), src = fs.readFileSync(process.argv[2], "utf8");
const fn = name => { const i = src.indexOf("function " + name + "("); return src.slice(i, src.indexOf("\n}\n", i) + 3); };
const line = start => { const i = src.indexOf(start); return src.slice(i, src.indexOf("\n", i) + 1); };
const jsSrc = fs.readFileSync(require("path").join(require("path").dirname(process.argv[2]), "groundcover_tufts.js"), "utf8");
const literal = (text, start) => { const i = text.indexOf(start); return text.slice(i, text.indexOf("\n};", i) + 4).replace(/;?\s*$/, ";\n").replace(start.split(" ")[0] + " ", "var "); };
const oneLine = (text, start) => { const i = text.indexOf(start); return text.slice(i, text.indexOf("\n", i) + 1).replace("const ", "var "); };
const coverCode = oneLine(jsSrc, "const PRESET_BASE") + literal(jsSrc, "const PRESETS = {") + literal(src, "const COVER_RENDER = {");
const KINDS = new Function(literal(src, "const KINDS = {") + "return KINDS;")();
const code = coverCode + src.slice(src.indexOf("const r1 ="), src.indexOf("try { level = unpack")) + line("const segSteps =")
  + ["bakeKey", "tangent", "roadSamples", "junctions", "polygonDistance"].map(fn).join("");
const { pack, unpack, roadSamples, junctions, polygonDistance } = new Function("btoa", "atob", code + "return { pack, unpack, roadSamples, junctions, polygonDistance };")(s => Buffer.from(s, "binary").toString("base64"), s => Buffer.from(s, "base64").toString("binary"));
const raw = JSON.parse(fs.readFileSync(process.argv[3], "utf8")), lvl = unpack(raw);
if (typeof lvl.cover === "string") lvl.cover = Uint8Array.from(Buffer.from(lvl.cover, "base64")); // cover_mask.py writes it already encoded
// A lab download keeps cover as a lossless WebP (red = type id); node can't decode it, so libwebp's dwebp / cwebp do the round trip.
const { execFileSync } = require("child_process"), os = require("os"), path = require("path");
const tmp = path.join(os.tmpdir(), "pack_level_cover");
if (typeof raw.coverWebp === "string") {
  fs.writeFileSync(tmp + ".webp", Buffer.from(raw.coverWebp, "base64"));
  execFileSync("dwebp", [tmp + ".webp", "-ppm", "-o", tmp + ".ppm"], { stdio: "ignore" });
  const ppm = fs.readFileSync(tmp + ".ppm"), n = lvl.size ?? 600, px = ppm.subarray(ppm.length - n * n * 3);
  lvl.cover = Uint8Array.from({ length: n * n }, (_, i) => px[i * 3]);
  delete lvl.coverWebp;
}
const TREE_CLEAR = 0.5, COVER_CLEAR = 0.5; // metres beyond the road's edge kept free: past a tree's low branches (its kind's `low` spread), a tuft's spread
const treeClear = t => TREE_CLEAR + KINDS[t.kind].low * t.sx;
const SIZE = lvl.size ?? 600;
const samples = roadSamples(lvl.roads);
// Segments bucketed into 32 m squares, each listed in every square within `reach` of it, so a point only checks the segments that could be that close.
const BUCKET = 32, reach = Math.max(...samples.map(s => s.w)) + lvl.trees.reduce((m, t) => Math.max(m, treeClear(t)), TREE_CLEAR) + 1, buckets = new Map(), key = (gx, gz) => gx * 65536 + gz;
for (let i = 0; i < samples.length - 1; i++) {
  if (samples[i + 1].first) continue;
  const a = samples[i], b = samples[i + 1];
  for (let gx = Math.floor((Math.min(a.x, b.x) - reach) / BUCKET); gx <= Math.floor((Math.max(a.x, b.x) + reach) / BUCKET); gx++)
    for (let gz = Math.floor((Math.min(a.z, b.z) - reach) / BUCKET); gz <= Math.floor((Math.max(a.z, b.z) + reach) / BUCKET); gz++) {
      const k = key(gx, gz); if (!buckets.has(k)) buckets.set(k, []); buckets.get(k).push(i);
    }
}
// Metres from the road's edge to (x, z); Infinity when no road is within reach.
const edge = (x, z) => {
  let bd = Infinity, bi = -1;
  for (const i of buckets.get(key(Math.floor(x / BUCKET), Math.floor(z / BUCKET))) || []) {
    const a = samples[i], b = samples[i + 1], abx = b.x - a.x, abz = b.z - a.z;
    const t = Math.max(0, Math.min(1, ((x - a.x) * abx + (z - a.z) * abz) / (abx * abx + abz * abz || 1)));
    const d = Math.hypot(x - a.x - abx * t, z - a.z - abz * t);
    if (d < bd) { bd = d; bi = i; }
  }
  return bi < 0 ? Infinity : bd - samples[bi].w;
};
const before = lvl.trees.length;
lvl.trees = lvl.trees.filter(t => edge(t.x, t.z) > treeClear(t));
let cleared = 0;
if (lvl.cover) for (let r = 0; r < SIZE; r++) for (let c = 0; c < SIZE; c++) {
  const i = r * SIZE + c;
  if (lvl.cover[i] && edge(c + 0.5 - SIZE / 2, r + 0.5 - SIZE / 2) < COVER_CLEAR) { lvl.cover[i] = 0; cleared++; }
}
console.log(`off the road: ${before - lvl.trees.length} trees, ${cleared} cover cells`);
// Buildings: nothing grows inside a footprint, and one standing on a slope gets a level pad (the game seats a building on the
// lowest ground under it, so on a slope the uphill side is buried). The pad is the footprint's mean height, blended out over PAD_BLEND m.
const PAD_BLEND = 6, buildings = lvl.buildings ?? [];
const outside = (b, x, z) => { const lx = x - b.x, lz = z - b.z, c = Math.cos(b.rot), s = Math.sin(b.rot);
  return Math.hypot(Math.max(Math.abs(lx * c + lz * s) - b.L / 2, 0), Math.max(Math.abs(-lx * s + lz * c) - b.W / 2, 0)); };
const treesBefore = lvl.trees.length;
lvl.trees = lvl.trees.filter(t => buildings.every(b => outside(b, t.x, t.z) > treeClear(t)));
const treesByBuildings = treesBefore - lvl.trees.length;
let coverIn = 0;
if (lvl.cover) for (const b of buildings) { const R = Math.hypot(b.L, b.W) / 2 + 1;
  for (let r = Math.max(0, Math.floor(b.z - R + SIZE / 2)); r < Math.min(SIZE, b.z + R + SIZE / 2); r++) for (let c = Math.max(0, Math.floor(b.x - R + SIZE / 2)); c < Math.min(SIZE, b.x + R + SIZE / 2); c++) {
    const i = r * SIZE + c; if (lvl.cover[i] && outside(b, c + 0.5 - SIZE / 2, r + 0.5 - SIZE / 2) < COVER_CLEAR) { lvl.cover[i] = 0; coverIn++; } } }
// Gravel patches. A dead end (a road end that meets no other road, away from the square's edge) gets a rough disc of
// DEAD_END_R m just past its end; a building gets its footprint grown by YARD m plus a mouth on the nearest road within
// DRIVE_MAX m. Patches within MERGE_GAP m of each other merge into one (the convex hull of both): two level pads that
// close at different heights would leave a steep ramp between them.
const DEAD_END_R = 9, YARD = 3, DRIVE_MAX = 40, MOUTH = 5, MERGE_GAP = 12;
const hull = pts => { // Andrew's monotone chain
  const p = [...pts].sort((a, b) => a.x - b.x || a.z - b.z), cross = (o, a, b) => (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x), lo = [], hi = [];
  for (const q of p) { while (lo.length > 1 && cross(lo[lo.length - 2], lo[lo.length - 1], q) <= 0) lo.pop(); lo.push(q); }
  for (const q of p.reverse()) { while (hi.length > 1 && cross(hi[hi.length - 2], hi[hi.length - 1], q) <= 0) hi.pop(); hi.push(q); }
  return lo.slice(0, -1).concat(hi.slice(0, -1));
};
let made = 0;
const yard = b => {
  const c = Math.cos(b.rot), s = Math.sin(b.rot), pts = [];
  for (const [u, v] of [[1, 1], [1, -1], [-1, -1], [-1, 1]]) { const lx = u * (b.L / 2 + YARD), lz = v * (b.W / 2 + YARD); pts.push({ x: b.x + lx * c - lz * s, z: b.z + lx * s + lz * c }); }
  let best = null;
  for (let i = 0; i < samples.length - 1; i++) {
    if (samples[i + 1].first) continue;
    const a = samples[i], e = samples[i + 1], abx = e.x - a.x, abz = e.z - a.z, t = Math.max(0, Math.min(1, ((b.x - a.x) * abx + (b.z - a.z) * abz) / (abx * abx + abz * abz || 1)));
    const qx = a.x + abx * t, qz = a.z + abz * t, d = Math.hypot(b.x - qx, b.z - qz);
    if (!best || d < best.d) best = { d, qx, qz, ux: abx / (Math.hypot(abx, abz) || 1), uz: abz / (Math.hypot(abx, abz) || 1) };
  }
  if (best && best.d < DRIVE_MAX) pts.push({ x: best.qx + best.ux * MOUTH, z: best.qz + best.uz * MOUTH }, { x: best.qx - best.ux * MOUTH, z: best.qz - best.uz * MOUTH });
  return hull(pts);
};
const merge = sets => {
  let merged = true, polys = sets.map(hull);
  const touch = (a, b) => a.some(q => polygonDistance(b, q.x, q.z) < MERGE_GAP) || b.some(q => polygonDistance(a, q.x, q.z) < MERGE_GAP);
  while (merged) {
    merged = false;
    for (let i = 0; i < polys.length && !merged; i++) for (let j = i + 1; j < polys.length && !merged; j++)
      if (touch(polys[i], polys[j])) { polys[i] = hull([...polys[i], ...polys[j]]); polys.splice(j, 1); merged = true; }
  }
  return polys.map(p => p.map(q => ({ x: Math.round(q.x * 10) / 10, z: Math.round(q.z * 10) / 10 })));
};
if (lvl.gravelPatches) {
  const bare = buildings.filter(b => lvl.gravelPatches.every(p => p.length < 3 || polygonDistance(p, b.x, b.z) > 0));
  const yards = merge(bare.map(yard));
  lvl.gravelPatches.push(...yards);
  made = yards.length;
} else {
  const sets = [], jitter = (k, s) => { let h = Math.imul(k + 1, 2654435761) ^ Math.imul(s + 7, 40503); h = Math.imul(h ^ h >>> 15, 2246822519); return ((h ^ h >>> 13) >>> 0) / 4294967296; };
  const allNodes = lvl.roads.flatMap((road, c) => road.map(n => ({ n, c })));
  lvl.roads.forEach((road, c) => {
    if (road.length < 2) return;
    for (const [end, prev] of [[road[0], road[1]], [road[road.length - 1], road[road.length - 2]]]) {
      if (Math.max(Math.abs(end.x), Math.abs(end.z)) > SIZE / 2 - 10) continue;
      if (allNodes.some(({ n, c: c2 }) => n !== end && Math.hypot(n.x - end.x, n.z - end.z) < 0.75 && (c2 !== c || n === road[0] || n === road[road.length - 1]))) continue;
      const d = Math.hypot(end.x - prev.x, end.z - prev.z) || 1, cx = end.x + (end.x - prev.x) / d * 3, cz = end.z + (end.z - prev.z) / d * 3;
      sets.push(Array.from({ length: 10 }, (_, k) => { const a = k / 10 * Math.PI * 2, r = DEAD_END_R * (0.85 + 0.25 * jitter(sets.length, k)); return { x: cx + Math.cos(a) * r, z: cz + Math.sin(a) * r }; }));
    }
  });
  for (const b of buildings) sets.push(yard(b));
  lvl.gravelPatches = merge(sets);
  made = lvl.gravelPatches.length;
}
// Fences and hedges clear the same way: trees and cover off the line, hedges by half their 1.4 m base as well.
const lines = (lvl.fences ?? []).filter(f => f.pts.length > 1), halfW = f => f.kind === "hedge" ? 0.7 : 0;
const lineGap = (x, z) => { let g = Infinity; for (const f of lines) for (let i = 0; i < f.pts.length - 1; i++) {
  const [ax, az] = f.pts[i], [bx, bz] = f.pts[i + 1], abx = bx - ax, abz = bz - az, t = Math.max(0, Math.min(1, ((x - ax) * abx + (z - az) * abz) / (abx * abx + abz * abz || 1)));
  g = Math.min(g, Math.hypot(x - ax - abx * t, z - az - abz * t) - halfW(f)); } return g; };
const treesOnLines = lvl.trees.length; let coverOnLines = 0;
if (lines.length) {
  lvl.trees = lvl.trees.filter(t => lineGap(t.x, t.z) > treeClear(t));
  for (const f of lines) for (let i = 0; i < f.pts.length - 1; i++) {
    const [ax, az] = f.pts[i], [bx, bz] = f.pts[i + 1], m = halfW(f) + COVER_CLEAR + 1;
    if (lvl.cover) for (let r = Math.max(0, Math.floor(Math.min(az, bz) - m + SIZE / 2)); r < Math.min(SIZE, Math.max(az, bz) + m + SIZE / 2); r++) for (let c = Math.max(0, Math.floor(Math.min(ax, bx) - m + SIZE / 2)); c < Math.min(SIZE, Math.max(ax, bx) + m + SIZE / 2); c++) {
      const k = r * SIZE + c; if (lvl.cover[k] && lineGap(c + 0.5 - SIZE / 2, r + 0.5 - SIZE / 2) < COVER_CLEAR) { lvl.cover[k] = 0; coverOnLines++; } }
  }
}
console.log(`fences: ${treesOnLines - lvl.trees.length} trees, ${coverOnLines} cover cells cleared off ${lines.length} lines`);
const patches = lvl.gravelPatches.filter(p => p.length >= 3), box = p => [Math.min(...p.map(q => q.x)), Math.min(...p.map(q => q.z)), Math.max(...p.map(q => q.x)), Math.max(...p.map(q => q.z))];
const boxes = patches.map(box), padGap = (x, z, m) => Math.min(...patches.map((p, i) => { const b = boxes[i];
  return x < b[0] - m || z < b[1] - m || x > b[2] + m || z > b[3] + m ? Infinity : polygonDistance(p, x, z); }));
const treesOnPads = lvl.trees.length;
lvl.trees = lvl.trees.filter(t => padGap(t.x, t.z, treeClear(t) + 1) > treeClear(t));
let coverOnPads = 0;
if (lvl.cover) patches.forEach((p, i) => { const b = boxes[i];
  for (let r = Math.max(0, Math.floor(b[1] - 1 + SIZE / 2)); r < Math.min(SIZE, b[3] + 1 + SIZE / 2); r++) for (let c = Math.max(0, Math.floor(b[0] - 1 + SIZE / 2)); c < Math.min(SIZE, b[2] + 1 + SIZE / 2); c++) {
    const k = r * SIZE + c; if (lvl.cover[k] && polygonDistance(p, c + 0.5 - SIZE / 2, r + 0.5 - SIZE / 2) < COVER_CLEAR) { lvl.cover[k] = 0; coverOnPads++; } } });
console.log(`gravel patches: ${made} made, ${patches.length} in all; ${treesOnPads - lvl.trees.length} trees, ${coverOnPads} cover cells cleared off them`);
let hm = lvl.heightmap;
if (typeof raw.heightWebp === "string") {
  fs.writeFileSync(tmp + ".webp", Buffer.from(raw.heightWebp, "base64"));
  execFileSync("dwebp", [tmp + ".webp", "-ppm", "-o", tmp + ".ppm"], { stdio: "ignore" });
  const ppm = fs.readFileSync(tmp + ".ppm"), n = Math.round(Math.sqrt((ppm.length - 15) / 3)), px = ppm.subarray(ppm.length - n * n * 3);
  hm = Float32Array.from({ length: n * n }, (_, i) => ((px[i * 3] << 8 | px[i * 3 + 1]) - 32768) / 10);
}
let pads = 0;
if (hm) { const hn = Math.round(Math.sqrt(hm.length)), HC = SIZE / (hn - 1);
  const reach = b => Math.hypot(b.L, b.W) / 2 + HC + PAD_BLEND;
  // Buildings whose pads would overlap share one, or each would tilt its neighbour's.
  const group = buildings.map((_, i) => i), find = i => group[i] === i ? i : group[i] = find(group[i]);
  buildings.forEach((a, i) => buildings.forEach((b, j) => { if (j > i && Math.hypot(a.x - b.x, a.z - b.z) < reach(a) + reach(b)) group[find(i)] = find(j); }));
  const groups = new Map(); buildings.forEach((b, i) => { const g = find(i); if (!groups.has(g)) groups.set(g, []); groups.get(g).push(b); });
  for (const bs of groups.values()) {
    const cells = new Map();
    for (const b of bs) { const R = reach(b);
      for (let r = Math.max(0, Math.floor((b.z - R) / HC + (hn - 1) / 2)); r < Math.min(hn, (b.z + R) / HC + (hn - 1) / 2); r++)
        for (let c = Math.max(0, Math.floor((b.x - R) / HC + (hn - 1) / 2)); c < Math.min(hn, (b.x + R) / HC + (hn - 1) / 2); c++) {
          const d = Math.max(0, outside(b, c * HC - SIZE / 2, r * HC - SIZE / 2) - HC), i = r * hn + c; // flat a grid cell past the walls, so every corner sits on it
          if (d < PAD_BLEND && !(cells.get(i) <= d)) cells.set(i, d);
        } }
    const roadAt = i => Math.min(1, Math.max(0, 1 - (edge((i % hn) * HC - SIZE / 2, Math.floor(i / hn) * HC - SIZE / 2) - HC) / 4)); // roads keep their ground: held up to a grid cell past the edge, eased over 4 m
    const inner = [...cells].filter(([i, d]) => !d && !roadAt(i)).map(([i]) => hm[i]);
    if (!inner.length || Math.max(...inner) - Math.min(...inner) < 0.5) continue; // already level: re-runs leave it alone
    const target = inner.reduce((a, h) => a + h, 0) / inner.length, was = new Map([...cells].map(([i]) => [i, hm[i]]));
    const under = bs.map(b => [...cells.keys()].filter(i => outside(b, (i % hn) * HC - SIZE / 2, Math.floor(i / hn) * HC - SIZE / 2) <= HC / 2));
    const spread = () => under.map(is => is.length ? Math.max(...is.map(i => hm[i])) - Math.min(...is.map(i => hm[i])) : 0), before = spread();
    for (const [i, d] of cells) {
      const t = d / PAD_BLEND, k = Math.max(t * t * (3 - 2 * t), roadAt(i));
      hm[i] = target + (hm[i] - target) * k;
    }
    if (spread().some((v, k) => v > Math.max(before[k], 0.3))) { for (const [i, h] of was) hm[i] = h; continue; } // a road held at its height can leave a building on rougher ground: keep the original then
    pads++;
  }
}
console.log(`buildings: ${treesByBuildings} trees, ${coverIn} cover cells cleared, ${pads} levelled`);
const out = { ...pack(lvl), ...((lvl.coverWebp || raw.coverWebp) && { coverKinds: raw.coverKinds }) };
if (pads && typeof raw.heightWebp === "string") {
  const n = Math.round(Math.sqrt(hm.length)), px = Buffer.alloc(n * n * 3);
  hm.forEach((h, i) => { const u = Math.round(h * 10) + 32768; px[i * 3] = u >> 8; px[i * 3 + 1] = u & 255; });
  fs.writeFileSync(tmp + ".ppm", Buffer.concat([Buffer.from(`P6\n${n} ${n}\n255\n`), px]));
  execFileSync("cwebp", ["-lossless", "-exact", "-z", "9", tmp + ".ppm", "-o", tmp + ".webp"], { stdio: "ignore" });
  out.heightWebp = fs.readFileSync(tmp + ".webp").toString("base64");
}
if (typeof raw.coverWebp === "string") {
  const n = lvl.size ?? 600, px = Buffer.alloc(n * n * 3);
  lvl.cover.forEach((id, i) => px.fill(id, i * 3, i * 3 + 3));
  fs.writeFileSync(tmp + ".ppm", Buffer.concat([Buffer.from(`P6\n${n} ${n}\n255\n`), px]));
  execFileSync("cwebp", ["-lossless", "-exact", "-z", "9", tmp + ".ppm", "-o", tmp + ".webp"], { stdio: "ignore" });
  out.coverWebp = fs.readFileSync(tmp + ".webp").toString("base64"); delete out.coverRle;
}
const packed = JSON.stringify(out), back = unpack(JSON.parse(packed));
let maxH = 0; lvl.heightmap?.forEach((h, i) => maxH = Math.max(maxH, Math.abs(h - back.heightmap[i])));
console.log("trees", back.trees.length === lvl.trees.length, back.trees[0].kind, "roads", back.roads.length, "max height error", maxH.toFixed(3), "m");
fs.writeFileSync(process.argv[4] || process.argv[3], packed);
