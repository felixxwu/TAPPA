// Procedural low-poly spectators: abstract faceless peg figures built from a handful of primitives,
// modelled once at 1.75 m and scaled per person, with random clothes, hats, body shape and pose.
const Spectators = (() => {
const V = (x = 0, y = 0, z = 0) => new THREE.Vector3(x, y, z);

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];

const SKIN = ["#f3d2b8", "#e8b896", "#d29a72", "#b07650", "#87573a", "#5c3a26"];
const HAIR = ["#1c1714", "#3b2a1e", "#6b4a2e", "#c9a35e", "#a3502a", "#9a9a9a", "#d8d4cc"];
const JACKET = ["#24345a", "#a8262c", "#2f5a3a", "#d9b42a", "#1e1e22", "#6c7078", "#2d7f86", "#5b3a78", "#8a7a52", "#c8c4bc", "#3f6fb0", "#7a2f2f"];
const TROUSERS = ["#3a4f73", "#29405e", "#1f2024", "#7a6e55", "#4d5156", "#38452f"];
const ACCENT = ["#e8e2d0", "#c22", "#f0c419", "#1a8a4a", "#2a62c8", "#111"];
const MARSHAL = "#ee6a12", STRIPE = "#e6e8ea";
const POSES = {
  // Upper-arm and forearm directions for the right arm; the left arm mirrors x. "r"/"l" override one side.
  stand:    { upper: [0.12, -1, 0], fore: [0.05, -1, 0.12] },
  pockets:  { upper: [0.25, -1, -0.15], fore: [-0.45, -0.55, 0.55] },
  folded:   { upper: [0.08, -1, 0.2], fore: [-1, 0.25, 0.35] },
  wave:     { upper: [0.12, -1, 0], fore: [0.05, -1, 0.12], r: { upper: [0.7, 0.5, 0], fore: [0.15, 1, 0.1] } },
  cheer:    { upper: [0.45, 0.9, 0.1], fore: [0.1, 1, 0] },
  camera:   { upper: [0.03, -0.17, 0.18], fore: [-0.15, 0.32, 0.1] },
  umbrella: { upper: [0.12, -1, 0], fore: [0.05, -1, 0.12], r: { upper: [0.1, -0.8, 0.5], fore: [-0.2, 0.7, 0.6] } },
};

// Appends primitives into one shared position/colour buffer, each placed by `root` (the person's transform).
class Builder {
  constructor() { this.pos = []; this.col = []; this.tris = 0; }
  add(geo, color, matrix) {
    const g = geo.index ? geo.toNonIndexed() : geo;
    g.applyMatrix4(matrix);
    const c = new THREE.Color(color).convertSRGBToLinear(), p = g.attributes.position.array;
    for (let i = 0; i < p.length; i += 3) { this.pos.push(p[i], p[i + 1], p[i + 2]); this.col.push(c.r, c.g, c.b); }
    this.tris += p.length / 9;
    geo.dispose(); g.dispose();
  }
  geometry() {
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(this.pos, 3));
    g.setAttribute("color", new THREE.Float32BufferAttribute(this.col, 3));
    g.computeVertexNormals();
    return g;
  }
}

function spectator(out, root, seed, opts) {
  const r = rng(seed), m = new THREE.Matrix4();
  const at = (x, y, z, rx = 0, sx = 1, sy = 1, sz = 1) =>
    root.clone().multiply(m.compose(V(x, y, z), new THREE.Quaternion().setFromEuler(new THREE.Euler(rx, 0, 0)), V(sx, sy, sz)));
  const limb = (a, b, r0, r1, color, sides = 6) => {
    const len = a.distanceTo(b) + 0.02, dir = b.clone().sub(a).normalize();
    const q = new THREE.Quaternion().setFromUnitVectors(V(0, 1, 0), dir);
    out.add(new THREE.CylinderGeometry(r1, r0, len, sides, 1, true), color,
      root.clone().multiply(m.compose(a.clone().add(b).multiplyScalar(0.5), q, V(1, 1, 1))));
  };

  const marshal = opts.marshals && r() < 0.08;
  const skin = pick(r, SKIN), hair = pick(r, HAIR), jacket = marshal ? MARSHAL : pick(r, JACKET);
  const trousers = pick(r, TROUSERS), accent = pick(r, ACCENT);
  const bw = 0.85 + r() * 0.35, belly = r() < 0.25 ? 1.15 + r() * 0.15 : 1;
  const coat = r() < 0.3, tshirt = !opts.rain && !coat && r() < 0.15;
  let pose = opts.pose === "random" ? pick(r, ["stand", "stand", "pockets", "pockets", "folded", "wave", "cheer", "camera", "camera"]) : opts.pose;
  if (opts.pose === "random" && opts.rain && r() < 0.35) pose = "umbrella";
  const hat = opts.rain && r() < 0.4 ? "hood" : pick(r, ["none", "none", "none", "beanie", "cap", "bucket", "beanie"]);

  const hipX = 0.085 * bw;
  if (opts.limbless) out.add(new THREE.CylinderGeometry(0.15 * bw * belly, 0.12 * bw, 0.84, 6), trousers, at(0, 0.42, 0, 0, 1, 1, 0.65));
  else for (const s of [-1, 1]) limb(V(s * hipX, 0.86, 0), V(s * (hipX + 0.01), 0, 0), 0.075 * bw, 0.05 * bw, trousers, 4);

  const torsoBottom = coat ? 0.62 : 0.8, torsoTop = 1.42, bottomR = (coat ? 0.19 : 0.15) * bw * belly;
  out.add(new THREE.CylinderGeometry(0.2 * bw, bottomR, torsoTop - torsoBottom, 6), jacket,
    at(0, (torsoTop + torsoBottom) / 2, 0, 0, 1, 1, 0.65));
  if (marshal) out.add(new THREE.CylinderGeometry(0.192 * bw, 0.18 * bw * belly, 0.07, 6), STRIPE, at(0, 1.08, 0, 0, 1.03, 1, 0.68));
  if (r() < 0.25) out.add(new THREE.BoxGeometry(0.26 * bw, 0.32, 0.14), pick(r, [accent, pick(r, JACKET)]), at(0, 1.13, -0.13 * bw * belly - 0.06));
  const camera = (y, z) => {
    out.add(new THREE.BoxGeometry(0.14, 0.09, 0.07), "#1a1a1a", at(0, y, z));
    out.add(new THREE.CylinderGeometry(0.03, 0.03, 0.06, 6), "#3a3a3e", at(0, y, z + 0.06, Math.PI / 2));
  };
  if (opts.limbless && pose === "camera") camera(1.53, 0.26);

  const p = POSES[pose];
  if (opts.limbless && pose === "umbrella") {
    limb(V(0.12, 1.1, 0.14), V(0.12, 2.05, 0.14), 0.012, 0.012, "#222", 3);
    out.add(new THREE.ConeGeometry(0.55, 0.22, 6, 1, true), accent, at(0.12, 2.01, 0.14));
  }
  for (const s of opts.limbless ? [] : [-1, 1]) {
    const side = (s > 0 && p.r) || p, mirror = d => V(d[0] * s, d[1], d[2]).normalize();
    const shoulder = V(s * 0.2 * bw, 1.36, 0);
    const elbow = shoulder.clone().addScaledVector(mirror(side.upper), 0.28);
    const hand = elbow.clone().addScaledVector(mirror(side.fore), 0.3);
    limb(shoulder, elbow, 0.06 * bw, 0.05 * bw, jacket, 4);
    limb(elbow, hand, 0.05 * bw, 0.035 * bw, tshirt ? skin : jacket, 4);
    if (pose === "umbrella" && s > 0) {
      limb(hand, V(hand.x, 2.05, hand.z), 0.012, 0.012, "#222", 3);
      out.add(new THREE.ConeGeometry(0.55, 0.22, 6, 1, true), accent, at(hand.x, 2.01, hand.z));
    }
    if (pose === "camera" && s > 0) camera(hand.y, hand.z + 0.02);
  }

  // Hats and hair are low-poly domes around the gem-shaped head; sized well past it so no head corner pokes through their flat faces.
  const headY = 1.56, headR = 0.14;
  out.add(new THREE.IcosahedronGeometry(headR, 0), skin, at(0, headY, 0));

  const bald = r() < 0.15, hatColor = pick(r, [accent, jacket, pick(r, JACKET)]);
  const dome = (scale, color, tilt = 0, cover = 0.5) =>
    out.add(new THREE.SphereGeometry(headR * scale, 6, 3, 0, Math.PI * 2, 0, Math.PI * cover), color, at(0, headY, 0, tilt));
  if (hat === "none" && !bald) dome(1.25, hair, -0.35, 0.55);
  if (hat === "beanie") {
    dome(1.3, hatColor);
    if (r() < 0.5) out.add(new THREE.IcosahedronGeometry(0.04, 0), accent, at(0, headY + headR * 1.3 + 0.02, 0));
  } else if (hat === "cap") {
    dome(1.28, hatColor);
    out.add(new THREE.BoxGeometry(0.2, 0.02, 0.14), hatColor, at(0, headY + 0.02, 0.19, 0.12));
  } else if (hat === "bucket") {
    out.add(new THREE.CylinderGeometry(0.12, 0.155, 0.13, 6), hatColor, at(0, 1.7, 0));
    out.add(new THREE.CylinderGeometry(0.24, 0.24, 0.015, 6), hatColor, at(0, 1.64, 0));
  } else if (hat === "hood") dome(1.4, jacket, -0.55, 0.62);
}

return { rng, pick, POSES, Builder, spectator };
})();

// Shared by tools/spectator_lab.html, the level editor lab and tools/bake_spectators.js (needs THREE as a global).
if (typeof module !== "undefined") module.exports = Spectators;

