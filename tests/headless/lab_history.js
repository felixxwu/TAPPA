// Checks the level editor lab's undo history (tools/level_editor_lab.html) outside the browser: `node tests/headless/lab_history.js`.
const fs = require("fs"), vm = require("vm"), path = require("path"), assert = require("assert");
const html = fs.readFileSync(path.join(__dirname, "../../tools/level_editor_lab.html"), "utf8");
const a = html.indexOf("let history = []"), b = html.indexOf("function save()", a);
if (a < 0 || b < 0) throw new Error("lab source moved: undo history");

const ctx = vm.createContext({ structuredClone, Math, loads: 0 });
vm.runInContext(`let level = { roads: [[{ x: 0 }]], trees: [], cover: new Uint8Array(4), heightmap: new Float32Array(9) };
  function loaded() { loads++; save(); }
  ${html.slice(a, b)}
  function save() { if (!restoring) snapshot(); }`, ctx);
const run = src => vm.runInContext(src, ctx);

run("save()");
run("level.trees.push({ x: 1 }); save()");
run("level.cover[0] = 3; coverEdited = true; save()");
run("stepHistory(-1)");
assert.strictEqual(run("level.cover[0]"), 0, "undo restores the cover grid");
assert.strictEqual(run("level.trees.length"), 1);
run("level.cover[1] = 2"); // painting the restored level must not reach back into the history
run("stepHistory(-1)");
assert.strictEqual(run("level.trees.length"), 0, "undo restores the trees");
assert.strictEqual(run("level.cover[1]"), 0);
run("stepHistory(-1)");
assert.strictEqual(run("historyAt"), 0, "undo stops at the oldest step");
run("stepHistory(1); stepHistory(1)");
assert.strictEqual(run("level.cover[0]"), 3, "redo brings the cover back");
assert.strictEqual(run("history[historyAt].heightmap"), run("level.heightmap"), "the height grid is shared, not copied");
run("stepHistory(-1); level.roads[0][0].x = 5; save(); stepHistory(1)");
assert.strictEqual(run("level.roads[0][0].x"), 5, "a new edit drops the redo steps");
assert.strictEqual(run("history.length"), 3);
console.log("lab history ok");
