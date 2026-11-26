// Procedural Welsh-valley buildings as single low-poly meshes textured from one painted atlas (one draw call each).
// Shared by tools/building_lab.html and tools/level_editor_lab.html; needs three.js loaded first.
const Buildings = (() => {
const V = (x = 0, y = 0, z = 0) => new THREE.Vector3(x, y, z);
const X = V(1, 0, 0), Y = V(0, 1, 0), Z = V(0, 0, 1);

// The atlas is a stack of horizontal strips, each 16 m wide (wraps in U so walls tile along their length)
// and 8 m tall (V never wraps, so nothing taller than 8 m may use one face).
const PPM = 32, STRIP_M = 8, ATLAS_W = 512;
const STRIPS = ["stone", "render", "clad", "darkwood", "slate", "rust", "bluetin", "detail", "chain"];
const STRIP_PX = STRIP_M * PPM, ATLAS_H = STRIPS.length * STRIP_PX;
// Cut-out pieces in the "detail" strip, in pixels; sizes are metres x PPM.
const DETAIL = {
  door: [0, 0, 32, 64], doorRed: [36, 0, 32, 64], sash: [72, 0, 32, 38], small: [108, 0, 26, 32],
  arch: [138, 0, 32, 51], roller: [174, 0, 83, 77], solar: [262, 0, 77, 38], pot: [344, 0, 8, 12], white: [356, 0, 8, 8],
};

function rng(seed) { let a = seed >>> 0; return () => { a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }

// --- atlas painting ----------------------------------------------------------------------
function paintAtlas() {
  const c = document.createElement("canvas"); c.width = ATLAS_W; c.height = ATLAS_H;
  const g = c.getContext("2d"), r = rng(7);
  const rnd = (a, b) => a + (b - a) * r();
  // Draws a rect twice when it crosses the right edge so the strip tiles horizontally.
  const rect = (x, y, w, h, col) => { g.fillStyle = col; g.fillRect(x, y, w, h); if (x + w > ATLAS_W) g.fillRect(x - ATLAS_W, y, w, h); };
  const top = s => STRIPS.indexOf(s) * STRIP_PX;

  let y0 = top("stone");
  rect(0, y0, ATLAS_W, STRIP_PX, "#6f685e");
  const stones = ["#8a8072", "#7a7468", "#9a8a70", "#6a645c", "#a09482", "#857560", "#5e5a55"];
  for (let y = 0; y < STRIP_PX;) {
    const h = Math.round(rnd(5, 11));
    for (let x = rnd(0, 10); x < ATLAS_W;) {
      const w = Math.round(rnd(7, 20)), col = stones[Math.floor(r() * stones.length)], k = rnd(0.85, 1.15);
      rect(x + 1, y0 + y + 1, w - 1, h - 1, shadeHex(col, k));
      rect(x + 1, y0 + y + 1, w - 1, 1, shadeHex(col, k * 1.2));
      rect(x + 1, y0 + y + h - 1, w - 1, 1, shadeHex(col, k * 0.7));
      x += w;
    }
    y += h;
  }

  y0 = top("render");
  rect(0, y0, ATLAS_W, STRIP_PX, "#d6cf9e");
  for (let i = 0; i < 400; i++) { g.globalAlpha = 0.08; rect(rnd(0, ATLAS_W), y0 + rnd(0, STRIP_PX), rnd(4, 30), rnd(3, 20), r() < 0.5 ? "#a8a070" : "#efe9c0"); }
  for (let i = 0; i < 60; i++) { g.globalAlpha = 0.12; rect(rnd(0, ATLAS_W), y0 + STRIP_PX - rnd(30, 120), rnd(2, 6), rnd(20, 100), "#7f7a58"); }
  g.globalAlpha = 1;
  rect(0, y0 + STRIP_PX - 10, ATLAS_W, 10, "#77736a");

  const boards = (s, base, h, vertical) => {
    y0 = top(s);
    for (let i = 0; i * h < (vertical ? ATLAS_W : STRIP_PX); i++) {
      const col = shadeHex(base, rnd(0.85, 1.12));
      if (vertical) { rect(i * h, y0, h, STRIP_PX, col); rect(i * h + h - 1, y0, 1, STRIP_PX, shadeHex(base, 0.5)); }
      else { rect(0, y0 + i * h, ATLAS_W, h, col); rect(0, y0 + i * h + h - 1, ATLAS_W, 1, shadeHex(base, 0.45)); rect(0, y0 + i * h, ATLAS_W, 1, shadeHex(base, 1.25)); }
    }
    for (let i = 0; i < 300; i++) { g.globalAlpha = 0.15; rect(rnd(0, ATLAS_W), y0 + rnd(0, STRIP_PX), vertical ? 1 : rnd(6, 30), vertical ? rnd(6, 30) : 1, shadeHex(base, 0.6)); }
    g.globalAlpha = 1;
  };
  boards("clad", "#6e5338", 7, false);
  boards("darkwood", "#4a3326", 7, false);

  y0 = top("slate");
  rect(0, y0, ATLAS_W, STRIP_PX, "#2c2e33");
  for (let row = 0; row * 8 < STRIP_PX; row++) {
    for (let x = (row % 2) * 5; x < ATLAS_W; x += 10) {
      const k = rnd(0.8, 1.2);
      rect(x, y0 + row * 8, 9, 7, shadeHex("#5a5c64", k));
      rect(x, y0 + row * 8 + 6, 9, 1, shadeHex("#5a5c64", k * 0.6));
      if (r() < 0.04) rect(x + rnd(1, 6), y0 + row * 8 + rnd(1, 5), 2, 2, "#8c9468");
    }
  }

  const tin = (s, base, rustiness) => {
    y0 = top(s);
    for (let x = 0; x < ATLAS_W; x++) rect(x, y0, 1, STRIP_PX, shadeHex(base, 0.8 + 0.3 * Math.sin(x / 4 * Math.PI * 2)));
    for (let i = 0; i < 120 * rustiness; i++) { g.globalAlpha = rnd(0.1, 0.35); rect(rnd(0, ATLAS_W), y0 + rnd(0, STRIP_PX), rnd(3, 25), rnd(10, 80), r() < 0.5 ? "#5a2a1c" : "#9a5a30"); }
    g.globalAlpha = 1;
  };
  tin("rust", "#8a3b2a", 3);
  tin("bluetin", "#33475a", 0.6);

  y0 = top("detail");
  g.clearRect(0, y0, ATLAS_W, STRIP_PX);
  const at = (k, f) => { const [x, y, w, h] = DETAIL[k]; f(x, y0 + y, w, h); };
  const plankDoor = (x, y, w, h, col) => {
    rect(x, y, w, h, shadeHex(col, 0.55));
    for (let i = 0; i < 6; i++) rect(x + 2 + i * 5, y + 2, 4, h - 2, shadeHex(col, rnd(0.9, 1.1)));
    rect(x + w - 7, y + h / 2, 2, 2, "#c8b060");
  };
  at("door", (x, y, w, h) => plankDoor(x, y, w, h, "#4a3a2c"));
  at("doorRed", (x, y, w, h) => plankDoor(x, y, w, h, "#b8332a"));
  const glass = (x, y, w, h) => { const gr = g.createLinearGradient(0, y, 0, y + h); gr.addColorStop(0, "#9fb4c4"); gr.addColorStop(0.5, "#3a4a58"); gr.addColorStop(1, "#1c242c"); g.fillStyle = gr; g.fillRect(x, y, w, h); };
  const sash = (x, y, w, h, frame) => {
    rect(x, y, w, h, frame); glass(x + 3, y + 3, w - 6, h - 9);
    rect(x + w / 2 - 1, y + 3, 2, h - 9, frame); rect(x + 3, y + (h - 6) / 2, w - 6, 2, frame);
    rect(x - 0, y + h - 5, w, 5, "#8c887e");
  };
  at("sash", (x, y, w, h) => sash(x, y, w, h, "#e8e6de"));
  at("small", (x, y, w, h) => sash(x, y, w, h, "#3a3530"));
  at("arch", (x, y, w, h) => {
    g.save(); g.beginPath(); g.moveTo(x, y + h); g.lineTo(x, y + w / 2); g.arc(x + w / 2, y + w / 2, w / 2, Math.PI, 0); g.lineTo(x + w, y + h); g.closePath(); g.clip();
    sash(x, y, w, h, "#ece9e0"); g.restore();
  });
  at("roller", (x, y, w, h) => {
    rect(x, y, w, h, "#3a2a20");
    for (let i = 0; i * 4 < h - 3; i++) rect(x + 3, y + 3 + i * 4, w - 6, 3, shadeHex("#7a6050", rnd(0.95, 1.05)));
  });
  at("solar", (x, y, w, h) => {
    rect(x, y, w, h, "#b0b4b8");
    for (let i = 0; i < 6; i++) for (let j = 0; j < 3; j++) rect(x + 2 + i * 12.3, y + 2 + j * 11.5, 11, 10.5, shadeHex("#2a3f78", rnd(0.9, 1.15)));
  });
  at("pot", (x, y, w, h) => rect(x, y, w, h, "#9a5a3a"));
  at("white", (x, y, w, h) => rect(x, y, w, h, "#ffffff"));

  // Chain-link mesh for shop fences: wires on a transparent strip, an 8 px diamond repeat so it tiles along and up.
  y0 = top("chain");
  g.clearRect(0, y0, ATLAS_W, STRIP_PX);
  for (let x = 0; x < ATLAS_W; x += 8) for (let y = 0; y < STRIP_PX; y += 8) for (let k = 0; k < 8; k++) { rect(x + k, y0 + y + k, 2, 1, "#ffffff"); rect(x + 7 - k, y0 + y + k, 2, 1, "#ffffff"); }

  // Fine per-pixel grain so flat colours don't read as plastic.
  const img = g.getImageData(0, 0, ATLAS_W, ATLAS_H), d = img.data;
  for (let i = 0; i < d.length; i += 4) { if (!d[i + 3]) continue; const n = (r() - 0.5) * 14; d[i] += n; d[i + 1] += n; d[i + 2] += n; }
  g.putImageData(img, 0, 0);
  return c;
}
function shadeHex(hex, k) { const n = parseInt(hex.slice(1), 16); const f = v => Math.max(0, Math.min(255, Math.round(v * k))).toString(16).padStart(2, "0"); return "#" + f(n >> 16) + f(n >> 8 & 255) + f(n & 255); }

// --- mesh building -----------------------------------------------------------------------
// Collects flat-shaded triangles into one geometry. Faces are UV-mapped by projecting onto their own (a, b) axes in metres.
class Mesh {
  constructor() { this.p = []; this.n = []; this.uv = []; }
  // pts: convex polygon, counter-clockwise seen from the front; a = surface "right", b = surface "up".
  poly(pts, a, b, strip) {
    const n = V().crossVectors(a, b).normalize(), s = STRIPS.indexOf(strip);
    const vs = pts.map(p => p.dot(b)), v0 = Math.min(...vs);
    const uvs = pts.map((p, i) => [p.dot(a) * PPM / ATLAS_W, 1 - (s * STRIP_M + STRIP_M - Math.min(STRIP_M, vs[i] - v0)) * PPM / ATLAS_H]);
    this._fan(pts, uvs, n);
  }
  quad(o, a, b, w, h, strip) { this.poly([o, o.clone().addScaledVector(a, w), o.clone().addScaledVector(a, w).addScaledVector(b, h), o.clone().addScaledVector(b, h)], a, b, strip); }
  // A cut-out from the detail strip (door, window...) laid 2 cm proud of a wall.
  decal(o, a, b, key, w, h) {
    const [x, y, pw, ph] = DETAIL[key], n = V().crossVectors(a, b).normalize(), t = STRIPS.indexOf("detail") * STRIP_PX;
    o = o.clone().addScaledVector(n, 0.02); w = w ?? pw / PPM; h = h ?? ph / PPM;
    const u = px => (px) / ATLAS_W, v = py => 1 - (t + py) / ATLAS_H;
    const pts = [o, o.clone().addScaledVector(a, w), o.clone().addScaledVector(a, w).addScaledVector(b, h), o.clone().addScaledVector(b, h)];
    this._fan(pts, [[u(x + .5), v(y + ph - .5)], [u(x + pw - .5), v(y + ph - .5)], [u(x + pw - .5), v(y + .5)], [u(x + .5), v(y + .5)]], n);
  }
  box(c, sx, sy, sz, strip, topStrip = strip) {
    const lo = V(c.x - sx / 2, c.y, c.z - sz / 2), hi = V(c.x + sx / 2, c.y + sy, c.z + sz / 2);
    this.quad(V(lo.x, lo.y, hi.z), X, Y, sx, sy, strip);
    this.quad(V(hi.x, lo.y, lo.z), X.clone().negate(), Y, sx, sy, strip);
    this.quad(V(hi.x, lo.y, hi.z), Z.clone().negate(), Y, sz, sy, strip);
    this.quad(V(lo.x, lo.y, lo.z), Z, Y, sz, sy, strip);
    this.quad(V(lo.x, hi.y, hi.z), X, Z.clone().negate(), sx, sz, topStrip);
  }
  _fan(pts, uvs, n) {
    for (let i = 1; i < pts.length - 1; i++) for (const k of [0, i, i + 1]) { this.p.push(pts[k].x, pts[k].y, pts[k].z); this.n.push(n.x, n.y, n.z); this.uv.push(...uvs[k]); }
  }
  geometry() {
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(this.p, 3));
    g.setAttribute("normal", new THREE.Float32BufferAttribute(this.n, 3));
    g.setAttribute("uv", new THREE.Float32BufferAttribute(this.uv, 2));
    // Baked sun shading for unlit materials (the level editor draws everything unshaded, like the game's level view).
    const sun = V(0.4, 0.8, 0.45).normalize(), c = [];
    for (let i = 0; i < this.n.length; i += 3) { const k = 0.65 + 0.35 * Math.max(0, this.n[i] * sun.x + this.n[i + 1] * sun.y + this.n[i + 2] * sun.z); c.push(k, k, k); }
    g.setAttribute("color", new THREE.Float32BufferAttribute(c, 3));
    return g;
  }
}

// A gabled box: ridge along X, footprint W x D centred on (ox, 0, 0), walls H high, ridge `rise` above the eaves.
function gabled(m, { ox = 0, W, D, H, rise, over = 0.3, wall, gable = wall, roof = "slate" }) {
  const hw = W / 2, hd = D / 2, nX = X.clone().negate(), nZ = Z.clone().negate();
  m.quad(V(ox - hw, 0, hd), X, Y, W, H, wall);
  m.quad(V(ox + hw, 0, -hd), nX, Y, W, H, wall);
  m.poly([V(ox + hw, 0, hd), V(ox + hw, 0, -hd), V(ox + hw, H, -hd), V(ox + hw, H + rise, 0), V(ox + hw, H, hd)], nZ, Y, gable);
  m.poly([V(ox - hw, 0, -hd), V(ox - hw, 0, hd), V(ox - hw, H, hd), V(ox - hw, H + rise, 0), V(ox - hw, H, -hd)], Z, Y, gable);
  const slope = Math.hypot(rise, hd), lift = 0.12;
  for (const side of [1, -1]) {
    const s = V(0, rise, -side * hd).normalize(), a = side > 0 ? X : nX;
    const eave = V(ox - side * (hw + over), H + lift, side * hd).addScaledVector(s, -over);
    m.quad(eave, a, s, W + 2 * over, slope + over, roof);
    m.quad(eave.clone().addScaledVector(Y, -0.18), a, Y, W + 2 * over, 0.18, "darkwood");
  }
}
function chimney(m, x, H, rise, z = 0, strip = "stone") {
  m.box(V(x, H, z), 0.7, rise + 1.0, 0.6, strip, "slate");
  m.box(V(x, H + rise + 1.0, z), 0.16, 0.35, 0.16, "rust");
}
// Puts a door/window centred at x on the front wall (z = +D/2).
function front(m, D, x, y, key, w, h) { m.decal(V(x - (w ?? DETAIL[key][2] / PPM) / 2, y, D / 2), X, Y, key, w, h); }

const TYPES = {
  "Stone cottage": (r, s) => {
    const m = new Mesh(), two = s.h ? s.h > 6 : r() < 0.4, W = s.L ?? 7 + r() * 4, D = s.W ?? 5 + r() * 1, H = two ? 4.8 : 2.8, rise = 2 + r() * 0.6;
    gabled(m, { W, D, H, rise, wall: "stone" });
    chimney(m, W / 2 - 0.4, H, rise); if (r() < 0.6) chimney(m, -W / 2 + 0.4, H, rise);
    front(m, D, 0, 0, "door");
    for (const sx of [-1, 1]) {
      front(m, D, sx * W / 4, 0.9, "small");
      if (two) front(m, D, sx * W / 4, 3.1, "small");
    }
    return m;
  },
  "Rendered cottage": (r, s) => {
    const m = new Mesh(), W = s.L ?? 7 + r() * 3, D = s.W ?? 5, H = 2.9, rise = 2.2;
    gabled(m, { W, D, H, rise, wall: "render", gable: r() < 0.5 ? "slate" : "render" });
    chimney(m, W / 2 - 0.4, H, rise, 0, "render");
    for (const sx of [-1, 1]) front(m, D, sx * W / 4, 0.8, "arch");
    m.decal(V(-W / 2 - 0.0, 0, 1.6), Z, Y, "door");
    return m;
  },
  "Stone terrace": (r, s) => {
    const m = new Mesh(), n = s.L ? Math.max(1, Math.round(s.L / 5.2)) : 2 + Math.floor(r() * 3), W = s.L ?? n * 5.2, unit = W / n, D = s.W ?? 5.5, H = 4.6, rise = 2;
    gabled(m, { W, D, H, rise, wall: "stone" });
    for (let i = 0; i <= n; i++) chimney(m, Math.min(W / 2 - 0.4, Math.max(-W / 2 + 0.4, -W / 2 + i * unit)), H, rise);
    for (let i = 0; i < n; i++) {
      const cx = -W / 2 + unit * (i + 0.5), flip = r() < 0.5 ? 1 : -1;
      front(m, D, cx + flip * 1.2, 0, "door");
      front(m, D, cx - flip * 1.0, 0.9, "small");
      front(m, D, cx - flip * 1.0, 3.0, "small"); front(m, D, cx + flip * 1.2, 3.0, "small");
    }
    return m;
  },
  "Timber hut": (r, s) => {
    const m = new Mesh(), W = s.L ?? 6 + r() * 3, D = s.W ?? 4 + r(), H = 2.5, rise = 1.4;
    gabled(m, { W, D, H, rise, over: 0.45, wall: "clad" });
    front(m, D, -W / 4, 0, "doorRed", 1, 2.1); front(m, D, W / 4, 0, "doorRed", 1, 2.1);
    const sl = V(0, rise, -D / 2).normalize(), n = V().crossVectors(X, sl);
    if (r() < 0.7) m.decal(V(-1.2, 2.5 + 0.14, D / 2).addScaledVector(sl, 0.6).addScaledVector(n, 0.02), X, sl, "solar");
    return m;
  },
  "Stone garage": (r, s) => {
    const m = new Mesh(), W = s.L ?? 6 + r() * 2, D = s.W ?? 4 + r(), H = 2.7, rise = 1.6;
    gabled(m, { W, D, H, rise, over: 0.35, wall: "stone", gable: "darkwood" });
    m.decal(V(W / 2, 0, Math.min(1.3, D / 2 - 0.1)), Z.clone().negate(), Y, "roller");
    return m;
  },
  "Dutch barn": (r, s) => {
    const m = new Mesh(), W = s.L ?? 14 + r() * 10, D = s.W ?? 9 + r() * 3, H = 4.2, rise = Math.min(3.5, D * 0.25), over = 0.4, segs = 8;
    const hw = W / 2, hd = D / 2;
    m.quad(V(hw, 0, -hd), X.clone().negate(), Y, W, H, "bluetin");
    for (const sx of [1, -1]) {
      const a = sx > 0 ? Z.clone().negate() : Z, pts = [];
      for (let i = 0; i <= segs; i++) { const t = Math.PI * i / segs; pts.push(V(sx * hw, H + rise * Math.sin(t), sx * hd * Math.cos(t))); }
      m.quad(V(sx * hw, 0, sx * hd), a, Y, D, H, sx > 0 && r() < 0.5 ? "clad" : "bluetin");
      m.poly(sx > 0 ? pts : pts.reverse(), a, Y, "bluetin");
    }
    const arc = t => V(0, H + 0.08 + (rise + 0.1) * Math.sin(t), (hd + over) * Math.cos(t));
    for (let i = 0; i < segs; i++) {
      const p = arc(Math.PI * i / segs), q = arc(Math.PI * (i + 1) / segs), b = q.clone().sub(p);
      m.quad(V(-hw - 0.3, p.y, p.z), X, b.clone().normalize(), W + 0.6, b.length(), "rust");
    }
    const bays = Math.round(W / 4.5);
    for (let i = 0; i <= bays; i++) m.box(V(-hw + 0.1 + (W - 0.2) * i / bays, 0, hd - 0.1), 0.2, H, 0.2, "bluetin");
    return m;
  },
};

// Builds one building as a BufferGeometry, ridge along X, centred on the origin at ground level.
// size (optional): { L: length along the ridge, W: depth, h: eaves-ish height } in metres, e.g. from a map footprint.
const build = (type, seed, size = {}) => TYPES[type](rng(seed), size).geometry();
// UV of a point `um`, `vm` metres along a strip (V counts from the bottom of the strip), or of the centre of a detail cell.
const stripUV = (strip, um, vm) => [um * PPM / ATLAS_W, 1 - (STRIPS.indexOf(strip) * STRIP_PX + STRIP_PX - Math.min(STRIP_M, vm) * PPM) / ATLAS_H];
const detailUV = key => { const [x, y, w, h] = DETAIL[key]; return [(x + w / 2) / ATLAS_W, 1 - (STRIPS.indexOf("detail") * STRIP_PX + y + h / 2) / ATLAS_H]; };
return { TYPES, build, paintAtlas, stripUV, detailUV, ATLAS_W, ATLAS_H, PPM };
})();
