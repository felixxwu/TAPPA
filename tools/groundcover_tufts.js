// Opaque ground-cover tufts and bushes (plain vertex-coloured triangles, no texture or alpha) shared by the ground cover lab and the level editor lab.
const DEG = Math.PI / 180;
// Every preset is applied over these, so switching from a bush preset to a grass one doesn't keep bush-only settings.
const PRESET_BASE = { shape: "blades", flowers: 0, flowerColour: "#f2d01c", bushRadius: 0.5, bushHeight: 0.45, leaves: 150, leafSize: 0.09, fuzz: 0.35, core: 1 };

const PRESETS = {
  "Hafren verge grass": { blades: 7, radius: 0.1, height: 0.6, heightJitter: 0.4, width: 0.1, segments: 1, lean: 20, leanJitter: 15, bend: 0, colourVar: 0.15, flowers: 0.3, base: "#749a4c", tip: "#97ba60", ground: "#658645" },
  "Hafren molinia (straw tussock)": { blades: 9, radius: 0.2, height: 1.1, heightJitter: 0.3, width: 0.09, segments: 2, lean: 40, leanJitter: 18, bend: 70, colourVar: 0.14, base: "#9c9862", tip: "#c9b68a", ground: "#5c6a32" },
  "Hafren soft rush": { blades: 8, radius: 0.1, height: 1.3, heightJitter: 0.25, width: 0.05, segments: 1, lean: 12, leanJitter: 8, bend: 0, colourVar: 0.1, base: "#577540", tip: "#6f9050", ground: "#5c7b40" },
  "Hafren dead bracken": { blades: 5, radius: 0.3, height: 1.0, heightJitter: 0.35, width: 0.16, segments: 2, lean: 50, leanJitter: 25, bend: 70, colourVar: 0.15, base: "#7a6044", tip: "#9a7a58", ground: "#5a5a32" },
  "Hafren bilberry mound": { shape: "bush", bushRadius: 0.8, bushHeight: 0.8, leaves: 45, leafSize: 0.25, fuzz: 0.45, core: 1, colourVar: 0.15, base: "#6b8648", tip: "#8aa65c", ground: "#658645" },
  "Hafren heather": { shape: "bush", bushRadius: 0.7, bushHeight: 0.6, leaves: 40, leafSize: 0.22, fuzz: 0.6, core: 1, colourVar: 0.2, base: "#54433b", tip: "#6e5a50", ground: "#4e5a2c" },
  "Hafren scrub mound": { shape: "bush", bushRadius: 1.4, bushHeight: 1.2, leaves: 70, leafSize: 0.35, fuzz: 0.5, core: 1, colourVar: 0.15, base: "#617a41", tip: "#7f9d54", ground: "#658645" },
  "Short grass": { blades: 10, radius: 0.06, height: 0.22, heightJitter: 0.4, width: 0.03, segments: 2, lean: 25, leanJitter: 12, bend: 25, colourVar: 0.12, base: "#3e5c24", tip: "#8fb447", ground: "#4a5a2c" },
  "Meadow grass": { blades: 18, radius: 0.1, height: 0.6, heightJitter: 0.5, width: 0.025, segments: 3, lean: 20, leanJitter: 15, bend: 45, colourVar: 0.15, base: "#4a5e26", tip: "#b8c060", ground: "#4f5a2e" },
  "Bracken-ish": { blades: 8, radius: 0.05, height: 0.9, heightJitter: 0.3, width: 0.18, segments: 4, lean: 35, leanJitter: 15, bend: 70, colourVar: 0.12, base: "#3d5a1e", tip: "#7a9a30", ground: "#4a4a2a" },
  "Bare minimum (1 tri blades)": { blades: 5, radius: 0.05, height: 0.3, heightJitter: 0.4, width: 0.06, segments: 1, lean: 20, leanJitter: 10, bend: 0, colourVar: 0.15, base: "#3e5c24", tip: "#8fb447", ground: "#4a5a2c" },
};

function mulberry32(a) { return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
const V = (x = 0, y = 0, z = 0) => new THREE.Vector3(x, y, z);
const UP = V(0, 1, 0);

function buildTuft(seed, upNormals, s) {
  const rnd = mulberry32(seed);
  const g = { pos: [], col: [], nrm: [], idx: [], tips: [], rnd, s, upNormals };
  (s.shape === "bush" ? addBush : addBlades)(g);
  addFlowers(g);
  const geo = new THREE.BufferGeometry();
  geo.setAttribute("position", new THREE.Float32BufferAttribute(g.pos, 3));
  geo.setAttribute("color", new THREE.Float32BufferAttribute(g.col, 3));
  geo.setAttribute("normal", new THREE.Float32BufferAttribute(g.nrm, 3));
  geo.setIndex(g.idx);
  return geo;
}
function vert(g, p, c, n) { g.pos.push(p.x, p.y, p.z); g.col.push(c.r, c.g, c.b); g.nrm.push(n.x, n.y, n.z); return g.pos.length / 3 - 1; }

// Each blade is a strip of quads up a bending centre line, closed by a single tip triangle: 2*segments-1 triangles.
function addBlades(g) {
  const { rnd, s } = g, base = new THREE.Color(s.base), tip = new THREE.Color(s.tip), n = s.segments;
  for (let b = 0; b < s.blades; b++) {
    const a = rnd() * Math.PI * 2, r = s.radius * Math.sqrt(rnd());
    const yaw = a + (rnd() - 0.5) * 0.8;
    const dir = V(Math.cos(yaw), 0, Math.sin(yaw)), side = V(-Math.sin(yaw), 0, Math.cos(yaw));
    const h = s.height * (1 - s.heightJitter * rnd());
    const lean = (s.lean + (rnd() * 2 - 1) * s.leanJitter) * DEG;
    const shade = 1 + (rnd() * 2 - 1) * s.colourVar;
    const p = V(Math.cos(a) * r, 0, Math.sin(a) * r);
    const first = g.pos.length / 3;
    for (let i = 0; i <= n; i++) {
      const t = i / n, ang = lean + s.bend * DEG * t, w = s.width * (1 - t) / 2;
      const c = base.clone().lerp(tip, t).multiplyScalar(shade);
      const nm = g.upNormals ? UP : dir.clone().multiplyScalar(-Math.cos(ang)).addScaledVector(UP, Math.sin(ang));
      if (i < n) { vert(g, p.clone().addScaledVector(side, -w), c, nm); vert(g, p.clone().addScaledVector(side, w), c, nm); }
      else { vert(g, p, c, nm); g.tips.push(p.clone()); }
      if (i < n) {
        const mid = lean + s.bend * DEG * (i + 0.5) / n;
        p.addScaledVector(dir, Math.sin(mid) * h / n).addScaledVector(UP, Math.cos(mid) * h / n);
      }
    }
    for (let i = 0; i < n - 1; i++) { const q = first + 2 * i; g.idx.push(q, q + 2, q + 1, q + 1, q + 2, q + 3); }
    const q = first + 2 * (n - 1); g.idx.push(q, first + 2 * n, q + 1);
  }
}

// A bush is a low-poly dome (so you never see through it) wearing a coat of single-triangle leaves on its surface.
function addBush(g) {
  const { rnd, s } = g, base = new THREE.Color(s.base), tip = new THREE.Color(s.tip);
  const R = s.bushRadius, H = s.bushHeight;
  const outward = d => g.upNormals ? d.clone().add(UP).normalize() : d;
  if (s.core) {
    const dome = new THREE.SphereGeometry(1, 8, 4, 0, Math.PI * 2, 0, Math.PI / 2), dp = dome.attributes.position, first = g.pos.length / 3;
    const inner = base.clone().multiplyScalar(0.7);
    for (let i = 0; i < dp.count; i++) { const d = V(dp.getX(i), dp.getY(i), dp.getZ(i)); vert(g, V(d.x * R * 0.85, d.y * H * 0.9, d.z * R * 0.85), inner, outward(d)); }
    for (const i of dome.index.array) g.idx.push(first + i);
  }
  for (let k = 0; k < s.leaves; k++) {
    const y = rnd() * 1.1 - 0.1, th = rnd() * Math.PI * 2, rr = Math.sqrt(Math.max(0, 1 - y * y));
    const d = V(rr * Math.cos(th), y, rr * Math.sin(th));
    const out = 1 + (rnd() - 0.4) * s.fuzz * 0.5;
    const c0 = V(d.x * R * out, Math.max(d.y, 0) * H * out, d.z * R * out);
    const t1 = V().crossVectors(Math.abs(d.y) > 0.9 ? V(1, 0, 0) : UP, d).normalize(), t2 = V().crossVectors(d, t1);
    const col = base.clone().lerp(tip, Math.max(0, y) * 0.8 + rnd() * 0.2).multiplyScalar(1 + (rnd() * 2 - 1) * s.colourVar);
    const a0 = rnd() * Math.PI * 2, sz = s.leafSize * (0.6 + 0.4 * rnd()) / 1.7, n = outward(d), ids = [];
    for (let j = 0; j < 3; j++) {
      const a = a0 + j * 2.0944, p = c0.clone().addScaledVector(t1, Math.cos(a) * sz).addScaledVector(t2, Math.sin(a) * sz);
      if (j === 0) p.addScaledVector(d, s.fuzz * sz * 1.5);
      ids.push(vert(g, p, col, n));
    }
    g.idx.push(...ids);
    g.tips.push(c0);
  }
}

// Flowers are one small flat triangle perched on a random blade tip or leaf.
function addFlowers(g) {
  const { rnd, s } = g, c = new THREE.Color(s.flowerColour), count = Math.floor(s.flowers + rnd());
  for (let k = 0; k < count && g.tips.length; k++) {
    const p = g.tips[Math.floor(rnd() * g.tips.length)], a0 = rnd() * Math.PI * 2, ids = [];
    for (let j = 0; j < 3; j++) { const a = a0 + j * 2.0944; ids.push(vert(g, V(p.x + Math.cos(a) * 0.02, p.y + 0.01, p.z + Math.sin(a) * 0.02), c, UP)); }
    g.idx.push(...ids);
  }
}

// Wind and the distance shrink run in the vertex shader, which is where the game would do them too.
const U = { uTime: { value: 0 }, uWind: { value: 0 }, uFade: { value: new THREE.Vector2(20, 30) }, uCenter: { value: V() } };
function tuftMaterial(wire, h) {
  const m = new THREE.MeshLambertMaterial({ vertexColors: true, side: THREE.DoubleSide, wireframe: wire });
  m.onBeforeCompile = sh => {
    Object.assign(sh.uniforms, U, { uH: { value: Math.max(h, 0.05) } });
    sh.vertexShader = "uniform float uTime, uWind, uH; uniform vec2 uFade; uniform vec3 uCenter;\n" + sh.vertexShader.replace("#include <begin_vertex>", `#include <begin_vertex>
      vec3 root = (modelMatrix * instanceMatrix * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
      float cut = mix(uFade.x, uFade.y, fract(sin(dot(root.xz, vec2(12.9898, 78.233))) * 43758.5453));
      transformed *= step(distance(root.xz, uCenter.xz), cut);
      float sway = sin(uTime * 1.7 + root.x * 0.35 + root.z * 0.21) + 0.4 * sin(uTime * 3.1 + root.z * 0.9);
      transformed.xz += vec2(0.8, 0.5) * sway * uWind * 0.4 * transformed.y * transformed.y / uH;`);
    // three.js lights the back of a two-sided triangle as if its normal pointed the other way (down, for up-normals),
    // which turned every blade seen from behind near-black; light both sides the same instead
    sh.fragmentShader = sh.fragmentShader.replace(/\( gl_FrontFacing \)/g, "( true )");
  };
  return m;
}
