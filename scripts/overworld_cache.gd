class_name OverworldCache
extends RefCounted

# On-disk, random-access cache of generated overworld terrain chunks
# (docs/superpowers/specs/2026-08-17-overworld-hq-design.md -> "The cache on disk").
#
# Two files under user://overworld/:
#
#   index.dat   format version, the invalidation key, and a chunk-coord -> (offset,
#               length) table. Rewritten WHOLE via index.dat.tmp + rename.
#   chunks.dat  per-chunk records, APPEND-ONLY, each record individually compressed
#               so a single seek + read still resolves one chunk. Never rewritten
#               wholesale (it reaches ~83 MB at 4 km).
#
# Write scheme is append-then-swap: append + flush the record to chunks.dat first,
# then swap the index in. A crash between the two leaves an orphaned data record and
# a stale index — which reads as a MISS and is simply regenerated.
#
# Every failure mode degrades to a miss. A bad magic / length / CRC32 is a miss, not
# an error. An I/O failure disables THIS cache instance for the session (`active()`
# goes false, one push_warning) and never, ever touches `Save.save_disabled` or the
# profile write path — a cache fault must not cost the player their progress.

# ---------------------------------------------------------------------------
# Format
# ---------------------------------------------------------------------------

## Bumped whenever the on-disk bytes change meaning. It is folded into the
## invalidation key, so a bump alone invalidates every cached chunk.
const FORMAT_VERSION := 2

## Per-record magic, "OWC1" little-endian. Guards against reading an offset that
## points at the middle of some other record (or at garbage).
const RECORD_MAGIC := 0x3143574F

## Record header size in bytes: magic u32 + payload_len u32 + raw_len u32 + crc32 u32.
const HEADER_BYTES := 16

## Payload (post-decompression) layout version. Slice-4 fields — the per-chunk
## scatter list and the region byte — get appended as new sections behind a bump of
## this AND of FORMAT_VERSION; the reader below tolerates trailing unknown bytes, so
## a bump is only needed when an EXISTING section changes.
const PAYLOAD_VERSION := 2

## Float channels per vertex in the optional SURFACE section: road weight (COLOR.a), tarmac
## weight (UV2.x) and region rank (UV2.y). See _encode_payload.
const SURFACE_CHANNELS := 3

## Fixed-point scale for cached heights: 0.01 m per int16 step, i.e. +/-327 m.
const HEIGHT_SCALE := 100.0

## Hard ceiling on chunks.dat. Past this the cache stops writing (reads keep working)
## rather than filling the player's disk. ~83 MB is the design figure for a 4 km world.
const MAX_TOTAL_BYTES := 160 * 1024 * 1024

const DIR_PATH := "user://overworld"
const INDEX_PATH := "user://overworld/index.dat"
const INDEX_TMP_PATH := "user://overworld/index.dat.tmp"
const CHUNKS_PATH := "user://overworld/chunks.dat"

## TEST REDIRECT. While non-empty, every path below is rebased onto this directory instead of
## `DIR_PATH`, so a test can exercise the real read/write/wipe paths without touching the
## developer's own cache. This is not a nicety: `wipe()` deletes the whole directory, so before
## this existed a suite run destroyed the player's precomputed map (tens of MB) and forced a
## re-precompute on their next launch. Same reasoning as `SaveManager.test_sandbox_path`.
##
## Static so a test can set it before constructing anything; always restore it in teardown.
static var dir_override := ""


## The directory the cache actually uses.
static func dir_path() -> String:
	return dir_override if dir_override != "" else DIR_PATH


## `name` inside the effective directory.
static func file_path(name: String) -> String:
	return dir_path() + "/" + name

const _COMPRESSION := FileAccess.COMPRESSION_ZSTD

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

# coord -> {"offset": int, "length": int}. `length` is the FULL record length
# (header + compressed payload), so a mismatch against the header is detectable.
var _index: Dictionary = {}
# The key this cache was opened with. Stored in index.dat; a mismatch wipes.
var _key: int = 0
# False once open() failed or an I/O fault was detected: every read misses and every
# write refuses for the rest of the session. Deliberately sticky per INSTANCE only.
var _active: bool = false
# Set when MAX_TOTAL_BYTES was hit — reads still work, writes stop.
var _full: bool = false
# BATCHED INDEX WRITES. `write` normally rewrites the WHOLE index after each record, which is
# fine for the odd chunk but quadratic across a bulk pass — and the progressive precompute
# (Overworld._precompute_map) now writes in many smaller passes instead of one big one, so it
# would pay that rewrite far more often. Between `begin_batch()` and `end_batch()` the index is
# only updated in MEMORY and flushed once.
#
# Safe because it weakens nothing that was guaranteed: a record is appended and flushed to
# chunks.dat BEFORE it is named in the index, so an unflushed name is exactly the pre-existing
# crash case — an orphaned record that reads as a miss and is regenerated. Only the index write
# is deferred; never the data.
var _batch_depth: int = 0
var _index_dirty: bool = false
# The append/read handle on chunks.dat, held open for the session.
var _chunks: FileAccess = null
# Byte length of chunks.dat as we believe it to be (== the next append offset).
var _bytes: int = 0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

## Open (or create) the cache and validate it against `key` — see invalidation_key().
## On a key mismatch, a missing/unreadable index, or a format-version change BOTH
## files are wiped to zero bytes before anything is written. Returns active().
func open(key: int) -> bool:
	_index = {}
	_key = key
	_full = false
	_active = true
	_batch_depth = 0
	_index_dirty = false
	if not DirAccess.dir_exists_absolute(dir_path()):
		var mk := DirAccess.make_dir_recursive_absolute(dir_path())
		if mk != OK:
			_fail("cannot create %s (error %d)" % [dir_path(), mk])
			return false
	var loaded := _read_index()
	if not _active:
		return false
	if not loaded:
		# No usable index (absent, truncated, wrong version, wrong key). Anything in
		# chunks.dat is unreachable, so drop both files rather than leaking ~83 MB.
		wipe()
		if not _active:
			return false
	if not _open_chunks():
		return false
	# An index that points past the end of the data file cannot be trusted at all.
	for coord in _index:
		var e: Dictionary = _index[coord]
		if int(e["offset"]) + int(e["length"]) > _bytes:
			_index = {}
			wipe()
			break
	return _active


## Close the file handles. The cache can be re-opened afterwards; the on-disk bytes
## are untouched.
func close() -> void:
	if _chunks != null:
		_chunks.close()
		_chunks = null


## Delete both files and forget the index. Used on invalidation, and callable
## directly (e.g. a "clear cache" action). Keeps the instance active.
func wipe() -> void:
	close()
	_index = {}
	_index_dirty = false
	_bytes = 0
	_full = false
	for path in [file_path("index.dat"), file_path("index.dat.tmp"), file_path("chunks.dat")]:
		if not FileAccess.file_exists(path):
			continue
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			# Could not delete — truncate to zero instead, which is just as good for
			# correctness and does not leave the stale bytes readable.
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f == null:
				_fail("cannot clear %s (remove error %d, open error %d)"
					% [path, err, FileAccess.get_open_error()])
				return
			f.close()


## False once this cache has been disabled (failed open, or a detected I/O fault).
## Every read then misses and every write refuses; nothing else in the game changes.
func active() -> bool:
	return _active


## Current size of chunks.dat in bytes (0 when inactive/empty).
func size_bytes() -> int:
	return _bytes

# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

## True when a record for `coord` is INDEXED. It can still fail integrity checks on
## read, so has() is a hint — read() is the authority.
func has(coord: Vector2i) -> bool:
	return _active and _index.has(coord)


## Read one chunk. Returns {} on any miss, and on ANY corruption (bad magic, length
## disagreeing with the index, CRC32 mismatch, failed decompression, wrong element
## count) — never an error, never a push_error. Keys match what compute_chunk_data
## produces, so the caller can splice the result straight in:
##
##   "heights"  PackedFloat32Array, SAMPLES^2, already quantised (see snap_heights)
##   "l0_light" PackedByteArray, SAMPLES^2 x RGB8, TerrainLod.decode_lights-ready
##   "surface"  PackedFloat32Array, SAMPLES^2 x 3 — (road_weight, tarmac_weight, region_rank)
##              per vertex. PRESENT ONLY when the record carries the section; absent means the
##              reader must recompute those channels (see _encode_payload).
func read(coord: Vector2i) -> Dictionary:
	if not _active or _chunks == null:
		return {}
	var entry: Variant = _index.get(coord)
	if entry == null:
		return {}
	var offset: int = int(entry["offset"])
	var length: int = int(entry["length"])
	if offset < 0 or length <= HEADER_BYTES or offset + length > _bytes:
		return {}
	_chunks.seek(offset)
	var header := _chunks.get_buffer(HEADER_BYTES)
	if header.size() != HEADER_BYTES:
		return {}
	if header.decode_u32(0) != RECORD_MAGIC:
		return {}
	var payload_len := int(header.decode_u32(4))
	var raw_len := int(header.decode_u32(8))
	var want_crc := int(header.decode_u32(12))
	if payload_len <= 0 or raw_len <= 0:
		return {}
	# The index's length and the header's must agree: a torn append that happens to
	# be plausible in one place rarely is in both.
	if HEADER_BYTES + payload_len != length:
		return {}
	var payload := _chunks.get_buffer(payload_len)
	if payload.size() != payload_len:
		return {}
	# The whole point of the CRC: corruption that PRESERVES the length would
	# otherwise decode into plausible int16 heights and silently corrupt geometry.
	if _crc32(payload) != want_crc:
		return {}
	var raw := payload.decompress(raw_len, _COMPRESSION)
	if raw.size() != raw_len:
		return {}
	return _decode_payload(raw)

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

## Append one chunk record and swap in a fresh index. Returns true only when the
## record is durably on disk AND the index naming it has been renamed into place.
##
## Refuses (returning false, without disabling the cache) when:
##   - the cache is inactive or the size ceiling has been reached,
##   - `heights` is empty,
##   - `lights` is EMPTY. A light-less record can never be distinguished from a
##     valid one later and the invalidation key can never discard it, so it must
##     not be written at all — capture the encoded light at generation time.
##
## `heights` should already have been through snap_heights() so that the cached
## bytes, the live collision shape, the bilinear height query and the mesh vertices
## all derive from identical numbers; write() quantises defensively regardless.
##
## `surface` is OPTIONAL and is the read-side speed-up (see _encode_payload): SAMPLES² x 3 f32s,
## interleaved (road_weight, tarmac_weight, region_rank), which lets a read skip
## `_apply_road_carve` + `_apply_region_blend` entirely. A wrong-sized array is dropped rather
## than written — the fallback (recompute on read) is exact, so a bad surface must never be able
## to poison a record whose heights and light are fine.
func write(coord: Vector2i, heights: PackedFloat32Array, lights: PackedByteArray,
		surface: PackedFloat32Array = PackedFloat32Array()) -> bool:
	if not _active or _chunks == null:
		return false
	if _full:
		return false
	if heights.is_empty():
		push_warning("OverworldCache: refusing to cache chunk %s — no heights" % coord)
		return false
	if lights.is_empty():
		push_warning("OverworldCache: refusing to cache chunk %s — the baked light is "
			% coord + "empty (it must be captured at generation time)")
		return false
	var kept := surface
	if not kept.is_empty() and kept.size() != heights.size() * SURFACE_CHANNELS:
		push_warning("OverworldCache: chunk %s surface channels are %d, wanted %d — storing the "
			% [coord, kept.size(), heights.size() * SURFACE_CHANNELS]
			+ "record without them (the reader recomputes)")
		kept = PackedFloat32Array()
	var raw := _encode_payload(heights, lights, kept)
	var payload := raw.compress(_COMPRESSION)
	if payload.is_empty():
		push_warning("OverworldCache: chunk %s failed to compress" % coord)
		return false
	var record := PackedByteArray()
	record.resize(HEADER_BYTES)
	record.encode_u32(0, RECORD_MAGIC)
	record.encode_u32(4, payload.size())
	record.encode_u32(8, raw.size())
	record.encode_u32(12, _crc32(payload))
	record.append_array(payload)
	var offset := _bytes
	if offset + record.size() > MAX_TOTAL_BYTES:
		_full = true
		push_warning("OverworldCache: size ceiling reached (%d bytes) — no further "
			% MAX_TOTAL_BYTES + "chunks will be cached this session")
		return false
	# 1. Append + flush the data record.
	_chunks.seek_end()
	_chunks.store_buffer(record)
	_chunks.flush()
	# store_buffer returns nothing, so the error state and the resulting file size are
	# the only detection available.
	var err := _chunks.get_error()
	if err != OK and err != ERR_FILE_EOF:
		_fail("append for chunk %s failed (error %d)" % [coord, err])
		return false
	var grown := _chunks.get_length()
	if grown < offset + record.size():
		_fail("append for chunk %s short-wrote (%d bytes, wanted %d)"
			% [coord, grown - offset, record.size()])
		return false
	_bytes = grown
	# 2. Only now name it in the index. A crash before this leaves the record
	#    orphaned, which reads as a miss.
	var previous: Variant = _index.get(coord)
	_index[coord] = {"offset": offset, "length": record.size()}
	if _batch_depth > 0:
		# Named in memory only; `end_batch`/`flush_index` puts it on disk. See _batch_depth.
		_index_dirty = true
		return true
	if not _write_index():
		# Roll the in-memory index back to whatever the on-disk index still says.
		if previous == null:
			_index.erase(coord)
		else:
			_index[coord] = previous
		return false
	return true

## Start a batched-index region: every `write` until the matching `end_batch()` updates the
## index in memory only. Nestable. See the `_batch_depth` note — the DATA is still appended and
## flushed per chunk, so an interrupted batch loses nothing but the naming of its last records.
func begin_batch() -> void:
	_batch_depth += 1


## Close one batched-index region and, at depth zero, flush the index if anything changed.
## Returns false only if the flush itself failed (which deactivates the cache).
func end_batch() -> bool:
	_batch_depth = maxi(_batch_depth - 1, 0)
	if _batch_depth > 0:
		return true
	return flush_index()


## Write the index now if a batched write has dirtied it. Safe (and free) to call at any time —
## a long batch calls it periodically so a crash cannot cost the whole pass.
func flush_index() -> bool:
	if not _index_dirty:
		return true
	if not _active or _chunks == null:
		return false
	if not _write_index():
		return false
	_index_dirty = false
	return true


# ---------------------------------------------------------------------------
# Quantisation (static, pure)
# ---------------------------------------------------------------------------

## Heights -> int16 fixed-point steps at HEIGHT_SCALE, clamped to the int16 range.
static func quantise_heights(heights: PackedFloat32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(heights.size())
	for i in heights.size():
		out[i] = clampi(roundi(heights[i] * HEIGHT_SCALE), -32768, 32767)
	return out


## Inverse of quantise_heights.
static func dequantise_heights(steps: PackedInt32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(steps.size())
	for i in steps.size():
		out[i] = float(steps[i]) / HEIGHT_SCALE
	return out


## Snap a live height grid onto the cache's quantisation lattice, for the caller to
## write BACK into the grid before building collision, the height query or the mesh.
## Idempotent: snapping an already-snapped grid returns the identical values, so a
## cache round-trip is exact rather than approximate.
static func snap_heights(heights: PackedFloat32Array) -> PackedFloat32Array:
	return dequantise_heights(quantise_heights(heights))

# ---------------------------------------------------------------------------
# Invalidation key (static, pure)
# ---------------------------------------------------------------------------

## Hash of everything the cached bytes derive from. Pure and instance-free, so the
## caller can compute it before deciding whether to open the cache at all. Retuning
## any input changes the key, and open() then wipes both files.
##
## `texture_tile_per_meter` lives on TerrainManager (not on GameConfig), and the map
## image path defaults to the shipped world map, so both are parameters.
static func invalidation_key(cfg: GameConfig, texture_tile_per_meter: float,
		map_image_path: String = RegionLibrary.DEFAULT_MAP_IMAGE) -> int:
	var parts := PackedStringArray()
	parts.append("v=%d/%d" % [FORMAT_VERSION, PAYLOAD_VERSION])
	# Grid geometry: the record is SAMPLES^2 only because CHUNK_M / CELL_M makes it so.
	parts.append("grid=%.4f,%.4f,%d" % [TerrainManager.CHUNK_M, TerrainManager.CELL_M,
		TerrainManager.SAMPLES])
	parts.append("hscale=%.4f" % HEIGHT_SCALE)
	parts.append("lscale=%.4f" % TerrainLod.LIGHT_ENCODE_SCALE)
	# World extent and the noise the heights come from.
	parts.append("world=%.4f" % _num(cfg, "overworld_size_m", 4000.0))
	# The OVERWORLD's height noise, not the stages'. These must be the same two inputs
	# overworld.gd hands the TerrainManager (overworld_terrain_seed /
	# overworld_terrain_layers) — key one world's ground on another world's parameters and
	# the cache silently serves heights nothing generated.
	parts.append("seed=%d" % int(_num(cfg, "overworld_terrain_seed", 0.0)))
	var layers: Array[Vector2] = (cfg.overworld_terrain_layers() if cfg != null
		else ([] as Array[Vector2]))
	for layer in layers:
		parts.append("layer=%.5f,%.5f" % [layer.x, layer.y])
	# Cliff knobs — they feed the BAKED heights, so they are part of the bytes.
	parts.append("cliff=%s,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f" % [
		str(bool(_num(cfg, "cliff_enabled", 1.0) != 0.0)),
		_num(cfg, "cliff_wavelength_m", 0.0),
		_num(cfg, "cliff_gain", 0.0),
		_num(cfg, "cliff_max_height_m", 0.0),
		_num(cfg, "cliff_run_m", 0.0),
		_num(cfg, "cliff_fade_m", 0.0),
		_num(cfg, "cliff_open_radius_m", 0.0),
		_num(cfg, "cliff_amount", 0.0),
	])
	parts.append("uv=%.5f" % texture_tile_per_meter)
	# THE BAKED LIGHT. A record holds TWO generator products, not one: heights AND the
	# per-vertex light (`l0_light`, written by _encode_payload from
	# TerrainManager._light_from_neighbours). Everything above this line covers the heights;
	# these five are the light's entire input set, pushed by GameConfig.apply_terrain_light.
	#
	# Omitting them was a real hole, and a silent one: retune the sun angle or the ambient
	# colours and every ALREADY-CACHED chunk keeps yesterday's shading baked into its vertex
	# colours while newly generated chunks use the new values — the map lit two different ways
	# with a seam wherever the cache boundary happens to fall, and no in-game way to flush it.
	# The taper knobs were missed the same way and for the same reason: it is easy to think of
	# this key as "the heights key". It is not. If you add anything to the PAYLOAD, add its
	# inputs here.
	parts.append("light=%.4f,%s,%s,%s,%s" % [
		_num(cfg, "terrain_light_amount", 0.0),
		_vec3(cfg, "sun_direction"), _col(cfg, "sun_color"),
		_col(cfg, "sky_color"), _col(cfg, "ground_color"),
	])
	# The coastline edge taper (D9). It is applied INSIDE height generation, before
	# quantisation, so it is baked into every perimeter chunk's bytes — retuning either knob
	# reshapes the coast and MUST invalidate. The waterline goes in with them because the
	# taper is measured as a depth below it, so moving the water moves the coast too.
	parts.append("taper=%.4f,%.4f,%.4f" % [
		_num(cfg, "overworld_edge_taper_m", 0.0),
		_num(cfg, "overworld_edge_depth_m", 0.0),
		_num(cfg, "track_water_level_m", 0.0),
	])
	# Scatter density + forestiness (slice-4 scatter records, and the light/colour the
	# foliage shading contributes today).
	parts.append("scatter=%.4f,%.4f" % [_num(cfg, "trees_per_turn", 0.0),
		_num(cfg, "tree_spawn_radius_m", 0.0)])
	parts.append("forest=%.4f,%.4f,%.4f" % [_num(cfg, "free_roam_forestiness", 0.0),
		_num(cfg, "track_forestiness", 0.0), _num(cfg, "forest_wavelength_m", 0.0)])
	parts.append("map=" + map_image_path)
	return "|".join(parts).hash()


# Read a numeric GameConfig field by name, tolerating a field this build does not
# have yet (the overworld knobs land in a sibling slice). Booleans come back as
# 0.0 / 1.0. Keeping this tolerant is what lets the key be a pure static helper.
# Tolerant readers for the non-scalar light fields — `_num` below only handles scalars and
# would silently fold a Vector3 or a Color to its fallback, which is exactly the kind of quiet
# hole this key must not have. Normalised/quantised so a meaningless last-bit difference in an
# authored value cannot throw away a whole valid cache.
static func _vec3(cfg: GameConfig, field: String) -> String:
	if cfg == null or not (field in cfg):
		return "-"
	var v: Variant = cfg.get(field)
	if typeof(v) != TYPE_VECTOR3:
		return "-"
	var n: Vector3 = (v as Vector3).normalized()
	return "%.4f/%.4f/%.4f" % [n.x, n.y, n.z]


static func _col(cfg: GameConfig, field: String) -> String:
	if cfg == null or not (field in cfg):
		return "-"
	var v: Variant = cfg.get(field)
	if typeof(v) != TYPE_COLOR:
		return "-"
	var c: Color = v
	return "%.4f/%.4f/%.4f/%.4f" % [c.r, c.g, c.b, c.a]


static func _num(cfg: GameConfig, field: String, fallback: float) -> float:
	if cfg == null or not (field in cfg):
		return fallback
	var v: Variant = cfg.get(field)
	match typeof(v):
		TYPE_FLOAT, TYPE_INT:
			return float(v)
		TYPE_BOOL:
			return 1.0 if v else 0.0
		_:
			return fallback

# ---------------------------------------------------------------------------
# Payload codec
# ---------------------------------------------------------------------------

# Uncompressed payload:
#   u8  payload version
#   u16 samples per edge (sanity: must match TerrainManager.SAMPLES)
#   u32 height count, then that many int16 fixed-point heights
#   u32 light byte count, then that many bytes (RGB8 triples)
#   u32 surface float count (0 = section absent), then that many little-endian f32s,
#       interleaved per vertex as (road_weight, tarmac_weight, region_rank)
#   [future sections appended here — a reader ignores trailing bytes it predates]
#
# THE SURFACE SECTION exists purely to make a READ cheap. It holds the three DERIVED per-vertex
# channels a rehydrated chunk otherwise has to recompute:
#
#   COLOR.a  road weight    } TerrainManager._apply_road_carve, which called
#   UV2.x    tarmac weight  } OverworldRoads.road_at once PER VERTEX (2,601 per chunk)
#   UV2.y    region rank      TerrainManager._apply_region_blend
#
# Without it, precomputing to disk removed the height generation and nothing else: rehydrating
# still paid both passes, ~10-15 ms a chunk, which is what made every chunk-boundary crossing a
# 3-4 frame spike.
#
# WHY f32 AND NOT A QUANTISED BYTE. The cache's contract is an EXACT round trip — a rehydrated
# chunk must be the same surface a freshly generated one produces (test_overworld_cache asserts
# bit-identical heights; test_terrain_digest is a golden SHA-256 over generated terrain). Heights
# get away with int16 only because they are SNAPPED AT GENERATION (`height_quantum`), so the
# cached and the generated numbers are literally equal. These three channels are NOT snapped
# anywhere, so quantising them would make a rehydrated chunk differ from a generated one — a
# lossy channel here would be a visible seam wherever the cache boundary falls, for a saving of
# ~23 KB raw per chunk. f32 is 12 bytes/vertex, ~31 KB raw per chunk before the record's zstd,
# which crushes it hard: the road channels are exactly 0.0 across nearly every vertex of a
# ~1,600-chunk map and the rank is near-constant within a region.
static func _encode_payload(heights: PackedFloat32Array, lights: PackedByteArray,
		surface: PackedFloat32Array = PackedFloat32Array()) -> PackedByteArray:
	var steps := quantise_heights(heights)
	var head := PackedByteArray()
	head.resize(7 + steps.size() * 2 + 4)
	head.encode_u8(0, PAYLOAD_VERSION)
	head.encode_u16(1, TerrainManager.SAMPLES)
	head.encode_u32(3, steps.size())
	var at := 7
	for i in steps.size():
		head.encode_s16(at, steps[i])
		at += 2
	head.encode_u32(at, lights.size())
	head.append_array(lights)
	var tail := PackedByteArray()
	tail.resize(4)
	tail.encode_u32(0, surface.size())
	head.append_array(tail)
	if not surface.is_empty():
		# to_byte_array / to_float32_array are the exact, allocation-light pair — no per-element
		# encode loop, and the f32 bits survive untouched.
		head.append_array(surface.to_byte_array())
	return head


# Inverse of _encode_payload. {} on anything unexpected — a decode failure is a miss.
static func _decode_payload(raw: PackedByteArray) -> Dictionary:
	if raw.size() < 7:
		return {}
	if raw.decode_u8(0) != PAYLOAD_VERSION:
		return {}
	if raw.decode_u16(1) != TerrainManager.SAMPLES:
		return {}
	var count := int(raw.decode_u32(3))
	var expect := TerrainManager.SAMPLES * TerrainManager.SAMPLES
	if count != expect:
		return {}
	var at := 7
	if raw.size() < at + count * 2 + 4:
		return {}
	var heights := PackedFloat32Array()
	heights.resize(count)
	for i in count:
		heights[i] = float(raw.decode_s16(at)) / HEIGHT_SCALE
		at += 2
	var light_len := int(raw.decode_u32(at))
	at += 4
	# RGB8, one triple per vertex. A light-less record is never written, so an empty
	# or mis-sized light block means the bytes are wrong.
	if light_len != count * 3 or raw.size() < at + light_len:
		return {}
	var lights := raw.slice(at, at + light_len)
	at += light_len
	var out := {"heights": heights, "l0_light": lights}
	# THE SURFACE SECTION IS OPTIONAL, in both directions: a record written without one (no road
	# and no region source attached, or a record from before the section existed) simply omits the
	# key, and TerrainManager._rehydrate_chunk_data then recomputes the two passes as it always
	# did. A truncated or mis-sized section is treated as absent rather than as corruption — the
	# heights and the light are still good, and the fallback is exact.
	if raw.size() >= at + 4:
		var surface_len := int(raw.decode_u32(at))
		at += 4
		var want := count * SURFACE_CHANNELS
		if surface_len == want and raw.size() >= at + want * 4:
			out["surface"] = raw.slice(at, at + want * 4).to_float32_array()
	return out

# ---------------------------------------------------------------------------
# Index I/O
# ---------------------------------------------------------------------------

# index.dat:
#   u32 format version
#   u8  key kind (0 = int, 1 = String — the String form is reserved for a future
#                 content-hash key; the reader accepts both)
#   s64 key           (kind 0)      | pascal string key (kind 1)
#   u32 entry count, then per entry: s64 coord.x, s64 coord.y, s64 offset, u32 length
#
# Returns true when a VALID index for _key was loaded. False (without disabling the
# cache) means "no usable index" — the caller wipes.
func _read_index() -> bool:
	if not FileAccess.file_exists(file_path("index.dat")):
		return false
	var f := FileAccess.open(file_path("index.dat"), FileAccess.READ)
	if f == null:
		# Present but unreadable: treat as no index rather than as a fault, but say so.
		push_warning("OverworldCache: cannot read %s (error %d) — rebuilding"
			% [file_path("index.dat"), FileAccess.get_open_error()])
		return false
	var version := int(f.get_32())
	if version != FORMAT_VERSION:
		f.close()
		return false
	var kind := int(f.get_8())
	var stored_key := 0
	if kind == 0:
		stored_key = f.get_64()
	elif kind == 1:
		stored_key = f.get_pascal_string().hash()
	else:
		f.close()
		return false
	if stored_key != _key:
		f.close()
		return false
	var count := int(f.get_32())
	if count < 0:
		f.close()
		return false
	var table: Dictionary = {}
	for _i in count:
		if f.eof_reached():
			f.close()
			return false
		var cx := f.get_64()
		var cz := f.get_64()
		var offset := f.get_64()
		var length := int(f.get_32())
		if offset < 0 or length <= HEADER_BYTES:
			f.close()
			return false
		table[Vector2i(cx, cz)] = {"offset": offset, "length": length}
	f.close()
	_index = table
	return true


# Write the WHOLE index to index.dat.tmp and rename it over index.dat. Never rewrites
# chunks.dat — an in-place index rewrite would orphan every record on a crash.
func _write_index() -> bool:
	var f := FileAccess.open(file_path("index.dat.tmp"), FileAccess.WRITE)
	if f == null:
		_fail("cannot open %s (error %d)" % [file_path("index.dat.tmp"), FileAccess.get_open_error()])
		return false
	f.store_32(FORMAT_VERSION)
	f.store_8(0)
	f.store_64(_key)
	f.store_32(_index.size())
	for coord in _index:
		var c: Vector2i = coord
		var e: Dictionary = _index[coord]
		f.store_64(c.x)
		f.store_64(c.y)
		f.store_64(int(e["offset"]))
		f.store_32(int(e["length"]))
	f.flush()
	var err := f.get_error()
	f.close()
	if err != OK and err != ERR_FILE_EOF:
		_fail("writing %s failed (error %d)" % [file_path("index.dat.tmp"), err])
		return false
	var dir := DirAccess.open("user://")
	if dir == null:
		_fail("cannot open user:// (error %d)" % DirAccess.get_open_error())
		return false
	var moved := dir.rename(file_path("index.dat.tmp"), file_path("index.dat"))
	if moved != OK:
		_fail("cannot rename %s over %s (error %d)"
			% [file_path("index.dat.tmp"), file_path("index.dat"), moved])
		return false
	return true

# ---------------------------------------------------------------------------
# Data-file handle
# ---------------------------------------------------------------------------

func _open_chunks() -> bool:
	if not FileAccess.file_exists(file_path("chunks.dat")):
		# READ_WRITE cannot create; WRITE_READ creates but truncates, so it is only
		# safe on a file that does not exist yet.
		var created := FileAccess.open(file_path("chunks.dat"), FileAccess.WRITE_READ)
		if created == null:
			_fail("cannot create %s (error %d)" % [file_path("chunks.dat"), FileAccess.get_open_error()])
			return false
		created.close()
	_chunks = FileAccess.open(file_path("chunks.dat"), FileAccess.READ_WRITE)
	if _chunks == null:
		_fail("cannot open %s (error %d)" % [file_path("chunks.dat"), FileAccess.get_open_error()])
		return false
	_bytes = _chunks.get_length()
	return true

# ---------------------------------------------------------------------------
# Failure handling
# ---------------------------------------------------------------------------

# Disable ONLY this cache for the session, warn once, and drop the handles. Never
# touches Save.save_disabled or the profile write path: a cache fault must not cost
# the player their progress.
func _fail(reason: String) -> void:
	if _active:
		push_warning("OverworldCache disabled for this session: " + reason)
	_active = false
	close()

# ---------------------------------------------------------------------------
# CRC32
# ---------------------------------------------------------------------------

static var _crc_table: PackedInt64Array = PackedInt64Array()

# Standard CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) over the compressed
# payload. Godot exposes no CRC32 for a PackedByteArray, and a hash() would not be
# guaranteed stable across engine versions, so the table is built here.
static func _crc32(bytes: PackedByteArray) -> int:
	if _crc_table.is_empty():
		var table := PackedInt64Array()
		table.resize(256)
		for i in 256:
			var c := i
			for _b in 8:
				c = (0xEDB88320 ^ (c >> 1)) if (c & 1) != 0 else (c >> 1)
			table[i] = c
		_crc_table = table
	var crc := 0xFFFFFFFF
	for i in bytes.size():
		crc = _crc_table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8)
	return crc ^ 0xFFFFFFFF
