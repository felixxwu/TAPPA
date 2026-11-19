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
const code = coverCode + src.slice(src.indexOf("const r1 ="), src.indexOf("try { level = unpack")) + line("const segSteps =")
  + ["bakeKey", "tangent", "roadSamples"].map(fn).join("");
const { pack, unpack, roadSamples } = new Function("btoa", "atob", code + "return { pack, unpack, roadSamples };")(s => Buffer.from(s, "binary").toString("base64"), s => Buffer.from(s, "base64").toString("binary"));
const lvl = unpack(JSON.parse(fs.readFileSync(process.argv[3], "utf8")));
if (typeof lvl.cover === "string") lvl.cover = Uint8Array.from(Buffer.from(lvl.cover, "base64")); // cover_mask.py writes it already encoded
const TREE_CLEAR = 2, COVER_CLEAR = 0.5; // metres beyond the road's edge kept free: a tree's trunk and low branches, a tuft's spread
const SIZE = lvl.size ?? 600;
const samples = roadSamples(lvl.roads);
// Segments bucketed into 32 m squares, each listed in every square within `reach` of it, so a point only checks the segments that could be that close.
const BUCKET = 32, reach = Math.max(...samples.map(s => s.w)) + TREE_CLEAR + 1, buckets = new Map(), key = (gx, gz) => gx * 65536 + gz;
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
lvl.trees = lvl.trees.filter(t => edge(t.x, t.z) > TREE_CLEAR);
let cleared = 0;
if (lvl.cover) for (let r = 0; r < SIZE; r++) for (let c = 0; c < SIZE; c++) {
  const i = r * SIZE + c;
  if (lvl.cover[i] && edge(c + 0.5 - SIZE / 2, r + 0.5 - SIZE / 2) < COVER_CLEAR) { lvl.cover[i] = 0; cleared++; }
}
console.log(`off the road: ${before - lvl.trees.length} trees, ${cleared} cover cells`);
const packed = JSON.stringify(pack(lvl)), back = unpack(JSON.parse(packed));
let maxH = 0; lvl.heightmap.forEach((h, i) => maxH = Math.max(maxH, Math.abs(h - back.heightmap[i])));
console.log("trees", back.trees.length === lvl.trees.length, back.trees[0].kind, "roads", back.roads.length, "max height error", maxH.toFixed(3), "m");
fs.writeFileSync(process.argv[4] || process.argv[3], packed);
