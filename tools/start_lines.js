// Procedural rally stage starts (arch, start control, gazebos, tape, sponsor adverts) from a seed, as flat-coloured three.js meshes.
// Shared by tools/start_lab.html and tools/bake_buildings.js; needs three.js loaded first. The road runs along z, cars leave towards -z.
const StartLines = (() => {
let NO_TEXT = false;
// The seeds the game bakes (road 7 m wide, 50 m zone); each rally end draws one of these.
const SEEDS = [5, 8, 12, 15, 21], WIDTH = 7, LEN = 50;
function rng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6D2B79F5) >>> 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
const pick = (R, a) => a[Math.floor(R() * a.length)];
const shade = (c, k) => "#" + new THREE.Color(c).multiplyScalar(k).getHexString();
const mats = {};
const M = c => mats[c] ??= new THREE.MeshLambertMaterial({ color: c });
const box = (g, w, h, d, x, y, z, c, ry = 0) => { const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), M(c)); m.position.set(x, y, z); m.rotation.y = ry; g.add(m); return m; };
const cyl = (g, r, h, x, y, z, c, seg = 8) => { const m = new THREE.Mesh(new THREE.CylinderGeometry(r, r, h, seg), M(c)); m.position.set(x, y, z); g.add(m); return m; };
const group = (g, x, z, ry) => { const t = new THREE.Group(); t.position.set(x, 0, z); t.rotation.y = ry; g.add(t); return t; };

function canvasTex(w, h, draw) {
  const c = document.createElement("canvas"); c.width = w; c.height = h; draw(c.getContext("2d"));
  const t = new THREE.CanvasTexture(c); t.encoding = THREE.sRGBEncoding; return t;
}
const textTex = (text, bg, fg, aspect) => NO_TEXT ? { flat: bg, text, fg } : canvasTex(Math.round(128 * aspect), 128, x => {
  const w = x.canvas.width; x.fillStyle = bg; x.fillRect(0, 0, w, 128);
  x.fillStyle = fg; x.font = "bold 72px sans-serif"; x.textAlign = "center"; x.textBaseline = "middle"; x.fillText(text, w / 2, 68, w - 24);
});
// The rally time-control board icon: a clock face on a coloured square.
const clockTex = (bg, bars) => NO_TEXT ? { flat: bg } : canvasTex(128, 128, x => {
  x.fillStyle = bg; x.fillRect(0, 0, 128, 128); x.strokeStyle = "#111"; x.lineWidth = 8; x.strokeRect(4, 4, 120, 120);
  x.beginPath(); x.arc(64, 64, 36, 0, Math.PI * 2); x.stroke(); x.beginPath(); x.moveTo(64, 64); x.lineTo(64, 38); x.moveTo(64, 64); x.lineTo(84, 70); x.stroke();
  if (bars) for (const d of [-14, 0, 14]) { x.beginPath(); x.moveTo(24 + d, 112); x.lineTo(104 + d, 16); x.stroke(); }
});
function plane(g, w, h, tex, x, y, z, ry = 0) {
  let m;
  if (tex.flat) {
    m = new THREE.Group(); m.add(new THREE.Mesh(new THREE.PlaneGeometry(w, h), M(tex.flat)));
    if (tex.text) { const t = new THREE.Object3D(); t.position.z = 0.003; t.userData.text = { text: tex.text, color: tex.fg, w: w * 0.9, h: h * 0.6 }; m.add(t); }
  } else m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: tex }));
  m.position.set(x, y, z); m.rotation.y = ry; g.add(m); return m;
}
// A sign readable from both faces: two planes back to back.
const sign2 = (g, w, h, tex, x, y, z, ry = 0) => { plane(g, w, h, tex, x, y, z + 0.01, ry); plane(g, w, h, tex, x, y, z - 0.01, ry + Math.PI); };

const SPONSORS = ["Severn Motors", "Clywedog Tyres", "Mid-Wales Fuels", "Dylife Quarry", "Cwm Coffee", "Gethin Autos", "Valley Radio", "Hafren Hire", "Draig Oils", "Kite Brakes", "Llyn Water", "Maesnant Tuning"];
const BRANDS = [["#c8302a", "#fff", "#f0c419"], ["#0f2a5a", "#fff", "#e83a2a"], ["#f0c419", "#111", "#c8302a"], ["#111", "#f0c419", "#fff"], ["#1f6a3a", "#fff", "#e8e4dc"], ["#fff", "#0f2a5a", "#2a9ad8"], ["#e06a1a", "#fff", "#111"], ["#2a9ad8", "#fff", "#0f2a5a"], ["#5b2a78", "#fff", "#f0c419"], ["#e8e4dc", "#7a2f2f", "#1f6a3a"]];
const FONTS = ["italic 900 {}px Arial Black, sans-serif", "900 {}px Impact, sans-serif", "bold {}px Georgia, serif", "italic bold {}px sans-serif", "bold {}px Courier New, monospace"];
const TAGS = ["Official Partner", "Since 1974", "Proud to support rallying", "Llanidloes", "Fuel for the stages", "Made in Wales"];
const EMBLEMS = ["roundel", "chevrons", "tyre", "flame", "peak", "star", "none"];

// A sponsor's advert identity (colours, font, emblem, background) seeded once, then drawn onto every sign that carries it.
function makeSponsor(name, R) {
  const [bg, fg, ac] = pick(R, BRANDS), font = pick(R, FONTS), emblem = pick(R, EMBLEMS), back = pick(R, ["plain", "stripe", "split", "fade"]), tag = pick(R, TAGS), caps = R() < 0.5;
  const texs = {};
  const draw = (x, w, h) => {
    x.fillStyle = bg; x.fillRect(0, 0, w, h);
    if (back === "stripe") { x.fillStyle = ac; x.beginPath(); x.moveTo(w * 0.62, 0); x.lineTo(w * 0.72, 0); x.lineTo(w * 0.6, h); x.lineTo(w * 0.5, h); x.fill(); }
    else if (back === "split") { x.fillStyle = ac; x.fillRect(0, h * 0.82, w, h * 0.18); }
    else if (back === "fade") { const g = x.createLinearGradient(0, 0, w, 0); g.addColorStop(0, bg); g.addColorStop(1, shade(bg, 0.55)); x.fillStyle = g; x.fillRect(0, 0, w, h); }
    let tx = 0.06 * h;
    if (emblem !== "none") { drawEmblem(x, emblem, h * 0.5, h * 0.5, h * 0.36, fg, ac, bg); tx = h; }
    const big = h * (w / h > 5 ? 0.62 : 0.42), withTag = w / h <= 5;
    x.fillStyle = fg; x.font = font.replace("{}", Math.round(big)); x.textBaseline = "middle"; x.textAlign = "left";
    x.fillText(caps ? name.toUpperCase() : name, tx, h * (withTag ? 0.42 : 0.52), w - tx - h * 0.1);
    if (withTag) { x.fillStyle = back === "split" ? bg : ac; x.font = `bold ${Math.round(h * 0.13)}px sans-serif`; x.fillText(tag.toUpperCase(), tx + 4, h * (back === "split" ? 0.91 : 0.72), w - tx - h * 0.1); }
  };
  return { name, bg, fg, draw, tex: aspect => NO_TEXT ? { flat: bg, text: name, fg } : texs[aspect.toFixed(2)] ??= canvasTex(Math.round(128 * aspect), 128, x => draw(x, Math.round(128 * aspect), 128)) };
}
function drawEmblem(x, kind, cx, cy, r, fg, ac, bg) {
  x.save(); x.translate(cx, cy); x.fillStyle = ac; x.strokeStyle = fg; x.lineWidth = r * 0.16;
  const path = pts => { x.beginPath(); pts.forEach(([a, b], i) => i ? x.lineTo(a * r, b * r) : x.moveTo(a * r, b * r)); x.closePath(); };
  if (kind === "roundel") { x.beginPath(); x.arc(0, 0, r, 0, 7); x.fill(); x.stroke(); x.fillStyle = fg; x.beginPath(); x.arc(0, 0, r * 0.4, 0, 7); x.fill(); }
  else if (kind === "chevrons") for (const d of [-0.45, 0.2]) { path([[d - 0.4, -0.9], [d + 0.15, 0], [d - 0.4, 0.9], [d - 0.05, 0.9], [d + 0.5, 0], [d - 0.05, -0.9]]); x.fill(); }
  else if (kind === "tyre") { x.lineWidth = r * 0.38; x.strokeStyle = "#111"; x.beginPath(); x.arc(0, 0, r * 0.78, 0, 7); x.stroke(); x.fillStyle = "#c0c4c8"; x.beginPath(); x.arc(0, 0, r * 0.45, 0, 7); x.fill(); }
  else if (kind === "flame") { x.beginPath(); x.moveTo(0, r); x.quadraticCurveTo(-r, r * 0.4, -r * 0.2, -r); x.quadraticCurveTo(0, -r * 0.2, r * 0.3, -r * 0.6); x.quadraticCurveTo(r, r * 0.3, 0, r); x.fill(); }
  else if (kind === "peak") { path([[-1, 0.8], [-0.2, -0.8], [0.2, -0.1], [0.45, -0.45], [1, 0.8]]); x.fill(); x.fillStyle = fg; path([[-0.2, -0.8], [-0.42, -0.36], [-0.05, -0.5]]); x.fill(); }
  else if (kind === "star") { const p = []; for (let i = 0; i < 10; i++) { const a = -Math.PI / 2 + i * Math.PI / 5, k = i % 2 ? 0.42 : 1; p.push([Math.cos(a) * k, Math.sin(a) * k]); } path(p); x.fill(); x.stroke(); }
  x.restore();
}
const CANOPY = ["#c8302a", "#2a5aa8", "#e8e4dc", "#1f6a3a", "#e0b030", "#1e1e22", "#e06a1a"];
const EVENTS = ["Hafren Rally", "Severn Stages", "Cambrian Rally", "Plynlimon Stages", "Clywedog Sprint"];

// A pop-up gazebo whose open front (+z) faces the road, with a sponsor name on the front valance.
function gazebo(g, x, z, ry, R, col, ad, size = 3) {
  const t = group(g, x, z, ry), h = 2.1, hs = size / 2;
  for (const sx of [-1, 1]) for (const sz of [-1, 1]) cyl(t, 0.03, h, sx * (hs - 0.05), h / 2, sz * (hs - 0.05), "#bbb", 5);
  for (const s of [-1, 1]) { box(t, size, 0.28, 0.02, 0, h - 0.12, s * hs, col); box(t, 0.02, 0.28, size, s * hs, h - 0.12, 0, col); }
  const roof = new THREE.Mesh(new THREE.ConeGeometry(hs * Math.SQRT2, 0.8, 4), M(col)); roof.position.set(0, h + 0.4, 0); roof.rotation.y = Math.PI / 4; t.add(roof);
  if (R() < 0.5) box(t, size, h, 0.02, 0, h / 2, -hs, shade(col, 0.85));
  if (typeof ad === "string") plane(t, size * 0.9, 0.24, textTex(ad, col, col === "#e8e4dc" || col === "#e0b030" ? "#111" : "#fff", size * 0.9 / 0.24), 0, h - 0.12, hs + 0.015);
  else if (ad) plane(t, size * 0.96, 0.26, ad.tex(size * 0.96 / 0.26), 0, h - 0.12, hs + 0.015);
  if (R() < 0.7) { box(t, 1.8, 0.05, 0.7, 0, 0.75, hs - 0.6, "#ddd"); for (const sx of [-0.8, 0.8]) box(t, 0.04, 0.73, 0.6, sx, 0.37, hs - 0.6, "#888"); }
}

// The start-line arch spanning the road, with the event banner hung from it.
function arch(g, kind, span, R, text, col) {
  if (kind === "none") return;
  if (kind === "inflatable") {
    const r = span / 2, tor = new THREE.Mesh(new THREE.TorusGeometry(r, 0.55, 8, 24, Math.PI), M(col)); tor.position.y = 0.3; g.add(tor);
    sign2(g, Math.min(span * 0.7, 9), 1.0, textTex(text, "#fff", "#111", Math.min(span * 0.7, 9)), 0, r * 0.82, 0);
    return;
  }
  const H = 4.6 + R() * 0.8, q = 0.15, c = "#c8ccd0";
  for (const s of [-1, 1]) {
    for (const dx of [-q, q]) for (const dz of [-q, q]) cyl(g, 0.03, H, s * span / 2 + dx, H / 2, dz, c, 5);
    for (let y = 0.3; y < H; y += 0.5) { box(g, 2 * q, 0.03, 0.03, s * span / 2, y, q, c); box(g, 2 * q, 0.03, 0.03, s * span / 2, y, -q, c); }
    box(g, 0.6, 0.06, 0.6, s * span / 2, 0.03, 0, "#555");
  }
  for (const dy of [-q, q]) for (const dz of [-q, q]) box(g, span + 2 * q, 0.06, 0.06, 0, H + dy, dz, c);
  for (let x = -span / 2; x < span / 2; x += 0.5) { box(g, 0.03, 2 * q, 0.03, x, H, q, c); box(g, 0.03, 2 * q, 0.03, x, H, -q, c); }
  sign2(g, span * 0.8, 1.1, textTex(text, col, "#fff", span * 0.8 / 1.1), 0, H - 0.85, 0);
}

// A post-mounted square board; time-control boards are icons, others carry text.
function board(g, x, z, ry, tex, size = 0.7, h = 1.6) {
  cyl(g, 0.04, h, x, h / 2, z, "#444", 6); box(g, size + 0.04, size + 0.04, 0.03, x, h + size / 2 - 0.1, z - 0.02 * Math.cos(ry), "#222", ry);
  plane(g, size, size, tex, x + 0.005 * Math.sin(ry), h + size / 2 - 0.1, z + 0.005 * Math.cos(ry), ry);
}
// The start clock and start lights stand at the roadside facing the arriving car (+z).
function startClock(g, x, z) {
  for (const dx of [-0.35, 0.35]) cyl(g, 0.04, 1.6, x + dx, 0.8, z, "#333", 6);
  box(g, 1.3, 0.7, 0.2, x, 1.9, z, "#111");
  plane(g, 1.2, 0.5, NO_TEXT ? { flat: "#111", text: "00:30", fg: "#ff3020" } : canvasTex(256, 112, c => { c.fillStyle = "#111"; c.fillRect(0, 0, 256, 112); c.fillStyle = "#ff3020"; c.font = "bold 64px monospace"; c.textAlign = "center"; c.textBaseline = "middle"; c.fillText("00:30", 128, 60); }), x, 1.9, z + 0.105);
  ["#e02020", "#e02020", "#e0c020", "#20c040"].forEach((col, i) => { const l = cyl(g, 0.08, 0.06, x - 0.45 + i * 0.3, 2.45, z + 0.1, col, 10); l.rotation.x = Math.PI / 2; });
  box(g, 1.4, 0.3, 0.15, x, 2.45, z, "#222");
}
const bale = (g, x, y, z, ry) => box(g, 1.2, 0.5, 0.48, x, y + 0.25, z, "#c8a858", ry);
function cone(g, x, z) { const m = new THREE.Mesh(new THREE.ConeGeometry(0.18, 0.7, 8), M("#ee6a12")); m.position.set(x, 0.35, z); g.add(m); cyl(g, 0.11, 0.1, x, 0.4, z, "#eee", 8); }
// A feather flag: pole plus a tall banner curving off it.
function flag(g, x, z, ry, col) {
  const t = group(g, x, z, ry); cyl(t, 0.025, 3.4, 0, 1.7, 0, "#ccc", 5);
  const s = new THREE.Shape(); s.moveTo(0, 0.6); s.lineTo(0.6, 0.7); s.quadraticCurveTo(0.75, 2.8, 0, 3.35); s.closePath();
  const m = new THREE.Mesh(new THREE.ShapeGeometry(s), new THREE.MeshLambertMaterial({ color: col, side: THREE.DoubleSide })); t.add(m);
}
// Red and white tape strung between stakes along the crowd line, from z0 to z1 at x.
function tape(g, x, z0, z1) {
  const n = Math.max(1, Math.round((z1 - z0) / 3)), step = (z1 - z0) / n;
  for (let i = 0; i <= n; i++) cyl(g, 0.025, 1.0, x, 0.5, z0 + i * step, "#ddd", 5);
  for (let i = 0; i < n * 3; i++) box(g, 0.01, 0.06, step / 3, x, 0.92, z0 + (i + 0.5) * step / 3, i % 2 ? "#eee" : "#d02020");
}
// A wire-mesh site fence panel with a sponsor banner on its face.
function banner(g, x, z, ry, ad) {
  const t = group(g, x, z, ry);
  for (const sx of [-1.15, 1.15]) { box(t, 0.05, 2, 0.05, sx, 1.0, 0, "#999"); box(t, 0.5, 0.12, 0.25, sx, 0.06, 0, "#333"); }
  box(t, 2.3, 0.05, 0.05, 0, 1.97, 0, "#999");
  plane(t, 2.2, 0.8, ad.tex(2.75), 0, 1.3, 0.03);
}
const portaloo = (g, x, z, ry, col) => { const t = group(g, x, z, ry); box(t, 1.1, 2.2, 1.1, 0, 1.1, 0, col); box(t, 1.2, 0.1, 1.2, 0, 2.25, 0, shade(col, 0.8)); box(t, 0.8, 1.9, 0.02, 0, 1.0, 0.56, shade(col, 0.9)); };

// Options: width, len (road width and zone length), arch ("truss" | "inflatable" | "none" | auto), event (banner text, seeded when blank),
// noText (exporting for the game: signs become flat colour plus a marker in `texts`, drawn by the game as 3D labels).
function build(seed, o) {
  NO_TEXT = !!o.noText;
  o = { ...o, event: (o.event || pick(rng(seed + 7), EVENTS)).toUpperCase() };
  const R = rng(seed), root = new THREE.Group(), W = o.width, L = o.len, edge = W / 2;
  const pool = SPONSORS.slice(); for (let i = pool.length - 1; i > 0; i--) { const j = Math.floor(R() * (i + 1)); [pool[i], pool[j]] = [pool[j], pool[i]]; }
  const ads = pool.slice(0, 5).map(n => makeSponsor(n, R));
  const archKind = o.arch || pick(R, ["truss", "truss", "inflatable"]), brand = pick(R, CANOPY), tapeOff = 0.8 + R() * 0.4;
  // a strip behind the tape kept clear for the game's own spectators; gazebos and portaloos stand right behind it
  const crowdBand = 2.2, back = edge + tapeOff + crowdBand;
  // the start control (clock, officials' gazebo, boards) stands on one side
  const cs = R() < 0.5 ? -1 : 1, ctlLo = -4, ctlHi = 12;

  arch(root, archKind, W + 1.6, R, o.event, brand);
  for (const s of [-1, 1]) { bale(root, s * (edge + 1.3), 0, 0.75, Math.PI / 2); bale(root, s * (edge + 1.3), 0, -0.75, Math.PI / 2); bale(root, s * (edge + 1.3), 0.5, 0, Math.PI / 2); }

  startClock(root, cs * (edge + 0.9), 1.9);
  gazebo(root, cs * (edge + 2.0), 5, -cs * Math.PI / 2, R, brand, "START CONTROL");
  board(root, cs * (edge + 0.5), L * 0.35, 0, clockTex("#f0c419"));
  board(root, cs * (edge + 0.5), 3.0, 0, clockTex("#d02020"));
  board(root, cs * (edge + 0.5), -L * 0.3, 0, clockTex("#d8ccb0", true));
  board(root, -cs * (edge + 0.5), 6, 0, textTex("SS" + (1 + Math.floor(R() * 9)), "#fff", "#111", 1), 0.8);
  for (let z = 1.5; z < 9; z += 2.5) cone(root, cs * (edge + 0.25), z);

  // the opposite side of the line gets sponsor fencing in place of tape
  const bz = 12, nb = Math.floor(bz * 2 / 2.4);
  for (let i = 0; i < nb; i++) banner(root, -cs * (edge + tapeOff), -bz + 1.2 + i * 2.4, cs * Math.PI / 2, pick(R, ads));
  for (const s of [-1, 1]) {
    const x = s * (edge + tapeOff), skip = s === cs ? [ctlLo, ctlHi] : [-bz, bz];
    tape(root, x, -L / 2, skip[0]); tape(root, x, skip[1], L / 2);
  }
  for (let i = 0; i < 2 + R() * 3; i++) { const s = R() < 0.5 ? -1 : 1; flag(root, s * (edge + tapeOff - 0.3), (R() - 0.3) * L * 0.4, R() * 6, pick(R, CANOPY)); }

  const ps = R() < 0.5 ? -1 : 1, pz = (R() < 0.5 ? -1 : 1) * L * 0.4, lc = pick(R, ["#2a5aa8", "#1f6a3a", "#2a8a9a"]), nLoo = 2 + Math.floor(R() * 3);
  for (let i = 0; i < nLoo; i++) portaloo(root, ps * (back + 0.6), pz + i * 1.3, -ps * Math.PI / 2, lc);
  // gazebos walked along each side with seeded gaps, skipping the start control and the portaloos
  let nGaz = 0, outer = back + 1.2;
  for (const s of [-1, 1]) {
    for (let z = -L / 2 + 2; z < L / 2 - 2; z += 3.6 + R() * 6) {
      if (s === cs && z > ctlLo - 3 && z < ctlHi + 1) continue;
      if (s === ps && z > pz - 3 && z < pz + nLoo * 1.3 + 1.5) continue;
      if (R() < 0.45) continue;
      const big = R() < 0.25, size = big ? 4 : 3;
      gazebo(root, s * (back + size / 2 + R() * 0.3), z, -s * Math.PI / 2, R, pick(R, CANOPY), R() < 0.7 ? pick(R, ads) : null, size);
      nGaz++; z += big ? 1 : 0; outer = Math.max(outer, back + size + 0.3);
    }
  }

  const texts = [];
  if (NO_TEXT) {
    root.updateMatrixWorld(true);
    const marks = []; root.traverse(n => { if (n.userData.text) marks.push(n); });
    const r3 = v => Math.round(v * 1000) / 1000;
    for (const n of marks) {
      const p = new THREE.Vector3(), q = new THREE.Quaternion(); n.matrixWorld.decompose(p, q, new THREE.Vector3());
      const t = n.userData.text; texts.push({ text: t.text, color: t.color, w: r3(t.w), h: r3(t.h), p: [p.x, p.y, p.z].map(r3), q: [q.x, q.y, q.z, q.w].map(r3) });
      n.parent.remove(n);
    }
  }
  return { root, texts, info: { event: o.event, arch: archKind, side: cs < 0 ? "left" : "right", gazebos: nGaz + 1, ads, outer } };
}
return { build, SEEDS, WIDTH, LEN };
})();
