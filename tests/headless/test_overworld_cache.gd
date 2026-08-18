extends GutTest
# The overworld terrain disk cache (`scripts/overworld_cache.gd`), per the
# "Cache" bullets of docs/superpowers/specs/2026-08-17-overworld-hq-design.md.
#
# Everything here is scene-free and await-free — OverworldCache is a RefCounted
# that only touches user:// — so the whole file costs a fraction of a second.
#
# WHY these tests exist (none of them pin a tunable value):
#   - the exact round-trip is the cache's whole contract: heights are snapped onto
#     the quantisation lattice AT GENERATION, so a cached chunk and the live chunk
#     must be the SAME numbers, not merely close. If the round-trip were lossy the
#     collision shape, the bilinear height query and the mesh would disagree by a
#     visible step at every chunk boundary.
#   - every failure mode must degrade to a MISS (a `{}`), never an error and never
#     another chunk's bytes: a miss is free (regenerate), a wrong answer is
#     corrupt geometry. The length-preserving corruption case is the specific
#     reason the record carries a CRC32 at all — a length/magic check cannot see it.
#   - a light-less record could never be told apart from a valid one later, and the
#     invalidation key cannot discard it, so it must not reach the disk.
#   - a changed invalidation key must FREE the bytes, not just hide them; at ~83 MB
#     for a 4 km world, "leave it and start again" would fill the player's disk.
#     The same-key test is the necessary complement — without it, a cache that
#     always wiped on open would pass the invalidation test.
#   - a cache fault must cost the player nothing: `active()` goes false for that
#     instance and `Save.save_disabled` is untouched (the profile write path is a
#     different subsystem and a terrain cache must never disable it).
#
# REDIRECTED, and this matters: `wipe()` deletes the whole cache directory, so running these
# against the real path destroyed the DEVELOPER'S precomputed overworld (tens of MB) on every
# suite run and forced a re-precompute on their next launch. `OverworldCache.dir_override` is the
# seam — set in before_all, restored in after_all — so the tests exercise the real read/write/wipe
# code against a throwaway directory instead. Same reasoning as `SaveManager.test_sandbox_path`.
#
# user://profile.json is never touched — the profile is only ever READ here (the save_disabled
# assertion).

const TEST_DIR := "user://test_overworld_cache"

var _dir_was := ""

const DIR := TEST_DIR
const CHUNKS := TEST_DIR + "/chunks.dat"
const INDEX := TEST_DIR + "/index.dat"

# An arbitrary key: these tests only ever compare keys to each other.
const KEY_A := 111
const KEY_B := 222

var _cache: OverworldCache = null


func before_all() -> void:
	_dir_was = OverworldCache.dir_override
	OverworldCache.dir_override = TEST_DIR


func before_each() -> void:
	# Belt and braces: if a sibling file ever clears the override, refuse to run against the real
	# cache rather than deleting it.
	OverworldCache.dir_override = TEST_DIR
	_cache = OverworldCache.new()
	_cache.wipe()
	_cache.close()


func after_each() -> void:
	if _cache != null:
		_cache.close()
		_cache.wipe()
		_cache.close()
		_cache = null
	_remove_dir()


func after_all() -> void:
	_remove_dir()
	OverworldCache.dir_override = _dir_was


func _remove_dir() -> void:
	for path in [INDEX, OverworldCache.INDEX_TMP_PATH, CHUNKS]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute(DIR):
		DirAccess.remove_absolute(DIR)


# --------------------------------------------------------------------------
# Synthetic chunk data (never a real generated chunk — no world is built here)
# --------------------------------------------------------------------------

# A deterministic, already-snapped height grid of exactly the size a record holds.
func _make_heights(salt: float = 0.0) -> PackedFloat32Array:
	var n := TerrainManager.SAMPLES * TerrainManager.SAMPLES
	var raw := PackedFloat32Array()
	raw.resize(n)
	for i in n:
		# Deliberately off-lattice values so snap_heights() has real work to do.
		raw[i] = sin(float(i) * 0.017 + salt) * 12.3456789 + salt
	return OverworldCache.snap_heights(raw)


# RGB8 triples, one per vertex — the shape TerrainLod.encode_lights produces.
func _make_lights() -> PackedByteArray:
	var n := TerrainManager.SAMPLES * TerrainManager.SAMPLES
	var out := PackedByteArray()
	out.resize(n * 3)
	for i in n * 3:
		out[i] = i % 251
	return out


func _new_config() -> GameConfig:
	return GameConfig.new()


# The DERIVED surface channels — SAMPLES² x (road_weight, tarmac_weight, region_rank). Values
# chosen to be awkward on purpose: fractions no fixed-point byte scale could represent, so a
# lossy channel cannot pass the exactness assertions below.
func _make_surface() -> PackedFloat32Array:
	var n := TerrainManager.SAMPLES * TerrainManager.SAMPLES
	var out := PackedFloat32Array()
	out.resize(n * OverworldCache.SURFACE_CHANNELS)
	for i in n:
		var at := i * OverworldCache.SURFACE_CHANNELS
		out[at] = float(i % 97) / 97.0
		out[at + 1] = float(i % 31) / 31.0
		out[at + 2] = float(i % 7) / 7.0
	return out


# --------------------------------------------------------------------------
# The derived surface channels (the read-side fast path)
# --------------------------------------------------------------------------

# The channels are stored so a read can skip the road carve and the region blend entirely. That
# is only sound if the round trip is EXACT — an approximate channel would make a rehydrated
# chunk shade differently from a generated one, with a seam wherever the cache boundary falls.
func test_surface_channels_round_trip_bit_exactly() -> void:
	var surface := _make_surface()
	assert_true(_cache.open(KEY_A), "cache opens")
	var coord := Vector2i(-4, 11)
	assert_true(_cache.write(coord, _make_heights(), _make_lights(), surface), "write succeeds")
	var got := _cache.read(coord)
	assert_true(got.has("surface"), "a record written with the section reads it back")
	var back: PackedFloat32Array = got["surface"]
	assert_eq(back.size(), surface.size(), "channel count survives")
	var mismatch := -1
	for i in surface.size():
		if back[i] != surface[i]:
			mismatch = i
			break
	assert_eq(mismatch, -1, "every channel value round-trips bit-exactly, not approximately")


# The section is OPTIONAL in both directions, which is what makes the fast path a pure speed-up
# rather than a correctness dependency: a record without it is still a perfectly good record,
# and the reader simply recomputes those channels.
func test_a_record_without_the_surface_section_is_still_a_hit() -> void:
	assert_true(_cache.open(KEY_A), "cache opens")
	var coord := Vector2i(2, 2)
	assert_true(_cache.write(coord, _make_heights(), _make_lights()), "write succeeds")
	var got := _cache.read(coord)
	assert_false(got.is_empty(), "a section-less record is a HIT, not a miss")
	assert_false(got.has("surface"), "and it reports no channels rather than empty ones")
	assert_eq(got["l0_light"], _make_lights(), "the light is unaffected by the absent section")


# A wrong-sized channel array must never be able to poison a record whose heights and light are
# fine: the recompute fallback is exact, so dropping the section is strictly better than storing
# something the reader would splice into the mesh.
func test_a_mis_sized_surface_section_is_dropped_not_stored() -> void:
	assert_true(_cache.open(KEY_A), "cache opens")
	var coord := Vector2i(0, -3)
	var heights := _make_heights()
	var short := PackedFloat32Array()
	short.resize(12)
	assert_true(_cache.write(coord, heights, _make_lights(), short),
		"the record is still written")
	var got := _cache.read(coord)
	assert_false(got.has("surface"), "the bad section is not stored")
	assert_eq(got["heights"] as PackedFloat32Array, heights,
		"and the heights it came with are untouched")


# --------------------------------------------------------------------------
# Round-trip and quantisation
# --------------------------------------------------------------------------

func test_written_chunk_reads_back_exactly() -> void:
	var heights := _make_heights()
	var lights := _make_lights()
	assert_true(_cache.open(KEY_A), "cache opens")
	assert_true(_cache.write(Vector2i(3, -7), heights, lights), "write succeeds")
	assert_true(_cache.has(Vector2i(3, -7)), "coord is indexed after a write")
	var got := _cache.read(Vector2i(3, -7))
	assert_false(got.is_empty(), "written coord reads back")
	var back: PackedFloat32Array = got["heights"]
	assert_eq(back.size(), heights.size(), "height count survives")
	# BIT-identical, not approximate: the grid was snapped before writing.
	var mismatch := -1
	for i in heights.size():
		if back[i] != heights[i]:
			mismatch = i
			break
	assert_eq(mismatch, -1, "every snapped height round-trips exactly")
	assert_eq(got["l0_light"], lights, "the encoded light bytes come back unchanged")


func test_snap_heights_is_idempotent_and_quantisation_round_trips() -> void:
	# Idempotence is what makes the cache round-trip exact rather than a slow
	# drift: the caller writes the snapped grid back into the live chunk, and
	# re-snapping it (on a later read, or a second write) must be a no-op.
	var once := _make_heights(0.5)
	var twice := OverworldCache.snap_heights(once)
	assert_eq(twice, once, "snapping an already-snapped grid changes nothing")
	var re := OverworldCache.dequantise_heights(OverworldCache.quantise_heights(once))
	assert_eq(re, once, "quantise/dequantise of a snapped grid is exact")


# --------------------------------------------------------------------------
# Misses: absent, corrupt, truncated
# --------------------------------------------------------------------------

func test_unwritten_coord_is_a_plain_miss() -> void:
	assert_true(_cache.open(KEY_A), "cache opens")
	assert_false(_cache.has(Vector2i(9, 9)), "never-written coord is not indexed")
	assert_eq(_cache.read(Vector2i(9, 9)), {}, "a miss is an empty dictionary")
	assert_true(_cache.active(), "a miss does not disable the cache")


func test_length_preserving_corruption_is_a_miss_not_an_error() -> void:
	# The case a magic/length check cannot catch, and the entire reason the record
	# carries a CRC32: flip one payload byte for another byte of the SAME width so
	# the record length and the index agree perfectly, yet the bytes are wrong.
	# Without the CRC this would decompress into plausible int16 heights.
	var coord := Vector2i(0, 0)
	assert_true(_cache.open(KEY_A), "cache opens")
	assert_true(_cache.write(coord, _make_heights(), _make_lights()), "write succeeds")
	var before := _cache.size_bytes()
	_cache.close()

	var f := FileAccess.open(CHUNKS, FileAccess.READ_WRITE)
	assert_not_null(f, "chunks.dat is openable for patching")
	# First record starts at 0, so its payload starts right after the header.
	f.seek(OverworldCache.HEADER_BYTES)
	var original := f.get_8()
	f.seek(OverworldCache.HEADER_BYTES)
	f.store_8((original + 1) % 256)
	f.flush()
	f.close()

	var reopened := OverworldCache.new()
	assert_true(reopened.open(KEY_A), "cache re-opens over the patched file")
	assert_eq(reopened.size_bytes(), before, "the record's LENGTH is unchanged")
	assert_true(reopened.has(coord), "the index still names the corrupt record")
	assert_eq(reopened.read(coord), {}, "a CRC mismatch reads as a miss")
	assert_true(reopened.active(), "corruption is a miss, not a fault")
	reopened.close()


func test_truncated_chunk_file_is_a_miss() -> void:
	# A torn append (power loss mid-write) leaves chunks.dat cut inside a record.
	# The index still names the full record, so the reader must notice it runs off
	# the end rather than handing back a half-decoded grid.
	var coord := Vector2i(2, 2)
	assert_true(_cache.open(KEY_A), "cache opens")
	assert_true(_cache.write(coord, _make_heights(), _make_lights()), "write succeeds")
	_cache.close()

	var reader := FileAccess.open(CHUNKS, FileAccess.READ)
	var bytes := reader.get_buffer(reader.get_length())
	reader.close()
	assert_gt(bytes.size(), OverworldCache.HEADER_BYTES + 8, "record is big enough to cut")
	var writer := FileAccess.open(CHUNKS, FileAccess.WRITE)
	writer.store_buffer(bytes.slice(0, bytes.size() - 8))  # cut mid-record
	writer.close()

	var reopened := OverworldCache.new()
	reopened.open(KEY_A)
	assert_eq(reopened.read(coord), {}, "a truncated record reads as a miss")
	assert_true(reopened.active(), "truncation does not raise or disable the cache")
	reopened.close()


# --------------------------------------------------------------------------
# Refusals
# --------------------------------------------------------------------------

func test_light_less_record_is_never_written() -> void:
	# A record with no baked light can never be distinguished from a valid one on
	# a later read, and the invalidation key cannot discard it, so it must not be
	# written at all — the light has to be captured at generation time.
	assert_true(_cache.open(KEY_A), "cache opens")
	var coord := Vector2i(1, 1)
	assert_false(_cache.write(coord, _make_heights(), PackedByteArray()),
		"write with empty light is refused")
	assert_false(_cache.has(coord), "the coord stays absent")
	assert_eq(_cache.read(coord), {}, "and reads as a miss")
	assert_eq(_cache.size_bytes(), 0, "nothing was appended")
	assert_true(_cache.active(), "a refusal is not a fault")


# --------------------------------------------------------------------------
# Invalidation
# --------------------------------------------------------------------------

func test_changed_key_discards_the_cache_and_frees_the_bytes() -> void:
	var coord := Vector2i(4, 5)
	assert_true(_cache.open(KEY_A), "cache opens with key A")
	assert_true(_cache.write(coord, _make_heights(), _make_lights()), "write succeeds")
	assert_gt(_cache.size_bytes(), 0, "bytes were written")
	_cache.close()

	var other := OverworldCache.new()
	assert_true(other.open(KEY_B), "cache opens with key B")
	assert_false(other.has(coord), "the stale coord is gone")
	assert_eq(other.read(coord), {}, "and reads as a miss")
	# Freeing matters: at life size the stale data file is tens of megabytes, so
	# "ignore it" would grow the player's disk usage without bound.
	assert_eq(other.size_bytes(), 0, "the old bytes were freed, not left on disk")
	other.close()


func test_same_key_preserves_the_cached_chunk() -> void:
	# The complement of the invalidation test: without this, a cache that wiped on
	# EVERY open would satisfy the test above while caching nothing at all.
	var coord := Vector2i(-6, 8)
	var heights := _make_heights(1.25)
	var lights := _make_lights()
	assert_true(_cache.open(KEY_A), "cache opens")
	assert_true(_cache.write(coord, heights, lights), "write succeeds")
	_cache.close()

	var reopened := OverworldCache.new()
	assert_true(reopened.open(KEY_A), "cache re-opens with the same key")
	assert_true(reopened.has(coord), "the coord survived the re-open")
	var got := reopened.read(coord)
	assert_false(got.is_empty(), "the record still reads")
	assert_eq(got["heights"], heights, "heights are unchanged across the re-open")
	assert_eq(got["l0_light"], lights, "light is unchanged across the re-open")
	reopened.close()


func test_a_batched_write_reads_back_and_survives_a_flushed_close() -> void:
	# Batching defers only the INDEX write (`begin_batch`/`end_batch`), so within the session a
	# batched chunk is an ordinary hit, and once the batch closes it is on disk like any other.
	var coord := Vector2i(3, -4)
	var heights := _make_heights(0.5)
	var lights := _make_lights()
	assert_true(_cache.open(KEY_A), "cache opens")
	_cache.begin_batch()
	assert_true(_cache.write(coord, heights, lights), "a batched write succeeds")
	assert_true(_cache.has(coord), "and is a hit immediately, without a flush")
	assert_eq(_cache.read(coord)["heights"], heights, "reading it back is exact")
	assert_true(_cache.end_batch(), "closing the batch flushes the index")
	_cache.close()

	var reopened := OverworldCache.new()
	assert_true(reopened.open(KEY_A), "cache re-opens")
	assert_true(reopened.has(coord), "the batched chunk survived the re-open")
	assert_eq(reopened.read(coord)["heights"], heights, "and still reads exactly")
	reopened.close()


func test_an_abandoned_batch_degrades_to_a_miss_not_corruption() -> void:
	# The safety claim that makes deferring the index write acceptable: the DATA record is still
	# appended and flushed per chunk, and a record that was never named is simply unreachable —
	# a miss, which the terrain regenerates — never another chunk's bytes and never an error.
	# This is the same crash semantics the write path already had; batching only widens the window.
	var named := Vector2i(1, 1)
	var abandoned := Vector2i(2, 2)
	var lights := _make_lights()
	assert_true(_cache.open(KEY_A), "cache opens")
	assert_true(_cache.write(named, _make_heights(2.0), lights), "the first chunk is written")
	_cache.begin_batch()
	assert_true(_cache.write(abandoned, _make_heights(3.0), lights), "the batched chunk is written")
	_cache.close()   # no end_batch(): the process "died" mid-batch

	var reopened := OverworldCache.new()
	assert_true(reopened.open(KEY_A), "the cache still opens after an abandoned batch")
	assert_true(reopened.has(named), "the chunk that WAS named is intact")
	assert_eq(reopened.read(named)["heights"], _make_heights(2.0),
		"...and reads back exactly, so the orphan did not disturb it")
	assert_false(reopened.has(abandoned), "the unnamed chunk is a plain miss")
	assert_true(reopened.read(abandoned).is_empty(), "and reading it returns nothing, not bytes")
	reopened.close()


func test_invalidation_key_is_pure_and_responds_to_its_inputs() -> void:
	# Only "changing an input changes the key" is asserted — never a key value and
	# never a field's default, both of which are tuning.
	var cfg := _new_config()
	var base := OverworldCache.invalidation_key(cfg, 0.25)
	assert_eq(OverworldCache.invalidation_key(cfg, 0.25), base,
		"the key is pure: same inputs, same key")

	var world := _new_config()
	world.overworld_size_m = cfg.overworld_size_m + 500.0
	assert_ne(OverworldCache.invalidation_key(world, 0.25), base,
		"changing overworld_size_m changes the key")

	var layered := _new_config()
	layered.overworld_terrain_layer1_amplitude = cfg.overworld_terrain_layer1_amplitude + 3.0
	assert_ne(OverworldCache.invalidation_key(layered, 0.25), base,
		"changing a terrain layer changes the key")

	var taper := _new_config()
	taper.overworld_edge_taper_m = cfg.overworld_edge_taper_m + 100.0
	assert_ne(OverworldCache.invalidation_key(taper, 0.25), base,
		"changing overworld_edge_taper_m changes the key")

	var depth := _new_config()
	depth.overworld_edge_depth_m = cfg.overworld_edge_depth_m + 10.0
	assert_ne(OverworldCache.invalidation_key(depth, 0.25), base,
		"changing overworld_edge_depth_m changes the key")

	# The taper is measured as a depth below the waterline, so moving the water
	# moves the coast and must invalidate too.
	var water := _new_config()
	water.track_water_level_m = cfg.track_water_level_m + 5.0
	assert_ne(OverworldCache.invalidation_key(water, 0.25), base,
		"changing track_water_level_m changes the key")

	assert_ne(OverworldCache.invalidation_key(cfg, 0.5), base,
		"changing the texture tiling changes the key")


# A cached record holds TWO generator products — heights AND the baked per-vertex light — and
# the light's five inputs were omitted from the key at first, exactly as the taper knobs were
# before them. The symptom is nasty and unflushable: retune the sun and already-cached chunks
# keep yesterday's shading while new ones use the new values, seaming the map wherever the
# cache boundary falls.
#
# One case per input, because the whole failure mode is "one of them was forgotten" — a single
# combined assertion would pass while four were still missing. Asserts no value and no
# default, only that changing an input changes the key.
func test_the_baked_lights_inputs_all_change_the_key() -> void:
	var cfg := _new_config()
	var base := OverworldCache.invalidation_key(cfg, 0.25)

	var amount := _new_config()
	amount.terrain_light_amount = 1.0 - cfg.terrain_light_amount
	assert_ne(OverworldCache.invalidation_key(amount, 0.25), base,
		"changing terrain_light_amount changes the key")

	# A different DIRECTION, not a longer vector: the key normalises, because scaling the sun
	# vector does not change the shading and must not throw the cache away.
	var sun_dir := _new_config()
	sun_dir.sun_direction = Vector3(cfg.sun_direction.z, cfg.sun_direction.y,
		-cfg.sun_direction.x)
	assert_ne(OverworldCache.invalidation_key(sun_dir, 0.25), base,
		"changing sun_direction changes the key")

	var scaled := _new_config()
	scaled.sun_direction = cfg.sun_direction * 3.0
	assert_eq(OverworldCache.invalidation_key(scaled, 0.25), base,
		"merely LENGTHENING sun_direction does not, since the shading is identical")

	for field in ["sun_color", "sky_color", "ground_color"]:
		var tinted := _new_config()
		var was: Color = tinted.get(field)
		# Rotate the red channel rather than inverting it. `1.0 - r` was the obvious choice and
		# was WRONG: sun_color and sky_color both ship at 0.5, so it produced the identical
		# colour, mutated nothing, and the test failed against correct code. An additive
		# rotation cannot land back on its input for any authored value.
		var changed := Color(fposmod(was.r + 0.37, 1.0), was.g, was.b, was.a)
		assert_false(changed.is_equal_approx(was),
			"the test actually changes %s — otherwise the assertion below is meaningless" % field)
		tinted.set(field, changed)
		assert_ne(OverworldCache.invalidation_key(tinted, 0.25), base,
			"changing %s changes the key" % field)


# --------------------------------------------------------------------------
# Failure isolation
# --------------------------------------------------------------------------

func test_failure_disables_only_this_cache_and_never_save_disabled() -> void:
	# Force open() to fail by putting a regular FILE where the cache wants its
	# directory: make_dir_recursive_absolute then cannot succeed. The property
	# under test is the isolation — a terrain cache fault must never reach the
	# profile write path, or a bad disk would cost the player their progress.
	_remove_dir()
	var save: Node = get_node("/root/Save")
	var save_disabled_before: bool = save.save_disabled

	var blocker := FileAccess.open(DIR, FileAccess.WRITE)
	assert_not_null(blocker, "a plain file can stand in for the cache directory")
	blocker.store_8(0)
	blocker.close()

	var broken := OverworldCache.new()
	assert_false(broken.open(KEY_A), "open() reports failure")
	assert_false(broken.active(), "the failed cache is inactive for the session")
	assert_eq(broken.read(Vector2i(0, 0)), {}, "reads miss while inactive")
	assert_false(broken.write(Vector2i(0, 0), _make_heights(), _make_lights()),
		"writes refuse while inactive")
	assert_eq(save.save_disabled, save_disabled_before,
		"Save.save_disabled is untouched by a cache failure")

	DirAccess.remove_absolute(DIR)
	# A brand-new instance is unaffected: the disable is sticky per INSTANCE only.
	var fresh := OverworldCache.new()
	assert_true(fresh.open(KEY_A), "a new instance opens fine once the disk is sane")
	fresh.close()


# The hub has its OWN height noise (GameConfig.overworld_terrain_*), separate from the stages'
# terrain_layer* / track_seed. Two things must hold, and the second is the one that bites:
#
#   * retuning the hub's noise MUST invalidate — the heights are baked into the cached bytes,
#     so a key that ignored them would serve ground nothing generated, unflushably;
#   * retuning the STAGES' noise must NOT invalidate — the hub does not read those fields, and
#     throwing away a whole precomputed map because someone retuned a stage is a real cost
#     (a full re-precompute on the next launch).
#
# That second assertion is also what pins the separation itself: if a future edit quietly
# repointed the hub back at the shared fields, this test fails rather than silently coupling
# the two worlds again. One case per field, because the failure mode is "one was forgotten".
func test_the_overworld_noise_is_keyed_and_the_stage_noise_is_not() -> void:
	var cfg := _new_config()
	var base := OverworldCache.invalidation_key(cfg, 0.25)

	var seeded := _new_config()
	seeded.overworld_terrain_seed = cfg.overworld_terrain_seed + 1
	assert_ne(OverworldCache.invalidation_key(seeded, 0.25), base,
		"changing overworld_terrain_seed changes the key")

	for field in [
		"overworld_terrain_layer1_wavelength", "overworld_terrain_layer1_amplitude",
		"overworld_terrain_layer2_wavelength", "overworld_terrain_layer2_amplitude",
		"overworld_terrain_layer3_wavelength", "overworld_terrain_layer3_amplitude",
	]:
		var tuned := _new_config()
		var was := float(tuned.get(field))
		# Additive, so it cannot land back on its input whatever the authored value — the
		# mistake that made an earlier version of the colour sweep in this file assert nothing.
		tuned.set(field, was + 7.0)
		assert_ne(float(tuned.get(field)), was,
			"the test actually changes %s" % field)
		assert_ne(OverworldCache.invalidation_key(tuned, 0.25), base,
			"changing %s changes the key" % field)

	# The stage fields the hub deliberately does NOT read.
	var stage := _new_config()
	stage.terrain_layer1_wavelength = cfg.terrain_layer1_wavelength + 50.0
	stage.terrain_layer1_amplitude = cfg.terrain_layer1_amplitude + 9.0
	stage.terrain_layer2_amplitude = cfg.terrain_layer2_amplitude + 4.0
	stage.track_seed = cfg.track_seed + 1
	assert_eq(OverworldCache.invalidation_key(stage, 0.25), base,
		"retuning the STAGES' terrain noise or seed does not invalidate the hub's cache")
