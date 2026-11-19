// Bakes textures/gravel-forest.png, the stones of the level view's gravel road: one seamless tile that both the game
// (level_ground.gdshader) and the lab (level_editor_lab.html) lay over the road. Run: node tools/bake_gravel.js
// RGB is a stone's colour; alpha is its rank, and the shaders show a stone only where the road's looseness exceeds it,
// so the ruts keep a few stones and the crown gets them all. Gaps between stones have rank 1 and show the shader's dust.
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
const img = Buffer.alloc(PX * PX * 4);
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

function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]), crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body) >>> 0);
  return Buffer.concat([len, body, crc]);
}
const raw = Buffer.alloc(PX * (PX * 4 + 1));
for (let y = 0; y < PX; y++) img.copy(raw, y * (PX * 4 + 1) + 1, y * PX * 4, (y + 1) * PX * 4);
const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(PX, 0); ihdr.writeUInt32BE(PX, 4); ihdr[8] = 8; ihdr[9] = 6;
fs.writeFileSync(__dirname + "/../textures/gravel-forest.png", Buffer.concat([
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0)),
]));
