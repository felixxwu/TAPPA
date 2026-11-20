// Lab side of the parity check: runs the road and ground maths pulled out of tools/level_editor_lab.html on
// fixtures/level_parity.json's save and compares them with its expected values (the game's side is test_level_data.gd).
// `node tests/headless/lab_parity.js` checks; add `--write` to regenerate the fixture's expected values from the lab.
const fs = require("fs"), vm = require("vm"), path = require("path");
const html = fs.readFileSync(path.join(__dirname, "../../tools/level_editor_lab.html"), "utf8");
const fixturePath = path.join(__dirname, "fixtures/level_parity.json");
const chunk = (from, to) => { const a = html.indexOf(from), b = html.indexOf(to, a); if (a < 0 || b < 0) throw new Error("lab source moved: " + from); return html.slice(a, b); };

function synthetic() {
  const node = (x, z, w = 3) => ({ x, z, w, m: null, tension: 1 }), n = 24, heightmap = [];
  for (let r = 0; r <= n; r++) for (let c = 0; c <= n; c++) heightmap.push(Math.round((4 * Math.sin(c / 3) + 3 * Math.cos(r / 4) + c * 0.2) * 10) / 10);
  return { size: 120, flat: 1.0, heightmap, roads: [
    [node(-50, -10), node(-20, 0), node(2, 5.5), { ...node(10, 8), tarmac: true }, { ...node(50, 0), tarmac: true }],
    [node(10, 8.3, 2), node(15, 40, 2), node(30, 55, 2)],
    [node(-40, 45), node(-20, 30), node(-20.2, 0.2, 4)],
    [node(-5, 30), node(2.1, 5.6, 2)]] };
}

function runLab(save) {
  const source = `
    const level = save; let SIZE = save.size, N = Math.round(Math.sqrt(save.heightmap.length)) - 1, CELL = SIZE / N, G = SIZE, GCELL = 1;
    const T = { x0: -SIZE / 2, z0: -SIZE / 2, full: true }, WW = () => G * GCELL, FALLOFF = 1, ROAD_FLAT_M = save.flat;
    class Path2D { moveTo() {} lineTo() {} }
    ${chunk("// --- the road: a cubic Hermite", "// The 3D ground window follows")}
    ${chunk("function rebuildGrid()", "// Outside the ground window")}
    heights = new Float32Array((G + 1) ** 2); roadD = new Float32Array((G + 1) ** 2);
    rebuildRoads(); rebuildGrid();
    ({ samples, juncs, heights, G });`;
  return vm.runInNewContext(source, { save, Math, Path2D: undefined, Float32Array, Map });
}

function observe(save, r, points) {
  return {
    sample_count: r.samples.length,
    samples: r.samples.map((s, i) => [i, s.x, s.z, s.w, s.h, s.t]).filter(s => s[0] % 6 === 0),
    junctions: r.juncs.map(j => [j.x, j.z, j.w]),
    heights: points.map(([x, z]) => [x, z, r.heights[(z + save.size / 2) * (r.G + 1) + x + save.size / 2]]),
  };
}

const points = [[0, 0], [-20, 0], [10, 8], [10, 12], [10, 20], [-20, 15], [-20, -3], [-50, -10], [40, 3], [0, 30], [30, 55], [-45, 40], [55, -25], [-59, 59], [5, 5], [2, 5], [4, 6], [6, 7], [8, 8], [2, 10]];
if (process.argv.includes("--write")) {
  const save = synthetic(), { flat, ...rest } = save;
  fs.writeFileSync(fixturePath, JSON.stringify({ save: { ...rest }, flat_margin: flat, points, expected: observe(save, runLab(save), points) }) + "\n");
  console.log("wrote", fixturePath);
} else {
  const fx = JSON.parse(fs.readFileSync(fixturePath, "utf8")), save = { ...fx.save, flat: fx.flat_margin };
  const got = observe(save, runLab(save), fx.points), want = fx.expected;
  const bad = [];
  const near = (a, b) => Math.abs(a - b) < 1e-3;
  if (got.sample_count !== want.sample_count) bad.push(`sample count ${got.sample_count} != ${want.sample_count}`);
  if (got.junctions.length !== want.junctions.length) bad.push("junction count");
  for (const k of ["samples", "junctions", "heights"]) got[k].forEach((row, i) => row.forEach((v, j) => { if (want[k][i] && !near(v, want[k][i][j])) bad.push(`${k}[${i}][${j}] ${v} != ${want[k][i][j]}`); }));
  if (bad.length) { console.error("lab parity FAILED:\n" + bad.join("\n")); process.exit(1); }
  console.log("lab parity ok");
}
