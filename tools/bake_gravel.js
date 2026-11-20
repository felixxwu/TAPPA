// Bakes the level view's two road tiles, laid over the road by both the game (level_ground.gdshader) and the lab
// (level_editor_lab.html). Run: node tools/bake_gravel.js
// textures/gravel-forest.png: RGB is a stone's colour; alpha is its rank, and the shaders show a stone only where the road's
// looseness exceeds it, so the ruts keep a few stones and the crown gets them all. Gaps between stones have rank 1 and show the shader's dust.
// textures/tarmac.png: the same idea for asphalt chippings, where alpha is how much wear it takes to strip the binder off a
// chip, so worn wheel tracks show pale stone and the rest stays dark binder.
const fs = require("fs"), zlib = require("zlib");
const PX = 256;                 // 2.5 cm texels over the 6.4 m tile the shaders assume
const LAYERS = [                // cells per tile (an integer, so the tile wraps), rank range: big stones only on loose ground
  { cells: 56, rank: [0.65, 1.0], seed: 11 },
  { cells: 136, rank: [0.0, 1.0], seed: 23 },
];

function hash(x, y, s) {
  let h = Math.imul(x | 0, 374761393) ^ Math.imul(y | 0, 668265263) ^ Math.imul(s | 0, 2147483647);
  h = Math.imul(h ^ h >>> 13, 1274126177);
  return ((h ^ h >>> 16) >>> 0) / 4294967296;
}
const wrap = (i, n) => ((i % n) + n) % n;

// Voronoi over a wrapping grid: the nearest stone's id and how far this point is from the gap to the next one.
function stones(u, v, L) {
  const px = u * L.cells, py = v * L.cells, ix = Math.floor(px), iy = Math.floor(py);
  let d1 = 9, d2 = 9, id = null;
  for (let y = -1; y <= 1; y++) for (let x = -1; x <= 1; x++) {
    const cx = wrap(ix + x, L.cells), cy = wrap(iy + y, L.cells);
    const ox = ix + x + hash(cx, cy, L.seed), oy = iy + y + hash(cx, cy, L.seed + 1);
    const d = Math.hypot(ox - px, oy - py);
    if (d < d1) { d2 = d1; d1 = d; id = [cx, cy]; } else if (d < d2) d2 = d;
  }
  return { tone: hash(id[0], id[1], L.seed + 2), pick: hash(id[0], id[1], L.seed + 3), gap: d2 - d1 };
}

const smooth = (a, b, x) => { const t = Math.max(0, Math.min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
let img = Buffer.alloc(PX * PX * 4);
for (let y = 0; y < PX; y++) for (let x = 0; x < PX; x++) {
  let out = [0.5, 0.48, 0.44, 1];  // dust, shown only by mipmaps far away
  for (const L of LAYERS) {         // later (smaller) layers sit under earlier (bigger) ones
    const s = stones((x + 0.5) / PX, (y + 0.5) / PX, L);
    if (s.gap < 0.08 || (out[3] < 1 && L !== LAYERS[0])) continue;
    const grey = 0.43 + 0.19 * s.tone, warm = s.pick > 0.8 ? [1.08, 0.97, 0.86] : [1, 1, 1];
    const edge = 0.7 + 0.3 * smooth(0.08, 0.3, s.gap);  // stones darken towards their rims
    out = [grey * warm[0] * edge, grey * warm[1] * edge * 0.985, grey * warm[2] * edge * 0.95, L.rank[0] + (L.rank[1] - L.rank[0]) * s.pick];
  }
  for (let c = 0; c < 4; c++) img[(y * PX + x) * 4 + c] = Math.round(Math.max(0, Math.min(1, out[c])) * 255);
}

writePng("gravel-forest.png");

// Tarmac: 1.25 cm texels over 3.2 m, chippings about 3 cm across packed edge to edge, in a dark binder.
const CHIPS = { cells: 107, seed: 41 }, FINES = { cells: 256, seed: 53 };
img = Buffer.alloc(PX * PX * 4);
for (let y = 0; y < PX; y++) for (let x = 0; x < PX; x++) {
  const u = (x + 0.5) / PX, v = (y + 0.5) / PX, c = stones(u, v, CHIPS), f = stones(u, v, FINES);
  let out;
  if (c.gap < 0.12) out = [0.16, 0.16, 0.17, 0.02];  // binder between chips: never worn through
  else {
    const grey = c.pick > 0.93 ? 0.72 : 0.36 + 0.2 * c.tone, edge = 0.75 + 0.25 * smooth(0.12, 0.35, c.gap);
    out = [grey * edge, grey * edge, grey * edge * 1.03, 0.15 + 0.85 * c.tone * (0.7 + 0.3 * f.tone)];
  }
  for (let k = 0; k < 4; k++) img[(y * PX + x) * 4 + k] = Math.round(Math.max(0, Math.min(1, out[k])) * 255);
}
writePng("tarmac.png");

function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]), crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body) >>> 0);
  return Buffer.concat([len, body, crc]);
}
function writePng(name) {
  const raw = Buffer.alloc(PX * (PX * 4 + 1));
  for (let y = 0; y < PX; y++) img.copy(raw, y * (PX * 4 + 1) + 1, y * PX * 4, (y + 1) * PX * 4);
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(PX, 0); ihdr.writeUInt32BE(PX, 4); ihdr[8] = 8; ihdr[9] = 6;
  fs.writeFileSync(__dirname + "/../textures/" + name, Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0)),
  ]));
}
