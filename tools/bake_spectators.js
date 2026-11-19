// Bakes 10 limbless spectators from tools/spectators.js into models/spectators/spectators.glb (one node + mesh each, real metres).
// Usage: node tools/bake_spectators.js
const fs = require("fs"), os = require("os"), path = require("path"), vm = require("vm");

const PEOPLE = [[1, 1.75], [2, 1.62], [3, 1.88], [4, 1.35], [5, 1.95], [6, 1.7], [7, 1.55], [8, 1.82], [9, 1.45], [10, 1.68]].map(([seed, height]) => ({ seed, height }));
const OPTS = { limbless: true, pose: "random", rain: false, marshals: true };
const THREE_URL = "https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js";

async function loadThree() {
  const cache = path.join(os.tmpdir(), "three-r128.min.js");
  if (!fs.existsSync(cache)) fs.writeFileSync(cache, Buffer.from(await (await fetch(THREE_URL)).arrayBuffer()));
  return fs.readFileSync(cache, "utf8");
}

function glb(people) {
  const bin = [], views = [], accessors = [], meshes = [], nodes = [];
  const push = (arr, count, type, target, extra = {}) => {
    const buf = Buffer.from(new Float32Array(arr).buffer);
    views.push({ buffer: 0, byteOffset: bin.reduce((n, b) => n + b.length, 0), byteLength: buf.length, target });
    bin.push(buf);
    accessors.push({ bufferView: views.length - 1, componentType: 5126, count, type, ...extra });
    return accessors.length - 1;
  };
  people.forEach((p, i) => {
    const n = p.pos.length / 3, mn = [1e9, 1e9, 1e9], mx = [-1e9, -1e9, -1e9], normals = [];
    for (let v = 0; v < p.pos.length; v += 3) for (let k = 0; k < 3; k++) { mn[k] = Math.min(mn[k], p.pos[v + k]); mx[k] = Math.max(mx[k], p.pos[v + k]); }
    for (let v = 0; v < p.pos.length; v += 9) {
      const a = p.pos.slice(v, v + 9), e1 = [a[3] - a[0], a[4] - a[1], a[5] - a[2]], e2 = [a[6] - a[0], a[7] - a[1], a[8] - a[2]];
      const c = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]], l = Math.hypot(...c) || 1;
      for (let k = 0; k < 3; k++) normals.push(c[0] / l, c[1] / l, c[2] / l);
    }
    const pa = push(p.pos, n, "VEC3", 34962, { min: mn, max: mx }), na = push(normals, n, "VEC3", 34962), ca = push(p.col, n, "VEC3", 34962);
    meshes.push({ name: `Spectator${i}`, primitives: [{ attributes: { POSITION: pa, NORMAL: na, COLOR_0: ca }, material: 0, mode: 4 }] });
    nodes.push({ name: `Spectator${i}`, mesh: i });
  });
  const total = bin.reduce((n, b) => n + b.length, 0);
  const json = {
    asset: { version: "2.0", generator: "tools/bake_spectators.js" },
    scene: 0, scenes: [{ nodes: nodes.map((_, i) => i) }], nodes, meshes,
    materials: [{ name: "Spectator", doubleSided: true, pbrMetallicRoughness: { baseColorFactor: [1, 1, 1, 1], metallicFactor: 0, roughnessFactor: 1 } }],
    accessors, bufferViews: views, buffers: [{ byteLength: total }],
  };
  let js = Buffer.from(JSON.stringify(json)); js = Buffer.concat([js, Buffer.alloc((4 - js.length % 4) % 4, 0x20)]);
  const bb = Buffer.concat(bin), head = Buffer.alloc(12), ch = Buffer.alloc(8), ch2 = Buffer.alloc(8);
  head.write("glTF"); head.writeUInt32LE(2, 4); head.writeUInt32LE(12 + 8 + js.length + 8 + bb.length, 8);
  ch.writeUInt32LE(js.length, 0); ch.write("JSON", 4); ch2.writeUInt32LE(bb.length, 0); ch2.write("BIN\0", 4);
  return Buffer.concat([head, ch, js, ch2, bb]);
}

(async () => {
  const ctx = { console }; vm.createContext(ctx);
  vm.runInContext(await loadThree(), ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, "spectators.js"), "utf8") + "\nthis.Spectators = Spectators;", ctx);
  const { Builder, spectator } = ctx.Spectators, THREE = ctx.THREE;
  const scan = process.env.SCAN;
  const list = scan ? Array.from({ length: +scan }, (_, i) => ({ seed: i + 1, height: 1.75 })) : PEOPLE;
  const people = list.map(({ seed, height }) => {
    const out = new Builder();
    spectator(out, new THREE.Matrix4().makeScale(height / 1.75, height / 1.75, height / 1.75), seed, OPTS);
    if (scan) console.log(seed, out.tris);
    return { pos: out.pos, col: out.col, tris: out.tris, seed, height };
  });
  if (scan) return;
  const outPath = path.join(__dirname, "..", "models", "spectators", "spectators.glb");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, glb(people));
  people.forEach((p, i) => console.log(`Spectator${i} seed ${p.seed} ${p.height} m ${p.tris} tris`));
})();
