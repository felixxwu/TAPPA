extends GutTest
# Opponent-field cache: serialization faithfulness, miss fallback, coverage/freshness.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

const START := Vector2.ZERO
const HEAD := Vector2(0, -1)

func after_each() -> void:
	OpponentCache.reset()
	CarFixtures.restore()

# A field survives a real JSON round-trip field-for-field (guards the int/bool type
# restore that JSON's float parsing would otherwise break). Synthetic roster + rally +
# tracks — no dependency on the shipped catalogue, no pinned tunable value.
func test_field_survives_json_round_trip() -> void:
	CarFixtures.install()
	var track := await TrackGenerator.generate(TrackGenParams.of(START, HEAD, 7, 8, 6.0))
	assert_true(track["complete"], "precondition: synthetic track generates")
	var events := [{"seed": 7}, {"seed": 7}, {"seed": 7}]
	var results := [track, track, track]
	var rally := {"id": "synth", "difficulty": 2, "restriction": {}, "events": events}
	var field := RallyLibrary.generate_opponent_field(rally, results, events)
	assert_false(field.is_empty(), "precondition: a field was generated")
	# Real JSON round-trip through the cache serialisation.
	var key := OpponentCache.key_for(rally)
	var doc := { "entries": { key: OpponentCache.serialize_field(field) } }
	# 4-arg form: indent, sort_keys, full_precision=true (the 3rd arg is sort_keys,
	# NOT full_precision — a random float like wreck_progress needs full precision to
	# round-trip). Matches how the generator writes the file.
	var parsed: Variant = JSON.parse_string(JSON.stringify(doc, "", true, true))
	OpponentCache.load_from(parsed["entries"])
	var got := OpponentCache.lookup(rally)
	assert_eq(got.size(), field.size(), "same rival count")
	for i in field.size():
		assert_eq(got[i], field[i], "rival %d round-trips field-for-field" % i)

func test_lookup_miss_returns_empty() -> void:
	OpponentCache.load_from({})
	var rally := {"id": "nope", "difficulty": 1, "restriction": {}, "events": [{"seed": 1}]}
	assert_true(OpponentCache.lookup(rally).is_empty(), "miss -> empty array")

# A seeded in-memory hit is returned by lookup (the path start_rally relies on).
func test_seeded_hit_is_returned() -> void:
	CarFixtures.install()
	var track := await TrackGenerator.generate(TrackGenParams.of(START, HEAD, 7, 8, 6.0))
	var events := [{"seed": 7}, {"seed": 7}, {"seed": 7}]
	var rally := {"id": "synth2", "difficulty": 3, "restriction": {}, "events": events}
	var field := RallyLibrary.generate_opponent_field(rally, [track, track, track], events)
	OpponentCache.load_from({ OpponentCache.key_for(rally): OpponentCache.serialize_field(field) })
	var got := OpponentCache.lookup(rally)
	assert_eq(got.size(), field.size(), "seeded field is returned by lookup")
	assert_eq(String(got[0]["name"]), String(field[0]["name"]), "first rival matches")

# Lockfile contract: every rally resolves to a key present in the committed
# data/opponent_cache.json, and the stored source_hash matches the current library.
# A stale/missing entry fails here and in CI — rerun ./cache_all.sh.
func test_committed_cache_covers_every_rally() -> void:
	OpponentCache.reset()  # force a real load from disk
	for rally in RallyLibrary.all():
		var got := OpponentCache.lookup(rally)
		assert_false(got.is_empty(),
			"rally %s missing from opponent lockfile — run ./cache_all.sh" % rally.get("id", "?"))

func test_committed_source_hash_is_fresh() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(OpponentCache.CACHE_PATH))
	assert_eq(typeof(data), TYPE_DICTIONARY, "lockfile parses")
	assert_eq(String(data["source_hash"]), TrackCache.source_hash_of(OpponentCache.all_rally_keys()),
		"opponent lockfile source_hash is stale — run ./cache_all.sh and commit")
