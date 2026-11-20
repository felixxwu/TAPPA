// Packs make_level.py's unpacked save into the level editor lab's format using the lab's own pack/unpack, checking the
// round trip, and clears every tree and ground-cover cell off the road (measured against every road of the lab's own road network).
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
  + ["bakeKey", "tangent", "roadSamples"].map(fn).join("");
const { pack, unpack, roadSamples } = new Function("btoa", "atob", code + "return { pack, unpack, roadSamples };")(s => Buffer.from(s, "binary").toString("base64"), s => Buffer.from(s, "base64").toString("binary"));
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
let coverIn = 0;
if (lvl.cover) for (const b of buildings) { const R = Math.hypot(b.L, b.W) / 2 + 1;
  for (let r = Math.max(0, Math.floor(b.z - R + SIZE / 2)); r < Math.min(SIZE, b.z + R + SIZE / 2); r++) for (let c = Math.max(0, Math.floor(b.x - R + SIZE / 2)); c < Math.min(SIZE, b.x + R + SIZE / 2); c++) {
    const i = r * SIZE + c; if (lvl.cover[i] && outside(b, c + 0.5 - SIZE / 2, r + 0.5 - SIZE / 2) < COVER_CLEAR) { lvl.cover[i] = 0; coverIn++; } } }
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
console.log(`buildings: ${treesBefore - lvl.trees.length} trees, ${coverIn} cover cells cleared, ${pads} levelled`);
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
