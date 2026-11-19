// Bakes a level's `buildings` list into what the game draws: <level>.buildings.json (one triangle mesh per building)
// and tools/levels/buildings_atlas.png, by running tools/buildings.js under node with tiny stand-ins for three.js and canvas.
// Usage: node tools/bake_buildings.js tools/levels/hafren_5km.json
const fs = require("fs"), path = require("path"), vm = require("vm"), zlib = require("zlib");

class Vector3 {
  constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; }
  clone() { return new Vector3(this.x, this.y, this.z); }
  addScaledVector(v, s) { this.x += v.x * s; this.y += v.y * s; this.z += v.z * s; return this; }
  sub(v) { this.x -= v.x; this.y -= v.y; this.z -= v.z; return this; }
  negate() { this.x = -this.x; this.y = -this.y; this.z = -this.z; return this; }
  dot(v) { return this.x * v.x + this.y * v.y + this.z * v.z; }
  length() { return Math.hypot(this.x, this.y, this.z); }
  normalize() { const l = this.length() || 1; this.x /= l; this.y /= l; this.z /= l; return this; }
  crossVectors(a, b) { this.x = a.y * b.z - a.z * b.y; this.y = a.z * b.x - a.x * b.z; this.z = a.x * b.y - a.y * b.x; return this; }
}
class BufferGeometry { constructor() { this.attributes = {}; } setAttribute(k, a) { this.attributes[k] = a; } }
const THREE = { Vector3, BufferGeometry, Float32BufferAttribute: class { constructor(a) { this.array = a; } } };

// Just enough of a 2D canvas for paintAtlas: rect fills with alpha, vertical gradients, one polygon clip.
function canvas() {
  const c = { width: 0, height: 0 };
  let px, clipPoly = null, path = [];
  const parse = s => [1, 3, 5].map(i => parseInt(s.slice(i, i + 2), 16));
  const inClip = (x, y) => {
    if (!clipPoly) return true;
    let inside = false;
    for (let i = 0, j = clipPoly.length - 1; i < clipPoly.length; j = i++) {
      const [xi, yi] = clipPoly[i], [xj, yj] = clipPoly[j];
      if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
  };
  const g = {
    fillStyle: "#000", globalAlpha: 1,
    fillRect(x, y, w, h) {
      px ??= new Uint8ClampedArray(c.width * c.height * 4);
      for (let yy = Math.max(0, Math.round(y)); yy < Math.min(c.height, Math.round(y + h)); yy++)
        for (let xx = Math.max(0, Math.round(x)); xx < Math.min(c.width, Math.round(x + w)); xx++) {
          if (!inClip(xx + 0.5, yy + 0.5)) continue;
          const col = typeof this.fillStyle === "string" ? parse(this.fillStyle) : this.fillStyle.at(yy + 0.5), o = (yy * c.width + xx) * 4, a = this.globalAlpha;
          for (let k = 0; k < 3; k++) px[o + k] = px[o + k] * (1 - a) + col[k] * a;
          px[o + 3] = px[o + 3] * (1 - a) + 255 * a;
        }
    },
    clearRect(x, y, w, h) { px ??= new Uint8ClampedArray(c.width * c.height * 4); for (let yy = y; yy < y + h; yy++) px.fill(0, (yy * c.width + x) * 4, (yy * c.width + x + w) * 4); },
    createLinearGradient(x0, y0, x1, y1) {
      const stops = [];
      return { addColorStop(t, col) { stops.push([t, parse(col)]); }, at(y) {
        const t = Math.max(0, Math.min(1, (y - y0) / (y1 - y0)));
        for (let i = 1; i < stops.length; i++) if (t <= stops[i][0]) { const [ta, a] = stops[i - 1], [tb, b] = stops[i], f = (t - ta) / (tb - ta || 1); return a.map((v, k) => v + (b[k] - v) * f); }
        return stops[stops.length - 1][1];
      } };
    },
    save() {}, restore() { clipPoly = null; }, beginPath() { path = []; }, closePath() {},
    moveTo(x, y) { path.push([x, y]); }, lineTo(x, y) { path.push([x, y]); },
    arc(cx, cy, r, a0, a1) { for (let i = 0; i <= 16; i++) { const a = a0 + (a1 - a0 + (a1 < a0 ? 2 * Math.PI : 0)) * i / 16; path.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]); } },
    clip() { clipPoly = path; },
    getImageData() { return { data: px }; }, putImageData() {},
  };
  c.getContext = () => g; c.pixels = () => px;
  return c;
}
const document = { createElement: () => canvas() };

function png(w, h, rgba) {
  const crc = b => { let c = ~0; for (const x of b) { c ^= x; for (let k = 0; k < 8; k++) c = c >>> 1 ^ 0xEDB88320 & -(c & 1); } return ~c >>> 0; };
  const chunk = (t, d) => { const b = Buffer.alloc(12 + d.length); b.writeUInt32BE(d.length); b.write(t, 4); d.copy(b, 8); b.writeUInt32BE(crc(b.subarray(4, 8 + d.length)), 8 + d.length); return b; };
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) Buffer.from(rgba.buffer, y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1);
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w); ihdr.writeUInt32BE(h, 4); ihdr.set([8, 6, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

const ctx = vm.createContext({ THREE, document, Math });
vm.runInContext(fs.readFileSync(path.join(__dirname, "buildings.js"), "utf8") + "\nthis.Buildings = Buildings;", ctx);
const B = ctx.Buildings;

const atlas = B.paintAtlas();
fs.writeFileSync(path.join(__dirname, "levels/buildings_atlas.png"), png(atlas.width, atlas.height, atlas.pixels()));

const levelPath = process.argv[2], level = JSON.parse(fs.readFileSync(levelPath, "utf8"));
const r3 = a => Array.from(a, v => Math.round(v * 1000) / 1000);
const out = (level.buildings ?? []).map(b => {
  const g = B.build(b.type, b.seed, b), at = g.attributes;
  return { x: b.x, z: b.z, rot: b.rot, L: b.L, W: b.W, h: b.h ?? 0, p: r3(at.position.array), n: r3(at.normal.array), uv: r3(at.uv.array), c: r3(at.color.array) };
});
fs.writeFileSync(levelPath.replace(/\.json$/, ".buildings.json"), JSON.stringify(out));
console.log(`${out.length} buildings, ${out.reduce((s, b) => s + b.p.length / 9, 0)} triangles`);
