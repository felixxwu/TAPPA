class_name OpponentCache
extends RefCounted
# Committed lockfile of precomputed rally opponent fields (data/opponent_cache.json).
# lookup() returns the deterministic field RallyLibrary.generate_opponent_field would
# produce, without running its ~30-45 lap-time simulations. Depends on the track
# cache (its fingerprint folds the track lockfile's source_hash). See
# docs/superpowers/specs/2026-07-21-opponent-field-cache-design.md.

const CACHE_PATH := "res://data/opponent_cache.json"
# Manual escape hatch: bump for genuine algorithm changes not captured by the
# auto-folded fingerprints below — the LapTimeModel physics (ROLLING_G, SAMPLE_STEP_M,
# the sim passes) or the field-assembly logic itself.
#   "2" — opponents gained engine swaps (features/rally-roster.md): the field is
#         drawn from car+engine combos WITHOUT replacement, so both the entry shape
#         (a new `engine_id`) and the rng draw order changed. The auto-folded inputs
#         below cover EngineLibrary DATA but not this generator LOGIC, hence the bump.
#   "3" — that draw became WEIGHTED toward modest swaps (RallyLibrary.swap_weight), which
#         changes which combos come out for the same seed. The spread CONSTANT is folded
#         in below, but the weighting itself is logic, so it needs the bump.
#   "4" — wreck_progress is now quantised at generation so it round-trips through JSON
#         exactly (a raw double did not, so a cached field could differ from a live one
#         in the last bits). Generation changed, so the bake must be redone.
# Bumped to "5" for the rival-ghost skill_k seeds (features/rival-ghost.md): entries
# written before that carry no seed, and a stale hit would silently cost every stage a full
# re-solve instead of the one-sweep validation the seed exists to enable.
const CACHE_VERSION := "5"

static var _entries: Dictionary = {}
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_entries = {}
	if not FileAccess.file_exists(CACHE_PATH):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CACHE_PATH))
	if typeof(data) == TYPE_DICTIONARY and data.has("entries"):
		_entries = data["entries"]


static func load_from(entries: Dictionary) -> void:
	_entries = entries
	_loaded = true


static func reset() -> void:
	_entries = {}
	_loaded = false
	reset_cache()


static var _global_fp := ""
static var _global_fp_key := ""


# Inputs outside the rally dict that shift any field's times. Uses the AUTHORED base
# config (never the mutable Config.data session copy) so the runtime key can't drift
# from the generator's.
#
# Memoised: lookup() calls this once per rally start, and the uncached form parses the
# full 248 KB track lockfile, load()s the config resource and SHA-256s the whole car +
# engine catalogue — 50-150 ms of a menu transition on wasm. Every remaining input is a
# `const` (CARS / ENGINES / the RallyLibrary constants), so the only things that can
# change WITHIN a process are the two files, and the memo key stats both: the track
# lockfile via TrackCache.stored_source_hash() (itself modified-time keyed) and the
# config resource via its modified time. That matters for the generators, which rewrite
# those files in-process — a memo that never invalidated could bake a stale fingerprint
# into a regenerated lockfile. reset_cache() is the explicit belt-and-braces seam.
static func global_fingerprint() -> String:
	var track_hash := TrackCache.stored_source_hash()
	var memo_key := "%s|%d" % [track_hash, int(FileAccess.get_modified_time(Config.CONFIG_PATH))]
	if memo_key == _global_fp_key and _global_fp != "":
		return _global_fp
	var base := load(Config.CONFIG_PATH) as GameConfig
	var catalogue := str(CarLibrary.CARS) + str(EngineLibrary.ENGINES) + str(CarLibrary.TORQUE_POWER_FALLOFF)
	# Weather folds in as ONE hash of the whole weather table plus every config value
	# it names (WeatherLibrary.fingerprint), not as a per-condition field in this
	# format string. Listing them one at a time meant editing this line for every new
	# condition forever, and forgetting once would silently serve stale rival times;
	# now adding or retuning any condition re-keys every field automatically.
	var grip := "%.6f|%.6f|%s" % [base.gravel_grip, base.tarmac_grip, WeatherLibrary.fingerprint(base)]
	# Auto-folded field-gen constants + name pool: edits invalidate without a manual bump.
	var consts := str([
		RallyLibrary.FIELD_MIN, RallyLibrary.FIELD_MAX,
		RallyLibrary.PACE_FAST_BASE, RallyLibrary.PACE_SLOW_BASE,
		RallyLibrary.PACE_FAST_STEP, RallyLibrary.PACE_SLOW_STEP,
		RallyLibrary.PACE_EVENT_NOISE, RallyLibrary.PACE_MIN_FLOOR,
		RallyLibrary.OPPONENT_WRECK_CHANCE, RallyLibrary.OPPONENT_SWAP_PW_SPREAD,
	]) + str(RallyLibrary.RIVAL_NAMES)
	var parts := "v%s|%s|%s|%s|%s" % [CACHE_VERSION, track_hash, catalogue, grip, consts]
	_global_fp = parts.sha256_text().substr(0, 16)
	_global_fp_key = memo_key
	return _global_fp


# Drop the memoised fingerprint (and the track cache's memoised source hash). Tests and
# any in-process regeneration path should call this after mutating the inputs.
static func reset_cache() -> void:
	_global_fp = ""
	_global_fp_key = ""
	TrackCache.reset_source_hash_cache()


# Per-rally content hash: captures difficulty (pace band), restriction (eligible pool),
# the events (per-event surface_mix drives grip), and prize_car (a car-unlock rally fields
# a ONE-MAKE grid of the car it awards, so the prize IS the field) — none of which are
# track-shape determinants, so none are in the track cache's source_hash.
#
# Hashes ONLY those determinants, by name. It used to hash `str(rally)` — the whole dict —
# which quietly folded in every cosmetic field too, so renaming a rally or nudging its map
# pin by a thousandth invalidated its cached opponent field and forced a rebake for a
# change that cannot move a single lap time. That matters much more now than it did: with
# map exploration, `map_pos` is progression data that gets re-fitted whenever the roster
# changes (tools/fit_map_pins.py), so whole-dict hashing meant a full rebake every time.
#
# Keep this list in step with what generate_opponent_field actually reads. Adding a field
# that DOES change the field and forgetting it here is the dangerous direction: the cache
# would serve a stale line-up rather than miss and regenerate.
const FIELD_DETERMINANTS := ["difficulty", "restriction", "events", "prize_car"]


static func rally_content_fingerprint(rally: Dictionary) -> String:
	var determinants: Array = []
	for key in FIELD_DETERMINANTS:
		determinants.append(rally.get(key))
	return str(determinants).sha256_text().substr(0, 16)


static func key_for(rally: Dictionary) -> String:
	return "%s|%s|%s" % [String(rally.get("id", "")), rally_content_fingerprint(rally), global_fingerprint()]


static func lookup(rally: Dictionary) -> Array:
	_ensure_loaded()
	var key := key_for(rally)
	if not _entries.has(key):
		return []
	return deserialize_field(_entries[key])


static func all_rally_keys() -> Array:
	var keys: Array = []
	for rally in RallyLibrary.all():
		keys.append(key_for(rally))
	return keys


# Field <-> JSON. Everything round-trips as-is except numbers (JSON parses them as
# floats), so deserialize restores int/bool types — a round-tripped field must equal
# a freshly generated one field-for-field.
static func serialize_field(field: Array) -> Array:
	return field.duplicate(true)


# JSON gives every number back as a float; normalise a list of them.
static func _floats(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for v in raw:
			out.append(float(v))
	return out


static func deserialize_field(raw: Array) -> Array:
	var out: Array = []
	for r in raw:
		var times: Array = []
		for tv in r.get("event_times_ms", []):
			times.append(int(tv))
		out.append({
			"name": String(r.get("name", "")),
			"car_id": String(r.get("car_id", "")),
			# The rival's fitted engine (features/rally-roster.md). This list is a
			# WHITELIST: a field the generator emits but this omits is dropped on the way
			# out of the cache. Not silently, though — test_opponent_cache's
			# test_field_survives_json_round_trip compares whole dicts, so an omission fails
			# there. Add any new rival field here.
			"engine_id": String(r.get("engine_id", "")),
			"car_name": String(r.get("car_name", "")),
			"event_times_ms": times,
			"dnf": bool(r.get("dnf", false)),
			"combined_ms": int(r.get("combined_ms", 0)),
			"wreck_event": int(r.get("wreck_event", -1)),
			"wreck_progress": float(r.get("wreck_progress", 0.0)),
			"wreck_side": float(r.get("wreck_side", 1.0)),
			# Per-event rival-ghost pace seeds. Absent in a cache file written before this
			# field existed, which must stay readable — an empty list means "no seed" and the
			# runtime solves from scratch.
			"skill_k": _floats(r.get("skill_k", [])),
		})
	return out
