// Procedural roadside car shops / tuning garages from a seed, as flat-coloured three.js meshes.
// Shared by tools/shop_lab.html, tools/level_editor_lab.html and tools/bake_buildings.js; needs three.js loaded first.
const Shops = (() => {
const PALETTES = {
  "Rusty tin":   { wall: "#8a4a2c", roof: "#6d6f70", trim: "#e8e0cc", door: "#4d5a63", pad: "#7d7a72", accent: "#c8402a" },
  "Green shed":  { wall: "#4d6a4a", roof: "#555a58", trim: "#dfd9c4", door: "#8a8f90", pad: "#807d74", accent: "#e0b030" },
  "Whitewash":   { wall: "#d8d4c6", roof: "#5a4a44", trim: "#2f3a4a", door: "#a33a2a", pad: "#8a867c", accent: "#2f6aa8" },
  "Blue garage": { wall: "#486a88", roof: "#47494c", trim: "#e8e8e0", door: "#c9cdd0", pad: "#76746e", accent: "#e8d030" },
};
const DISPLAY_PARTS = ["turbo", "lightweight", "radiator", "gearbox", "rollcage"];

function rng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6D2B79F5) >>> 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
const pick = (R, a) => a[Math.floor(R() * a.length)];
const shuf = (R, a) => { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(R() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };
const shade = (c, k) => "#" + new THREE.Color(c).multiplyScalar(k).getHexString();
const lum = c => { const k = new THREE.Color(c); return 0.3 * k.r + 0.59 * k.g + 0.11 * k.b; };

let SOLID = false;
const mats = {};
const M = c => mats[c] ??= new THREE.MeshLambertMaterial({ color: c });
const T = (c, o) => SOLID ? M(c) : mats[c + "|" + o] ??= new THREE.MeshLambertMaterial({ color: c, transparent: true, opacity: o });
const box = (g, w, h, d, x, y, z, c, ry = 0) => { const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), M(c)); m.position.set(x, y, z); m.rotation.y = ry; g.add(m); return m; };
const tbox = (g, w, h, d, x, y, z, c, o) => { const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), T(c, o)); m.position.set(x, y, z); g.add(m); return m; };
const cyl = (g, r, h, x, y, z, c, seg = 8, rz = 0) => { const m = new THREE.Mesh(new THREE.CylinderGeometry(r, r, h, seg), M(c)); m.position.set(x, y, z); m.rotation.z = rz; g.add(m); return m; };

// A 2D outline extruded along z and centred on z; used for gables, wedges and arched roofs.
function poly(g, pts, d, c, x, y, z) {
  const s = new THREE.Shape(pts.map(p => new THREE.Vector2(p[0], p[1])));
  const geo = new THREE.ExtrudeGeometry(s, { depth: d, bevelEnabled: false }); geo.translate(0, 0, -d / 2);
  const m = new THREE.Mesh(geo, M(c)); m.position.set(x, y, z); g.add(m); return m;
}
const arch = (w, h, n = 14) => { const p = []; for (let i = 0; i <= n; i++) { const a = Math.PI * i / n; p.push([Math.cos(a) * w / 2, Math.sin(a) * h]); } return p; };
const ribs = (g, w, h, z, c, step) => { for (let x = -w / 2 + step / 2; x < w / 2; x += step) box(g, 0.07, h, 0.05, x, h / 2, z, c); };
const roofH = (k, w, h, x, dir) => k === "gable" ? h * (1 - 2 * Math.abs(x) / w) : k === "mono" ? h * (0.5 + dir * x / w) : k === "curved" ? h * Math.sqrt(Math.max(0, 1 - (2 * x / w) ** 2)) : 0.2;

// Roof over a w x d footprint whose walls end at height y; ridge runs front to back so the gable faces the forecourt.
function roof(g, kind, w, d, h, y, c, wallC, dir = 1) {
  if (kind === "gable") {
    poly(g, [[-w / 2, 0], [w / 2, 0], [0, h]], d, wallC, 0, y, 0);
    const a = Math.atan2(h, w / 2), len = Math.hypot(w / 2, h) + 0.4;
    for (const s of [-1, 1]) box(g, len, 0.12, d + 0.6, s * w / 4, y + h / 2 + 0.07, 0, c).rotation.z = -s * a;
  } else if (kind === "mono") {
    poly(g, [[-w / 2, 0], [w / 2, 0], [dir * w / 2, h]], d, wallC, 0, y, 0);
    box(g, Math.hypot(w, h) + 0.4, 0.12, d + 0.6, 0, y + h / 2 + 0.07, 0, c).rotation.z = dir * Math.atan2(h, w);
  } else if (kind === "curved") poly(g, arch(w + 0.2, h), d + 0.4, c, 0, y, 0);
  else {
    box(g, w + 0.3, 0.2, d + 0.3, 0, y + 0.1, 0, c);
    const p = shade(wallC, 0.9);
    for (const s of [-1, 1]) { box(g, w + 0.3, 0.45, 0.18, 0, y + 0.22, s * (d / 2 + 0.06), p); box(g, 0.18, 0.45, d + 0.3, s * (w / 2 + 0.06), y + 0.22, 0, p); }
  }
}

// Front-wall elements are slots ({w, fn}) laid out left to right and squeezed to fit the wall.
function front(g, bw, slots, z, cx = 0) {
  const gap = 0.5; let tot = slots.reduce((a, s) => a + s.w, 0) + gap * (slots.length - 1);
  const k = Math.min(1, (bw - 1.2) / tot); tot *= k; let x = -tot / 2;
  for (const s of slots) { const w = s.w * k; s.fn(g, cx + x + w / 2, w, z); x += w + gap * k; }
}
function win(g, x, y, z, w, h, tc) {
  box(g, w + 0.16, h + 0.16, 0.1, x, y, z + 0.03, tc); box(g, w, h, 0.12, x, y, z + 0.04, "#9fc4d8");
  box(g, 0.05, h, 0.14, x, y, z + 0.05, tc); box(g, w, 0.05, 0.14, x, y, z + 0.05, tc);
}
const rollerS = (pal, w, h) => ({ w, fn: (g, x, ww, z) => {
  box(g, ww + 0.2, h + 0.1, 0.12, x, h / 2 + 0.05, z + 0.03, pal.trim); box(g, ww, h, 0.14, x, h / 2, z + 0.05, pal.door);
  for (let k = 1; k < 7; k++) box(g, ww, 0.03, 0.16, x, k * h / 7, z + 0.06, shade(pal.door, 0.7));
} });
const doorS = (pal, c = "#5a3a22") => ({ w: 1.0, fn: (g, x, ww, z) => { box(g, ww, 2.0, 0.12, x, 1.0, z + 0.04, pal.trim); box(g, ww - 0.2, 1.9, 0.14, x, 0.95, z + 0.05, c); } });
const winS = (pal, w = 1.3) => ({ w, fn: (g, x, ww, z) => win(g, x, 1.7, z, ww, 0.9, pal.trim) });
const barnS = (w, h, c) => ({ w, fn: (g, x, ww, z) => {
  box(g, ww + 0.3, h + 0.15, 0.14, x, h / 2 + 0.07, z + 0.03, "#2a1e14");
  for (const s of [-1, 1]) box(g, ww / 2 - 0.03, h, 0.16, x + s * ww / 4, h / 2, z + 0.05, c);
  box(g, 0.05, h, 0.18, x, h / 2, z + 0.06, "#222");
} });

const flue = (g, x, y, z, c) => { cyl(g, 0.2, 1.3, x, y + 0.65, z, c, 8); cyl(g, 0.28, 0.12, x, y + 1.35, z, c, 8); };
const stack = (g, x, y, z, c) => { box(g, 0.7, 1.8, 0.7, x, y + 0.9, z, c); box(g, 0.85, 0.12, 0.85, x, y + 1.85, z, shade(c, 0.7)); for (const s of [-1, 1]) cyl(g, 0.1, 0.35, x + s * 0.18, y + 2.1, z, "#8a4a2c", 6); };

// A sloping lean-to against one side wall: falls from highY at the wall to lowY at the outer posts.
function leanTo(g, side, half, bd, lw, lowY, highY, c, wallC, walls) {
  box(g, Math.hypot(lw, highY - lowY) + 0.4, 0.1, bd + 0.4, side * (half + lw / 2), (lowY + highY) / 2, 0, c).rotation.z = -side * Math.atan2(highY - lowY, lw);
  for (const sz of [-1, 1]) cyl(g, 0.06, lowY, side * (half + lw - 0.1), lowY / 2, sz * (bd / 2 - 0.1), "#555", 6);
  if (walls) box(g, 0.1, lowY, bd, side * (half + lw), lowY / 2, 0, wallC);
}

// Each archetype builds a shop at the origin (front faces +z) and returns its measurements for signs, pad and yard.
const ARCH = {
  tin: { label: "Corrugated tin workshop", clear: 3, fn(g, R, pal, S, c) {
    const bw = Math.max(9.5, 5 + Math.min(3, Math.max(c.n, 1)) * 2.4 + R() * 2) * S, bd = (6 + R() * 3) * S, wh = (3.2 + R() * 0.8) * S;
    const kind = pick(R, ["gable", "gable", "mono", "curved", "flat"]), dir = R() < 0.5 ? 1 : -1, rh = kind === "flat" ? 0.2 : (kind === "mono" ? 1.0 : 1.4) * S;
    box(g, bw, wh, bd, 0, wh / 2, 0, pal.wall); ribs(g, bw, wh, bd / 2 + 0.02, shade(pal.wall, 0.82), 0.55);
    roof(g, kind, bw, bd, rh, wh, pal.roof, pal.wall, dir);
    const slots = [], rh2 = Math.min(2.8 * S, wh - 1.0);
    for (let i = 1 + Math.floor(R() * Math.min(3, Math.max(c.n, 1))); i > 0; i--) slots.push(rollerS(pal, 3.2 * S, rh2));
    slots.push(doorS(pal)); for (let i = Math.floor(R() * 3); i > 0; i--) slots.push(winS(pal));
    front(g, bw, shuf(R, slots), bd / 2);
    const fx = (R() < 0.5 ? -1 : 1) * (bw / 2 - 1.2); flue(g, fx, wh + roofH(kind, bw, rh, fx, dir), -bd / 4, "#555");
    let extL = bw / 2, extR = bw / 2, lean = "";
    if (R() < 0.5) { const s = R() < 0.5 ? -1 : 1, lw = 2.6 * S; leanTo(g, s, bw / 2, bd, lw, 2.3 * S, wh - 0.3, pal.roof, pal.wall, R() < 0.5); if (s < 0) extL += lw; else extR += lw; lean = " + lean-to"; }
    return { bw, bd, wh, extL, extR, fz: bd / 2, fy: wh + 0.9, py: kind === "gable" ? wh + 0.5 : wh - 0.5, sw: Math.min(bw * 0.55, 5.6), wallC: pal.wall, signs: ["fascia", "fascia", "pole", "painted"], desc: kind + " roof, " + rh2.toFixed(1) + "m roller doors" + lean };
  } },
  barn: { label: "Stone barn, slate roof", clear: 3, fn(g, R, pal, S, c) {
    const bw = (9.5 + R() * 3) * S, bd = (7 + R() * 2) * S, wh = 3.3 * S, stone = pick(R, ["#8a8478", "#9c9078", "#7a7a74", "#a39a84"]), slate = pick(R, ["#454c54", "#5a5048", "#3e444a"]);
    const kind = R() < 0.8 ? "gable" : "mono", dir = R() < 0.5 ? 1 : -1, rh = (kind === "gable" ? 2.0 : 1.2) * S;
    box(g, bw, wh, bd, 0, wh / 2, 0, stone);
    for (let i = 0; i < 26; i++) box(g, 0.4 + R() * 0.5, 0.22 + R() * 0.15, 0.05, (R() - 0.5) * (bw - 0.6), 0.2 + R() * (wh - 0.4), bd / 2 + 0.02, shade(stone, 0.75 + R() * 0.5));
    roof(g, kind, bw, bd, rh, wh, slate, stone, dir);
    const slots = [barnS(3.4 * S, wh - 0.8, pick(R, ["#6a4a2c", "#3a4a5a", "#7a3a2a"])), doorS(pal), winS(pal, 0.9)]; if (R() < 0.6) slots.push(winS(pal, 0.9));
    front(g, bw, shuf(R, slots), bd / 2);
    const sx = (R() < 0.5 ? -1 : 1) * (bw / 2 - 1); stack(g, sx, wh + roofH(kind, bw, rh, sx, dir) - 0.2, -bd / 4, stone);
    let extL = bw / 2, extR = bw / 2, lean = "";
    if (R() < 0.55) { const s = R() < 0.5 ? -1 : 1, lw = 3 * S; leanTo(g, s, bw / 2, bd, lw, 2.3 * S, wh - 0.4, slate, stone, true); if (s < 0) extL += lw; else extR += lw; lean = " + stone lean-to"; }
    return { bw, bd, wh, extL, extR, fz: bd / 2, fy: wh + 0.9, py: kind === "gable" ? wh + 0.55 : wh - 0.4, sw: Math.min(bw * 0.5, 5), wallC: stone, signs: ["painted", "painted", "fascia", "pole"], desc: kind + " slate roof, stone chimney" + lean };
  } },
  nissen: { label: "Nissen hut", clear: 3, fn(g, R, pal, S, c) {
    const bw = (8 + R() * 2) * S, bd = (8 + R() * 3) * S, h = bw * 0.42, rc = pick(R, ["#7a8080", "#5a6648", "#8a5a3a", "#6a6e72"]), endC = pick(R, ["#8a4a3a", "#bdb8a8", "#6a4a2c", "#8a8f90"]);
    poly(g, arch(bw, h), bd, rc, 0, 0, 0); poly(g, arch(bw, h), 0.1, endC, 0, 0, bd / 2 + 0.04);
    for (let z = -bd / 2 + 0.5; z < bd / 2 - 0.2; z += 1.0) poly(g, arch(bw + 0.14, h + 0.07), 0.1, shade(rc, 0.8), 0, 0, z);
    const slots = [rollerS(pal, 3.4 * S, 2.4 * S), doorS(pal)]; if (R() < 0.6) slots.push(winS(pal));
    front(g, bw * 0.75, shuf(R, slots), bd / 2 + 0.06);
    flue(g, (R() < 0.5 ? -1 : 1) * 1.5, h * 0.9, -bd / 4, "#444");
    return { bw, bd, wh: h, extL: bw / 2, extR: bw / 2, fz: bd / 2, fy: h, py: Math.min(h - 0.7, 2.4 * S + 0.6), pz: bd / 2 + 0.12, sw: 3.6 * S, wallC: endC, signs: ["painted", "painted", "pole"], desc: "curved corrugated vault, " + (endC === "#8a4a3a" ? "brick" : "plain") + " end wall" };
  } },
  showroom: { label: "Glass-fronted showroom", clear: 3, fn(g, R, pal, S, c) {
    const bw = Math.min(14, 9 + c.n * 0.8 + R() * 2) * S, bd = 6 * S, wh = 3.4 * S, wallC = pick(R, ["#d8d4c6", "#c9ccce", "#8a8f94", "#e8e4d8"]);
    box(g, bw, wh, bd, 0, wh / 2, 0, wallC);
    const gw = bw - 2.6, gx = (R() < 0.5 ? -1 : 1) * 0.4, n = Math.max(1, Math.round(gw / 1.6));
    tbox(g, gw, 2.7 * S, 0.1, gx, 1.5 * S, bd / 2 + 0.05, "#9fc4d8", 0.45);
    for (let i = 0; i <= n; i++) box(g, 0.07, 2.8 * S, 0.14, gx - gw / 2 + i * gw / n, 1.45 * S, bd / 2 + 0.06, "#333");
    box(g, gw, 0.07, 0.14, gx, 2.85 * S, bd / 2 + 0.06, "#333"); box(g, gw, 0.2, 0.14, gx, 0.1, bd / 2 + 0.06, "#333");
    const dx = gx + (gx < 0 ? 1 : -1) * (gw / 2 - 1.1); box(g, 1.3, 2.3, 0.18, dx, 1.15, bd / 2 + 0.06, "#222"); tbox(g, 1.1, 2.1, 0.2, dx, 1.1, bd / 2 + 0.07, "#9fc4d8", 0.6);
    box(g, 2.2, 0.9, 0.7, gx, 0.45, bd / 2 - 1.0, "#6a4a2c");
    roof(g, "flat", bw, bd, 0.2, wh, shade(wallC, 0.6), wallC);
    box(g, bw + 0.4, 0.18, 1.6, 0, wh - 0.25, bd / 2 + 0.8, pal.accent); box(g, 1.2, 0.6, 0.9, -gx * 4, wh + 0.5, -bd / 4, "#9a9ea0");
    let extL = bw / 2, extR = bw / 2;
    const s = R() < 0.5 ? -1 : 1, aw = 4.2 * S, ad = bd * 0.85, az = -bd / 2 + ad;
    box(g, aw, 2.9 * S, ad, s * (bw / 2 + aw / 2), 1.45 * S, az - ad / 2, shade(wallC, 0.9)); box(g, aw + 0.2, 0.15, ad + 0.2, s * (bw / 2 + aw / 2), 2.95 * S, az - ad / 2, pal.roof);
    front(g, aw, [rollerS(pal, aw - 1.2, 2.4 * S)], az, s * (bw / 2 + aw / 2)); if (s < 0) extL += aw; else extR += aw;
    const sw = Math.min(bw * 0.5, 5.5);
    return { bw, bd, wh, extL, extR, fz: bd / 2 - 0.1, fy: wh + 0.55 + sw / 8, sw, noPosts: true, signs: ["fascia", "fascia", "pole"], desc: "flat roof with parapet, glass front, side service bay" };
  } },
  cabin: { label: "Portakabin + steel canopy", clear: 2.4, fn(g, R, pal, S, c) {
    const cw = (5.4 + R() * 1.6) * S, bd = 3.2 * S, ch = 2.7 * S, cc = pick(R, ["#5a6b5a", "#8a9a9e", "#c8c4b4", "#3a5a78"]);
    const W = Math.max(cw + 3, c.perRow * 3.1 + 1.4), cd = c.clear + c.rowL + 0.8, cx = -W / 2 + cw / 2 + 0.2;
    const cg = new THREE.Group(); cg.position.set(cx, 0, 0); g.add(cg);
    box(cg, cw, ch, bd, 0, ch / 2, 0, cc); ribs(cg, cw, ch, bd / 2 + 0.02, shade(cc, 0.85), 1.2);
    roof(cg, "mono", cw, bd, 0.25, ch, shade(cc, 0.8), cc, 1);
    front(cg, cw, shuf(R, [doorS(pal, "#3a3a3a"), winS(pal, 1.8), winS(pal, 1.2)]), bd / 2);
    box(cg, 1.4, 0.3, 0.9, 0, 0.15, bd / 2 + 0.5, "#777"); flue(cg, cw / 2 - 0.8, ch + 0.2, -bd / 4, "#444");
    // the canopy covers the front of the yard only, so the cabin's own roof stays in the open beside it
    const top = 3.6, za = bd / 2 + c.clear - 0.6, zb = bd / 2 + cd, m = Math.max(2, Math.round(W / 3.5) + 1);
    box(g, W + 0.6, 0.14, zb - za + 0.4, 0, top, (za + zb) / 2, shade(pal.roof, 0.85));
    for (const z of [za, zb - 0.1]) for (let i = 0; i < m; i++) cyl(g, 0.08, top, -W / 2 + 0.2 + i * (W - 0.4) / (m - 1), top / 2, z, "#555", 8);
    for (let i = 0; i <= 3; i++) box(g, W + 0.4, 0.2, 0.1, 0, top - 0.17, za + (zb - za) * i / 3, "#444");
    box(g, W + 0.6, 0.4, 0.15, 0, top - 0.1, bd / 2 + cd + 0.1, pal.accent);
    const sw = Math.min(W * 0.6, 5.2);
    return { bw: W, bd, wh: ch, extL: W / 2, extR: W / 2, bodyX: [cx - cw / 2, cx + cw / 2], fz: bd / 2 + cd, fy: top + 0.2 + sw / 8, sw, noPosts: true, signs: ["fascia", "fascia", "pole"], desc: "cabin office, open steel canopy over the bays" };
  } },
  timber: { label: "Timber-clad shed", clear: 3, fn(g, R, pal, S, c) {
    const bw = (8.5 + R() * 3) * S, bd = (6.5 + R() * 2) * S, wh = 3.2 * S, tc = pick(R, ["#6a4a2c", "#2a2a2a", "#7a2a22", "#5a6a58", "#8a7a58"]), rc = pick(R, ["#6d6f70", "#4a3a30", "#3a3a3a"]);
    const kind = R() < 0.7 ? "gable" : "mono", dir = R() < 0.5 ? 1 : -1, rh = (kind === "gable" ? 1.5 : 1.0) * S;
    box(g, bw, wh, bd, 0, wh / 2, 0, tc); ribs(g, bw, wh, bd / 2 + 0.02, shade(tc, 0.75), 0.3);
    roof(g, kind, bw, bd, rh, wh, rc, tc, dir);
    const slots = [barnS(3.0 * S, wh - 0.8, shade(tc, 1.2)), winS(pal)]; if (R() < 0.5) slots.push(doorS(pal)); if (R() < 0.5) slots.push(winS(pal));
    front(g, bw, shuf(R, slots), bd / 2);
    const s = R() < 0.5 ? -1 : 1, lw = 3 * S; leanTo(g, s, bw / 2, bd, lw, 2.2 * S, wh - 0.3, rc, tc, false);
    for (let i = 0; i < 3; i++) box(g, 0.9, 0.5, 0.5, s * (bw / 2 + lw / 2 + (i - 1) * 0.9), 0.25 + (i === 1 ? 0.5 : 0), -bd / 2 + 0.5, "#8a6a3a");
    cyl(g, 0.1, wh + 0.8, -s * (bw / 2 + 0.1), (wh + 0.8) / 2, -bd / 4, "#444", 6); cyl(g, 0.16, 0.1, -s * (bw / 2 + 0.1), wh + 0.85, -bd / 4, "#333", 8);
    return { bw, bd, wh, extL: bw / 2 + (s < 0 ? lw : 0), extR: bw / 2 + (s > 0 ? lw : 0), fz: bd / 2, fy: wh + 0.9, py: kind === "gable" ? wh + 0.45 : wh - 0.4, sw: Math.min(bw * 0.5, 5), wallC: tc, signs: ["fascia", "painted", "painted", "pole"], desc: kind + " roof, battened timber, open lean-to" };
  } },
};
const STYLE_IDS = Object.keys(ARCH);

function makePart(id) {
  const g = new THREE.Group();
  const pallet = () => { box(g, 1.1, 0.14, 1.1, 0, 0.07, 0, "#9a7a4a"); };
  switch (id) {
    case "turbo": case "big_turbo": { const s = id === "big_turbo" ? 1.5 : 1; pallet(); const t = new THREE.Group(); cyl(t, 0.3, 0.3, 0, 0, 0, "#8a8f90", 10, Math.PI / 2); cyl(t, 0.22, 0.4, 0.3, 0, 0, "#c8402a", 10); cyl(t, 0.14, 0.4, 0, 0.3, 0, "#555", 8); t.scale.setScalar(s); t.position.set(0, 0.45 * s, 0); g.add(t); break; }
    case "lightweight": { for (let i = 0; i < 4; i++) { box(g, 0.9, 0.04, 0.9, 0, 0.05 + i * 0.07, 0, i % 2 ? "#b8bcc0" : "#7a7e82"); } box(g, 0.1, 0.5, 0.1, 0.3, 0.3, 0.3, "#e0b030"); break; }
    case "radiator": pallet(); box(g, 0.9, 0.7, 0.12, 0, 0.5, 0, "#5a5f64"); box(g, 0.8, 0.6, 0.14, 0, 0.5, 0, "#2a2d30"); break;
    case "rollcage": { for (const sx of [-0.5, 0.5]) { cyl(g, 0.04, 1.3, sx, 0.65, -0.5, "#d9d9d9"); cyl(g, 0.04, 1.3, sx, 0.65, 0.5, "#d9d9d9"); cyl(g, 0.04, 1.0, sx, 1.3, 0, "#d9d9d9", 6, 0).rotation.x = Math.PI / 2; } cyl(g, 0.04, 1.0, 0, 1.3, -0.5, "#d9d9d9", 6, Math.PI / 2); cyl(g, 0.04, 1.0, 0, 1.3, 0.5, "#d9d9d9", 6, Math.PI / 2); break; }
    case "gearbox": pallet(); box(g, 0.5, 0.4, 0.9, 0, 0.35, 0, "#6a6e72"); cyl(g, 0.22, 0.5, 0, 0.35, 0.6, "#4a4d50", 8, 0).rotation.x = Math.PI / 2; break;
    case "nitrous": for (let i = 0; i < 3; i++) { const x = (i - 1) * 0.4; cyl(g, 0.14, 0.9, x, 0.45, 0, i === 1 ? "#2f6aa8" : "#3a7ab8"); cyl(g, 0.07, 0.12, x, 0.95, 0, "#c0c4c8"); } box(g, 1.3, 0.1, 0.5, 0, 0.03, 0, "#555"); break;
    case "aero": { for (const sx of [-0.5, 0.5]) box(g, 0.08, 0.6, 0.08, sx, 0.3, 0, "#333"); box(g, 1.4, 0.06, 0.4, 0, 0.7, 0, "#222").rotation.x = -0.15; box(g, 0.06, 0.2, 0.4, -0.7, 0.7, 0, "#c8402a"); box(g, 0.06, 0.2, 0.4, 0.7, 0.7, 0, "#c8402a"); break; }
    default: pallet(); box(g, 0.6, 0.5, 0.6, 0, 0.4, 0, "#8a8f90");
  }
  return g;
}

// A part on show: a trestle table (or the ground, for tall parts).
function display(g, p, x, z, ry) {
  const d = new THREE.Group(); d.position.set(x, 0, z); d.rotation.y = ry; g.add(d);
  const tall = p.part === "rollcage", top = tall ? 0.04 : 0.8;
  if (!tall) { box(d, 1.3, 0.08, 0.9, 0, 0.76, 0, "#7a5a38"); for (const sx of [-0.55, 0.55]) for (const sz of [-0.35, 0.35]) box(d, 0.07, 0.74, 0.07, sx, 0.37, sz, "#4a3a28"); }
  const part = makePart(p.part); part.position.y = top; part.scale.setScalar(tall ? 1 : 0.85); d.add(part);
}
// A galvanised five-bar farm gate hung on a post, swung open by `open` radians.
function farmGate(g, x, z, len, dir, open) {
  const h = new THREE.Group(); h.position.set(x, 0, z); h.rotation.y = -dir * open; g.add(h);
  const c = "#b4b8bc";
  for (let i = 0; i < 5; i++) box(h, len, 0.05, 0.05, dir * len / 2, 0.25 + i * 0.25, 0, c);
  for (const t of [0.05, len - 0.05]) box(h, 0.07, 1.25, 0.07, dir * t, 0.66, 0, c);
  const dl = Math.hypot(len, 1.0); box(h, dl, 0.05, 0.05, dir * len / 2, 0.75, 0, c).rotation.z = dir * Math.atan2(1.0, len);
}
// A sagging line of pennants between two points.
function bunting(g, a, b, cols, sag = 0.5) {
  const dx = b.x - a.x, dz = b.z - a.z, L = Math.hypot(dx, dz, b.y - a.y), n = Math.max(4, Math.round(L / 0.45)), yaw = Math.atan2(dx, dz) + Math.PI / 2;
  let prev = null;
  for (let i = 0; i <= n; i++) {
    const t = i / n, pt = new THREE.Vector3(a.x + dx * t, a.y + (b.y - a.y) * t - Math.sin(t * Math.PI) * sag, a.z + dz * t);
    if (prev) { const m = box(g, 0.015, 0.015, prev.distanceTo(pt), (prev.x + pt.x) / 2, (prev.y + pt.y) / 2, (prev.z + pt.z) / 2, "#222"); m.lookAt(pt.x, pt.y, pt.z); }
    if (i > 0 && i < n) { const sh = new THREE.Shape(); sh.moveTo(-0.13, 0); sh.lineTo(0.13, 0); sh.lineTo(0, -0.28); sh.closePath();
      const f = new THREE.Mesh(new THREE.ShapeGeometry(sh), new THREE.MeshLambertMaterial({ color: cols[i % cols.length], side: THREE.DoubleSide })); f.position.copy(pt); f.rotation.y = yaw; g.add(f); }
    prev = pt;
  }
}
const stain = (g, x, z, r) => { const m = new THREE.Mesh(new THREE.CircleGeometry(r, 10), SOLID ? M("#3a3a3a") : T("#1a1a1a", 0.35)); m.rotation.x = -Math.PI / 2; m.position.set(x, 0.065, z); g.add(m); };
// A pair of old petrol pumps on a little island.
function pumps(g, x, z, pal) {
  box(g, 2.6, 0.15, 1.0, x, 0.08, z, "#9a968c");
  for (const sx of [-0.65, 0.65]) { box(g, 0.55, 1.5, 0.4, x + sx, 0.9, z, pal.accent); box(g, 0.45, 0.35, 0.42, x + sx, 1.35, z, "#eee"); cyl(g, 0.2, 0.08, x + sx, 1.85, z, "#f2ead6", 10, 0).rotation.x = Math.PI / 2; }
}
const floodlight = (g, x, z) => { cyl(g, 0.08, 6, x, 3, z, "#666", 6); box(g, 0.6, 0.3, 0.35, x, 6, z - 0.2, "#333").rotation.x = 0.5; };

const tyreStack = (g, x, z, n) => { for (let i = 0; i < n; i++) { const t = new THREE.Mesh(new THREE.TorusGeometry(0.28, 0.13, 5, 9), M("#1c1c1c")); t.rotation.x = Math.PI / 2; t.position.set(x, 0.14 + i * 0.26, z); g.add(t); } };
const drum = (g, x, z, c) => cyl(g, 0.3, 0.9, x, 0.45, z, c, 9);

function canvasTex(w, h, draw) {
  const c = document.createElement("canvas"); c.width = w; c.height = h; draw(c.getContext("2d"));
  const t = new THREE.CanvasTexture(c); t.encoding = THREE.sRGBEncoding; return t;
}
const signTexture = (text, pal) => canvasTex(512, 128, x => {
  x.fillStyle = pal.accent; x.fillRect(0, 0, 512, 128); x.strokeStyle = pal.trim; x.lineWidth = 8; x.strokeRect(6, 6, 500, 116);
  x.fillStyle = pal.trim; x.font = "bold 56px sans-serif"; x.textAlign = "center"; x.textBaseline = "middle"; x.fillText(text, 256, 68, 480);
});
const paintTexture = (text, col) => canvasTex(640, 128, x => { x.fillStyle = col; x.font = "bold 88px sans-serif"; x.textAlign = "center"; x.textBaseline = "middle"; x.fillText(text, 320, 68, 620); });

// With `noText` (exporting for the game) no text is baked into a texture: each piece of text becomes an empty marker,
// collected into the build's `texts` for the game to draw as its own 3D labels, so the model carries no images.
let NO_TEXT = false;
function textPlane(w, h, tex, text, color, bg) {
  if (!NO_TEXT) return new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: tex(), transparent: !bg }));
  const g = new THREE.Group();
  if (bg) g.add(new THREE.Mesh(new THREE.PlaneGeometry(w, h), M(bg)));
  const t = new THREE.Object3D(); t.position.z = 0.003; t.userData.text = { text, color, w: w * 0.9, h: h * 0.6 }; g.add(t);
  return g;
}
function board(g, w, x, y, z, pal, text) {
  const face = NO_TEXT ? M(pal.accent) : new THREE.MeshBasicMaterial({ map: signTexture(text, pal) });
  const m = new THREE.Mesh(new THREE.BoxGeometry(w, w / 4, 0.15), [M(pal.trim), M(pal.trim), M(pal.trim), M(pal.trim), face, M(pal.trim)]);
  m.position.set(x, y, z); g.add(m);
  if (NO_TEXT) { const t = new THREE.Object3D(); t.position.set(x, y, z + 0.08); t.userData.text = { text, color: pal.trim, w: w * 0.9, h: w / 4 * 0.55 }; g.add(t); }
}

// One run of yard fence between two points; kind picks the construction.
function fence(g, kind, pal, x0, z0, x1, z1) {
  if (kind === "none") return;
  const L = Math.hypot(x1 - x0, z1 - z0), n = Math.max(1, Math.round(L / 2.2)), th = Math.atan2(x1 - x0, z1 - z0), mx = (x0 + x1) / 2, mz = (z0 + z1) / 2;
  const ph = { wire: 1.2, chain: 2.0, tin: 1.9, rail: 1.1 }[kind], pc = { wire: "#6a5a40", chain: "#777", tin: "#555", rail: "#7a5a38" }[kind];
  if (ph) for (let i = 0; i <= n; i++) box(g, 0.1, ph, 0.1, x0 + (x1 - x0) * i / n, ph / 2, z0 + (z1 - z0) * i / n, pc);
  if (kind === "wire") for (const y of [0.5, 1.0]) box(g, 0.025, 0.025, L, mx, y, mz, "#999", th);
  else if (kind === "chain") { const m = tbox(g, 0.02, 1.8, L, mx, 1.0, mz, "#aab", 0.4); m.rotation.y = th; m.userData.chain = true; box(g, 0.05, 0.05, L, mx, 1.95, mz, "#777", th); }
  else if (kind === "stone") box(g, 0.45, 0.9, L, mx, 0.45, mz, "#8a8478", th);
  else if (kind === "tin") box(g, 0.05, 1.8, L, mx, 0.9, mz, shade(pal.wall, 0.9), th);
  else for (const y of [0.45, 0.85]) box(g, 0.05, 0.12, L, mx, y, mz, "#7a5a38", th);
}

const NAMES = ["Garage", "Motors", "Autos", "Tuning", "Breakers", "Car Sales"], PRE = ["Gwyn's", "Hafren", "Dai's", "Valley", "Cwm", "Mid-Wales"];
const PLACES = ["Hafren", "Cwmbiga", "Llanidloes", "Staylittle", "Dylife", "Clywedog"];
const r2 = v => Math.round(v * 100) / 100;

function defaultSign(seed) {
  const rr = rng(seed + 7);
  return rr() < 0.25 ? "Garej " + pick(rr, PLACES) : pick(rr, PRE) + " " + pick(rr, NAMES);
}

// Options: pal (name or object), size, sign, bunting, style, noPad, noText, solid (see-through parts become opaque: for the baked mesh).
function build(seed, o) {
  const R = rng(seed), root = new THREE.Group(), pal = typeof o.pal === "string" ? PALETTES[o.pal] : o.pal, S = o.size ?? 1;
  o = { ...o, sign: o.sign || defaultSign(seed), bunting: o.bunting ?? true };
  NO_TEXT = !!o.noText;
  SOLID = !!o.solid;
  const parts = DISPLAY_PARTS.map(part => ({ part }));
  const picked = pick(R, STYLE_IDS), style = ARCH[o.style] ? o.style : picked;

  const clear = ARCH[style].clear, rowL = 4.8;
  const a = ARCH[style].fn(root, R, pal, S, { n: 3, perRow: 3, rowL, clear });
  const zFront = a.bd / 2 + clear + rowL + 2.5;
  const padW = Math.max(2 * Math.max(a.extL, a.extR) + 6, 14), zBack = -a.bd / 2 - 1.5;
  const surf = pick(R, [pal.pad, pal.pad, "#4a4c4e", "#9a9384"]);
  if (!o.noPad) box(root, padW, 0.06, zFront - zBack, 0, 0.03, (zFront + zBack) / 2, surf);
  for (let i = 0; i < 6 + R() * 6; i++) stain(root, (R() - 0.5) * (padW - 2), zBack + 1 + R() * (zFront - zBack - 2), 0.2 + R() * 0.5);

  // sign
  const sstyle = pick(R, a.signs);
  if (sstyle === "fascia") {
    board(root, a.sw, 0, a.fy, a.fz + 0.35, pal, o.sign);
    if (!a.noPosts) for (const sx of [-1, 1]) cyl(root, 0.06, 1.2, sx * a.sw * 0.4, a.fy - 0.7, a.fz + 0.3, "#333", 6);
  } else if (sstyle === "painted") {
    const pc = lum(a.wallC) > 0.5 ? "#222222" : "#f2ead6", m = textPlane(a.sw, a.sw / 5, () => paintTexture(o.sign, pc), o.sign, pc, null);
    m.position.set(0, a.py, a.pz ?? a.bd / 2 + 0.08); root.add(m);
  } else {
    const sx = (R() < 0.5 ? -1 : 1) * (padW / 2 - 1.2);
    cyl(root, 0.12, 6, sx, 3, zFront - 1.2, "#444", 8); board(root, 3.2, sx, 6.3, zFront - 1.1, pal, o.sign);
  }

  // yard fence with a gate in the front
  const fk = pick(R, ["none", "wire", "chain", "stone", "tin", "rail"]), fx = padW / 2 - 0.3, fz = zFront - 0.3, gap = 5.5;
  fence(root, fk, pal, -fx, fz, -gap / 2, fz); fence(root, fk, pal, gap / 2, fz, fx, fz);
  fence(root, fk, pal, -fx, zBack + 0.3, -fx, fz); fence(root, fk, pal, fx, zBack + 0.3, fx, fz);
  if (fk !== "none") for (const s of [-1, 1]) { box(root, 0.2, 1.6, 0.2, s * gap / 2, 0.8, fz, fk === "stone" ? "#8a8478" : "#666"); farmGate(root, s * gap / 2, fz, gap / 2 - 0.15, -s, 1.75 + R() * 0.4); }

  // parts: beside the building
  const pz = a.bd / 2 + Math.min(1.1, clear - 0.9), pw = 1.6, px0 = -(parts.length - 1) * pw / 2;
  parts.forEach((p, i) => display(root, p, px0 + i * pw, pz, (R() - 0.5) * 0.15));
  // yard dressing
  tyreStack(root, -a.extL - 1.2, a.bd / 2 - 0.6, 4 + Math.floor(R() * 3)); tyreStack(root, -a.extL - 1.2, a.bd / 2 - 1.5, 3);
  tyreStack(root, a.extR + 1.2, a.bd / 2 - 0.5, 3);
  const dcols = [pal.accent, "#2f6aa8", "#555"];
  for (let i = 0; i < 2 + Math.floor(R() * 3); i++) drum(root, a.extR + 0.7 + R() * 0.7, -a.bd / 2 - 0.8 - i * 0.7 + (i > 2 ? 1 : 0), dcols[i % 3]);
  if (R() < 0.35) pumps(root, (R() < 0.5 ? -1 : 1) * (padW / 2 - 2.2), zFront - 2.2, pal);
  if (R() < 0.5) floodlight(root, (R() < 0.5 ? -1 : 1) * (padW / 2 - 0.8), (zBack + zFront) / 2);
  if (o.bunting) {
    const ph = 4.2, z = zFront - 1.0, x0 = -padW / 2 + 0.6, x1 = padW / 2 - 0.6, cols = [pal.accent, pal.trim, "#e0b030", "#2f6aa8"];
    for (const x of [x0, x1]) { cyl(root, 0.06, ph, x, ph / 2, z, "#ccc", 6); box(root, 1.1, 0.65, 0.03, x + (x < 0 ? 0.55 : -0.55), ph - 0.4, z, pal.accent); }
    const ay = Math.min(a.wh - 0.1, 3.6), ax = Math.min(a.bw / 2 - 0.3, x1), az = (a.noPosts ? a.fz : a.bd / 2) + 0.05;
    bunting(root, { x: -ax, y: ay, z: az }, { x: x0, y: ph - 0.05, z }, cols);
    bunting(root, { x: ax, y: ay, z: az }, { x: x1, y: ph - 0.05, z }, cols);
    bunting(root, { x: x0, y: ph - 0.05, z }, { x: x1, y: ph - 0.05, z }, cols, 0.7);
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
  const bounds = [...(a.bodyX ?? [-a.extL, a.extR]), -a.bd / 2, a.bd / 2, a.wh].map(r2);
  return { root, texts, info: { style, box: bounds, sign: o.sign, desc: a.desc, sign: sstyle, fence: fk, padW, zBack, zFront, extL: a.extL, extR: a.extR, bd: a.bd, wh: a.wh } };
}

return { build, defaultSign, PALETTES, STYLE_IDS, ARCH };
})();
