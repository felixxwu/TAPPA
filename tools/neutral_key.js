#!/usr/bin/env node
// Prints a level's neutral bake key, the name its .bake.bin is published under, without needing Godot.
// Usage: node tools/neutral_key.js [tools/levels/<name>.json] | --self-test [save]
// It hashes the same content as LevelBake.key_of, so the two keys go stale together, but it isn't the same
// hash: Godot formats numbers differently from JavaScript when it re-stringifies the save.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const root = path.join(__dirname, "..");
const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8");

function constOf(src, name, file) {
	const m = src.match(new RegExp(`const ${name}\\s*:=\\s*(\\[[^\\]]*\\]|\\d+)`));
	if (!m) throw new Error(`no const ${name} in ${file}`);
	return m[1].startsWith("[") ? [...m[1].matchAll(/"([^"]*)"/g)].map((x) => x[1]) : Number(m[1]);
}

const bakeSrc = read("scripts/level_bake.gd");
const KEY_IGNORES = constOf(bakeSrc, "KEY_IGNORES", "scripts/level_bake.gd");
const BAKE_VERSION = constOf(bakeSrc, "BAKE_VERSION", "scripts/level_bake.gd");
const FORMAT = constOf(read("scripts/neutral_file.gd"), "FORMAT", "scripts/neutral_file.gd");

function keyOf(save) {
	const d = { ...save };
	for (const k of KEY_IGNORES) delete d[k];
	const md5 = crypto.createHash("md5").update(JSON.stringify(d)).digest("hex");
	return `${md5}-v${BAKE_VERSION}-n${FORMAT}`;
}

function defaultSave() {
	return read("scripts/game_config.gd").match(/var level_path.*"res:\/\/([^"]*)"/)[1];
}

function selfTest(savePath) {
	const save = JSON.parse(fs.readFileSync(savePath, "utf8"));
	const base = keyOf(save);
	const fail = (msg) => { console.error(`neutral_key self-test FAILED: ${msg}`); process.exit(1); };
	for (const k of KEY_IGNORES) {
		if (keyOf({ ...save, [k]: "changed" }) !== base) fail(`changing ${k} changed the key`);
	}
	const moved = structuredClone(save);
	const node = moved.roads?.[0]?.[0];
	if (!node) fail(`${savePath} has no road node to move`);
	node.x += 1;
	if (keyOf(moved) === base) fail("moving a road node kept the key");
	console.log(`neutral_key self-test ok (${KEY_IGNORES.length} ignored keys, ${base})`);
}

const args = process.argv.slice(2);
if (args[0] === "--self-test") selfTest(args[1] || path.join(root, defaultSave()));
else console.log(keyOf(JSON.parse(fs.readFileSync(args[0] || path.join(root, defaultSave()), "utf8"))));
