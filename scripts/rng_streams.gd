class_name RngStreams
# Docs: features/determinism.md — update in the same change as this file.
# Tests: tests/headless/test_rng_streams.gd, tests/headless/test_no_global_rng.gd — extend in the same change.
# The one source of randomness: every random draw in the game comes from a named stream seeded off
# `game_seed`, so a replay run with the same seed makes the same draws (the global randf()/randi() are banned).

static var game_seed: int = _boot_seed()
static var _shared := {}
static var _live := {}


# `--seed=N` after `--` on the command line pins the seed; otherwise each boot picks a random one.
static func _boot_seed() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			return arg.trim_prefix("--seed=").to_int()
	var boot := RandomNumberGenerator.new()
	boot.randomize()
	return boot.randi()


# A fresh generator for one stream; the same (game_seed, name, id) always draws the same numbers.
static func make(name: String, id := 0) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = fnv1a32("%d/%s/%d" % [game_seed, name, id])
	var key := "%s/%d" % [name, id]
	var n := 1
	while _live.has("%s#%d" % [key, n]):
		n += 1
	_live["%s#%d" % [key, n]] = weakref(rng)
	return rng


# One cached stream per name, for static callers that have nowhere to keep their own.
static func shared(name: String) -> RandomNumberGenerator:
	if not _shared.has(name):
		_shared[name] = make(name)
	return _shared[name]


# Restart every stream from a new seed. Generators already handed out keep their old seed,
# so call this before the scene that draws from them is built.
static func reseed(s: int) -> void:
	game_seed = s
	_shared.clear()
	_live.clear()


# {"name/id#n": state} for every generator still alive, for the replay trace (n counts repeat
# makes of one stream, e.g. one engine per car).
static func live_states() -> Dictionary:
	var out := {}
	for key in _live.keys():
		var rng: RandomNumberGenerator = _live[key].get_ref()
		if rng == null:
			_live.erase(key)
		else:
			out[key] = rng.state
	return out


# FNV-1a 32-bit over the UTF-8 bytes; simple enough for the Rust port to copy exactly.
static func fnv1a32(text: String) -> int:
	var h := 0x811C9DC5
	for b in text.to_utf8_buffer():
		h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
	return h
