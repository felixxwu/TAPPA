extends GutTest
# Track-turn cache: key stability, rebuild faithfulness, coverage, miss fallback.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")

const START := Vector2.ZERO
const HEAD := Vector2(0, -1)

func after_each() -> void:
	TrackCache.reset()

func test_cache_key_stable_and_input_sensitive() -> void:
	var a := TrackGenParams.of(Vector2.ZERO, Vector2(0, -1), 7, 8, 6.0)
	var b := TrackGenParams.of(Vector2.ZERO, Vector2(0, -1), 7, 8, 6.0)
	# Same inputs -> same key (deterministic, no reliance on object identity).
	assert_eq(a.cache_key("fp", "1"), b.cache_key("fp", "1"), "identical inputs -> identical key")
	# A different seed changes the key.
	var c := TrackGenParams.of(Vector2.ZERO, Vector2(0, -1), 8, 8, 6.0)
	assert_ne(a.cache_key("fp", "1"), c.cache_key("fp", "1"), "seed change -> new key")
	# The terrain fingerprint and version participate in the key.
	assert_ne(a.cache_key("fp", "1"), a.cache_key("fp2", "1"), "fingerprint participates")
	assert_ne(a.cache_key("fp", "1"), a.cache_key("fp", "2"), "version participates")

func test_cache_key_ignores_origin() -> void:
	# origin is derived (recompute_origin) and platform-float-sensitive, so it must
	# NOT change the key; every other authored input is held equal here.
	var a := TrackGenParams.of(Vector2.ZERO, Vector2(0, -1), 7, 8, 6.0)
	var b := TrackGenParams.of(Vector2(50, 50), Vector2(0, -1), 7, 8, 6.0)
	assert_eq(a.cache_key("fp", "1"), b.cache_key("fp", "1"), "origin does not affect the key")

# Rebuild faithfulness: generate live, then rebuild from that result's own pieces,
# and assert byte-identical centerline AND cells (per-piece + union). Pure logic,
# no catalogue, water off, small track -> cheap. Guards the TreeScatter dependency
# on piece["cells"].
func test_rebuild_matches_live_generation() -> void:
	var params := TrackGenParams.of(START, HEAD, 7, 8, 6.0)
	var live := await TrackGenerator.generate(params)
	assert_true(live["complete"], "precondition: live track completes")
	var rebuilt := TrackGenerator.rebuild_from_pieces(live["pieces"], params)
	assert_eq(rebuilt["complete"], live["complete"], "same complete flag")
	assert_eq(rebuilt["pieces"].size(), live["pieces"].size(), "same piece count")
	# Centerline point-for-point.
	assert_eq(rebuilt["centerline"].point_count, live["centerline"].point_count, "same point count")
	for i in live["centerline"].point_count:
		assert_eq(rebuilt["centerline"].get_point_position(i),
			live["centerline"].get_point_position(i), "centerline point %d matches" % i)
	# Cells union.
	assert_eq(rebuilt["cells"].size(), live["cells"].size(), "same cell-union size")
	for cell in live["cells"]:
		assert_true(rebuilt["cells"].has(cell), "cell %s present in rebuild" % str(cell))
	# Per-piece cells (what TreeScatter.turn_anchor consumes).
	for i in live["pieces"].size():
		assert_eq((rebuilt["pieces"][i]["cells"] as Array).size(),
			(live["pieces"][i]["cells"] as Array).size(), "piece %d cell count matches" % i)

func test_lookup_miss_returns_empty() -> void:
	TrackCache.load_from({})  # empty in-memory cache
	var params := TrackGenParams.of(START, HEAD, 7, 8, 6.0)
	var cfg := GameConfig.new()
	assert_true(TrackCache.lookup(params, cfg).is_empty(), "miss -> empty dict")

func test_lookup_hit_rebuilds_track() -> void:
	var params := TrackGenParams.of(START, HEAD, 7, 8, 6.0)
	var cfg := GameConfig.new()
	var live := await TrackGenerator.generate(params)
	assert_true(live["complete"], "precondition")
	# Seed an in-memory cache entry keyed exactly as key_for would compute it.
	var key := TrackCache.key_for(params, cfg)
	var serial: Array = []
	for p in live["pieces"]:
		serial.append({"corner": p["corner"], "flip": p["flip"], "straight": p["straight"],
			"entry_pos": [p["entry_pos"].x, p["entry_pos"].y],
			"entry_heading": [p["entry_heading"].x, p["entry_heading"].y]})
	TrackCache.load_from({ key: { "pieces": serial, "complete": true } })
	var hit := TrackCache.lookup(params, cfg)
	assert_false(hit.is_empty(), "hit -> non-empty")
	assert_eq(hit["centerline"].point_count, live["centerline"].point_count, "rebuilt centerline matches")

# In the editor/test context (OS.has_feature("editor") is true), a miss must fall
# back to live generation and still return a valid track.
func test_generate_cached_miss_falls_back_live() -> void:
	TrackCache.load_from({})  # guaranteed miss
	var params := TrackGenParams.of(START, HEAD, 7, 8, 6.0)
	var cfg := GameConfig.new()
	var res := await TrackGenerator.generate_cached(params, cfg)
	assert_true(res["complete"], "miss falls back to a valid live track")

# canonical_event_config must apply an event's terrain overrides onto a fresh base,
# so two sites building params for the same event get the same terrain fingerprint
# (the bug this fixes: _generate_event_tracks used unmodified Config.data).
func test_canonical_event_config_applies_overrides() -> void:
	var event := {"seed": 3, "turn_count": 6, "terrain_layer1_amplitude": 99.0}
	var cfg := RallySession.canonical_event_config(event)
	assert_eq(cfg.terrain_layer1_amplitude, 99.0, "event override applied to fresh base")
	# An omitted field falls back to the authored base, not a leaked prior value.
	var event2 := {"seed": 4, "turn_count": 6}
	var cfg2 := RallySession.canonical_event_config(event2)
	var base := load(Config.CONFIG_PATH) as GameConfig
	assert_eq(cfg2.terrain_layer1_amplitude, base.terrain_layer1_amplitude, "omitted field uses base")

# Lockfile contract: every rally event resolves to a key present in the committed
# data/track_cache.json with complete == true. A stale/missing entry fails here and
# in CI — rerun ./cache_tracks.sh. (By design this fails after any seed/terrain
# retune until the lockfile is regenerated; the message says how to fix it.)
func test_committed_cache_covers_every_event() -> void:
	TrackCache.reset()  # force a real load from disk
	for rally in RallyLibrary.all():
		for event in rally.get("events", []):
			var cfg := RallySession.canonical_event_config(event)
			var params := TrackGenParams.for_event(event, cfg)
			var hit := TrackCache.lookup(params, cfg)
			assert_false(hit.is_empty(),
				"rally %s seed %d missing from lockfile — run ./cache_tracks.sh" % [rally.get("id", "?"), params.seed])
			if not hit.is_empty():
				assert_true(hit["complete"], "cached track for rally %s is complete" % rally.get("id", "?"))

# The committed source_hash matches the current rally library — the same fast check
# CI runs (tools/verify_track_cache.gd), so a forgotten regeneration turns the local
# suite red before it reaches CI.
func test_committed_source_hash_is_fresh() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(TrackCache.CACHE_PATH))
	assert_eq(typeof(data), TYPE_DICTIONARY, "lockfile parses")
	assert_eq(String(data["source_hash"]), TrackCache.source_hash_of(TrackCache.all_event_keys()),
		"lockfile source_hash is stale — run ./cache_tracks.sh and commit")
