class_name TrackCache
extends RefCounted
# Committed lockfile of precomputed track-turn layouts (data/track_cache.json).
# lookup() rebuilds a full track from the stored pieces via
# TrackGenerator.rebuild_from_pieces — no DFS search. See
# docs/superpowers/specs/2026-07-21-track-turn-cache-design.md.

const CACHE_PATH := "res://data/track_cache.json"
# Bump when the generator's shape-affecting constants or CornerLibrary.CORNERS
# change (otherwise a stale cache would replay pieces the search never revalidated).
const CACHE_VERSION := "1"

static var _entries: Dictionary = {}
static var _loaded := false
static var _corner_fp := ""


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


# Test seam: inject an in-memory cache without touching disk.
static func load_from(entries: Dictionary) -> void:
	_entries = entries
	_loaded = true


# Test seam: force a reload from disk on next lookup.
static func reset() -> void:
	_entries = {}
	_loaded = false


static func terrain_fingerprint(cfg: GameConfig) -> String:
	var parts := PackedStringArray()
	for v in cfg.terrain_layers():
		parts.append("%.6f,%.6f" % [v.x, v.y])
	return "|".join(parts)


# Short fingerprint of the corner shape library, folded into the key so a corner
# shape edit auto-invalidates the cache without a manual CACHE_VERSION bump.
static func _corner_fingerprint() -> String:
	if _corner_fp == "":
		_corner_fp = str(CornerLibrary.CORNERS).sha256_text().substr(0, 12)
	return _corner_fp


# Version segment of the key: manual CACHE_VERSION + auto fingerprints of the corner
# library and the generator's shape/search constants, so a corner or generator-constant
# edit auto-invalidates the cache. Only genuine algorithm changes (control flow the
# constants don't capture) still need a manual CACHE_VERSION bump.
static func _version_tag() -> String:
	return "%s:%s:%s" % [CACHE_VERSION, _corner_fingerprint(), TrackGenerator.constants_fingerprint()]


static func key_for(params: TrackGenParams, cfg: GameConfig) -> String:
	return params.cache_key(terrain_fingerprint(cfg), _version_tag())


static func lookup(params: TrackGenParams, cfg: GameConfig) -> Dictionary:
	_ensure_loaded()
	var key := key_for(params, cfg)
	if not _entries.has(key):
		return {}
	var entry: Dictionary = _entries[key]
	return TrackGenerator.rebuild_from_pieces(_deserialize_pieces(entry.get("pieces", [])), params)


# The cache key of every rally event, resolved through the canonical event config —
# the exact keys the lockfile is stored under. Used to fingerprint the whole rally
# library's generation inputs WITHOUT generating any track (the hash-based CI check).
static func all_event_keys() -> Array:
	var keys: Array = []
	for rally in RallyLibrary.all():
		for event in rally.get("events", []):
			var cfg := RallySession.canonical_event_config(event)
			var params := TrackGenParams.for_event(event, cfg)
			keys.append(key_for(params, cfg))
	return keys


# Stable fingerprint of a set of cache keys (order-independent). Each key already
# encodes an event's full generation determinants + CACHE_VERSION, so the hash of
# the sorted key set captures every input that affects any generated track. CI
# compares this against the lockfile's stored source_hash — a stale library fails
# without regenerating a single track.
static func source_hash_of(keys: Array) -> String:
	var sorted := keys.duplicate()
	sorted.sort()
	return "|".join(PackedStringArray(sorted)).sha256_text()


# The source_hash committed in the track lockfile (not recomputed). Lets dependent
# caches (OpponentCache) fold the track cache's state into their key cheaply.
static func stored_source_hash() -> String:
	if not FileAccess.file_exists(CACHE_PATH):
		return ""
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CACHE_PATH))
	if typeof(data) == TYPE_DICTIONARY:
		return String(data.get("source_hash", ""))
	return ""


static func _deserialize_pieces(raw: Array) -> Array:
	var out: Array = []
	for r in raw:
		out.append({
			"corner": String(r["corner"]),
			"flip": bool(r["flip"]),
			"straight": float(r["straight"]),
			"entry_pos": Vector2(float(r["entry_pos"][0]), float(r["entry_pos"][1])),
			"entry_heading": Vector2(float(r["entry_heading"][0]), float(r["entry_heading"][1])),
		})
	return out
