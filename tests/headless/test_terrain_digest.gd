extends GutTest
# GOLDEN DIGEST — the byte-for-byte safety net for the TerrainDomain refactor.
#
# WHAT THIS IS
# ------------
# `scripts/terrain_manager.gd` is about to have its two parallel notions of "what ground
# exists" (the stage's track CORRIDOR and the overworld's rectangular BOUNDS) unified behind
# one injected domain abstraction. The single hardest requirement of that refactor is that
# STAGES STAY BYTE-FOR-BYTE IDENTICAL. Nothing in the suite checked that. This does.
#
# It builds a TerrainManager from FIXED SYNTHETIC INPUTS, calls `compute_chunk_data` for a
# couple of fixed coords, and hashes the produced arrays — `heights`, `vertices`, `colors`,
# `uv2s`, `indices`. If the refactor changes the maths, the hash moves and this fails.
#
# WHY THIS IS LEGAL UNDER CLAUDE.md ("never test tunable/balance VALUES")
# ----------------------------------------------------------------------
# It does NOT pin a tunable. Every input this test digests is CONSTRUCTED BY THE TEST:
# the noise seed, the terrain layers (wavelength/amplitude), texture_tile_per_meter, the
# centerline Curve2D, the bake width/transition, the lighting params and every cliff param
# are all set explicitly here. A designer retuning `config/game_config.tres` — or any
# authored catalogue — cannot make this fail, because none of those values are read.
# It reaches into no catalogue (`CarLibrary` / `RallyLibrary` / …) and asserts nothing about
# any authored entry.
#
# What it pins is the DERIVED OUTPUT OF FIXED SYNTHETIC INPUTS — i.e. "the terrain maths
# changed". That is precisely the thing a refactor claiming to be behaviour-preserving must
# not do, and it is not observable any other way.
#
# HOW TO (RE)RECORD THE GOLDEN VALUE  <-- READ THIS IF THIS TEST IS "PENDING"
# --------------------------------------------------------------------------
# The constants below start EMPTY. With an empty constant the test does not fail — it
# computes the digest, PRINTS it prominently, and marks itself `pending()`. Run:
#
#     ./run_tests.sh --fast test_terrain_digest
#
# and look for the banner lines:
#
#     ===== TERRAIN GOLDEN DIGEST (plain) = <64 hex chars> =====
#     ===== TERRAIN GOLDEN DIGEST (cliffs) = <64 hex chars> =====
#
# Paste each value into the matching constant below (GOLDEN_PLAIN / GOLDEN_CLIFFS) and run
# again; the test then asserts against it on every future run.
#
# RE-RECORDING IS A DELIBERATE ACT. If this test starts failing after a refactor that was
# supposed to preserve stage output, the refactor is wrong — do NOT re-record to get back to
# green. Re-record ONLY when the terrain maths was intentionally changed, and say so.
#
# QUANTISATION / TOLERANCE
# ------------------------
# Raw float bits would flap across platforms and compiler settings for reasons that have
# nothing to do with the refactor, so every float is quantised to QUANT_STEP (1e-4) before
# hashing. 1e-4 m is a tenth of a millimetre on a 1 m terrain cell and ~1/10000 of a colour
# channel: far below anything visible or physically meaningful, but far ABOVE the ~1e-7
# relative noise of single-precision float arithmetic, so genuine maths changes (a reordered
# lerp, a dropped cliff term, a changed sample position) still move the hash. Values sitting
# exactly on a quantisation boundary could in principle flip; with ~40k values per chunk that
# is a theoretical flake we accept in exchange for platform stability. If it ever bites,
# coarsen QUANT_STEP rather than deleting the test.
#
# COVERAGE: both the plain path and a CLIFFED chunk. The cliff fields (`cliff_offsets`, baked
# from the corridor centerline) are the ones most at risk when the corridor moves behind an
# abstraction, so they get their own digest rather than riding along in one.

const ManagerScript := preload("res://scripts/terrain_manager.gd")

# --- PASTE THE RECORDED DIGESTS HERE (see "HOW TO (RE)RECORD" above) ---------------------
const GOLDEN_PLAIN := "160e52a2d4d305f115c66311fd1991bfa7c610846e8a44b5de0a471499b5aaac"
const GOLDEN_CLIFFS := "28c83ab7e5fdaa772ed7ce12116bf08d6925438cb273de9f05666c65dc48ce66"
# -----------------------------------------------------------------------------------------

# Float quantisation step used before hashing (see the tolerance note above).
const QUANT_STEP := 1.0e-4
const QUANT_SCALE := 1.0 / QUANT_STEP

# The two fixed coords digested. (0,0) and (1,0) both straddle the synthetic centerline, so
# each carries road flatten, colour blend and (in the cliff case) cliff offsets.
const DIGEST_COORDS: Array = [Vector2i(0, 0), Vector2i(1, 0)]

# Every synthetic input, spelled out so the digest is a function of THIS FILE and the terrain
# maths, and of nothing else.
const SEED := 20260817
const TILE_PER_METER := 0.125
const LAYER_PARAMS: Array = [[60.0, 1.5], [15.0, 0.4], [3.0, 0.1]]
const TRACK_WIDTH := 7.0
const TRACK_TRANSITION_M := 3.0


func _synthetic_layers() -> Array[TerrainLayer]:
	var out: Array[TerrainLayer] = []
	for params in LAYER_PARAMS:
		var pair: Array = params
		var layer := TerrainLayer.new()
		layer.wavelength_m = float(pair[0])
		layer.amplitude_m = float(pair[1])
		out.append(layer)
	return out


func _synthetic_centerline() -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2(-40.0, 0.0))
	c.add_point(Vector2(150.0, 0.0))
	return c


# A bare, tree-resident TerrainManager with EXPLICIT everything: the cheap seam from
# test_terrain_memory.gd (set_script, defer_initial_build, no focus node), plus every field
# the digest depends on pinned to a literal so no config default can leak in.
func _digest_manager() -> TerrainManager:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.defer_initial_build = true
	add_child_autofree(m)
	# Generation inputs.
	m.noise_seed = SEED
	m.layers = _synthetic_layers()
	m.texture_tile_per_meter = TILE_PER_METER
	# Colour inputs (the `colors` array carries ground tint x baked light in RGB and the road
	# blend in ALPHA, so all of these are digest inputs).
	m.default_cell_color = Color(1.0, 1.0, 1.0)
	m.light_amount = 1.0
	m.sun_dir = Vector3(0.4, 0.9, 0.35).normalized()
	m.sun_color = Color(0.5, 0.5, 0.5)
	m.sky_color = Color(0.5, 0.5, 0.5)
	m.ground_color = Color(0.35, 0.35, 0.35)
	# Explicitly a STAGE: no bounded world, no store, no road network, no lattice snap.
	m.height_quantum = 0.0
	m.chunk_source = null
	m.road_source = null
	# Cliffs off by default here; the cliff digest turns them on via _cliff_manager().
	m.cliff_enabled = false
	m.cliff_wavelength_m = 60.0
	m.cliff_gain = 1.6
	m.cliff_max_height_m = 8.0
	m.cliff_run_m = 6.0
	m.cliff_fade_m = 6.0
	m.cliff_open_radius_m = 4.0
	m.cliff_amount = 1.0
	m.cliff_seed = 4242
	return m


func _cliff_manager() -> TerrainManager:
	var m := _digest_manager()
	m.cliff_enabled = true
	return m


# --- The digest ---------------------------------------------------------------------------

func _q(v: float) -> int:
	return int(round(v * QUANT_SCALE))


# Fold one chunk's mesh-source arrays into `buf` as quantised integers, in a fixed order.
func _accumulate(data: Dictionary, buf: PackedInt32Array) -> void:
	var heights: PackedFloat32Array = data.get("heights", PackedFloat32Array())
	for h in heights:
		buf.append(_q(h))
	var verts: PackedVector3Array = data.get("vertices", PackedVector3Array())
	for v in verts:
		buf.append(_q(v.x))
		buf.append(_q(v.y))
		buf.append(_q(v.z))
	var colors: PackedColorArray = data.get("colors", PackedColorArray())
	for c in colors:
		buf.append(_q(c.r))
		buf.append(_q(c.g))
		buf.append(_q(c.b))
		buf.append(_q(c.a))
	var uv2s: PackedVector2Array = data.get("uv2s", PackedVector2Array())
	for t in uv2s:
		buf.append(_q(t.x))
		buf.append(_q(t.y))
	var indices: PackedInt32Array = data.get("indices", PackedInt32Array())
	for i in indices:
		buf.append(i)


func _digest_of(m: TerrainManager) -> String:
	var buf := PackedInt32Array()
	for c in DIGEST_COORDS:
		var coord: Vector2i = c
		var data := m.compute_chunk_data(coord)
		# Sanity guards only (these rule out a broken build, they pin no value).
		var grid: PackedFloat32Array = data.get("heights", PackedFloat32Array())
		assert_eq(grid.size(), TerrainManager.SAMPLES * TerrainManager.SAMPLES,
			"precondition: %s produced a full-res grid" % coord)
		_accumulate(data, buf)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.to_byte_array())
	return ctx.finish().hex_encode()


# Compare against the recorded golden value, or SELF-RECORD (print + pending) when the
# constant is still empty. See the header for the paste-back instructions.
func _check(label: String, golden: String, actual: String) -> void:
	if golden.is_empty():
		print("")
		print("===== TERRAIN GOLDEN DIGEST (%s) = %s =====" % [label, actual])
		print("Paste it into GOLDEN_%s in tests/headless/test_terrain_digest.gd, then re-run."
			% label.to_upper())
		print("")
		pending("no golden digest recorded for '%s' yet — the value is %s (see the banner above)"
			% [label, actual])
		return
	assert_eq(actual, golden,
		("STAGE TERRAIN OUTPUT CHANGED (%s). compute_chunk_data no longer produces the same "
		+ "heights/vertices/colors/uv2s/indices for fixed synthetic inputs. If this was NOT "
		+ "intended, the change is wrong — do not re-record. See the header of this file.")
		% label)


# --- The two nets --------------------------------------------------------------------------

# The plain stage path: noise + road flatten + colour blend + surface UV2, no cliffs.
func test_stage_chunk_digest_is_unchanged() -> void:
	var m := _digest_manager()
	await m.bake_track(_synthetic_centerline(), TRACK_WIDTH, TRACK_TRANSITION_M)
	assert_false(m.road_blend.is_empty(), "precondition: the synthetic bake produced fields")
	assert_true(m.cliff_offsets.is_empty(), "precondition: cliffs are off on the plain path")
	_check("plain", GOLDEN_PLAIN, _digest_of(m))


# The cliffed path. `cliff_offsets` is baked from the CORRIDOR centerline and folded into the
# height before the road flatten, so it is the field most exposed by moving the corridor
# behind a domain abstraction — hence its own digest rather than sharing the plain one.
func test_cliffed_chunk_digest_is_unchanged() -> void:
	var m := _cliff_manager()
	await m.bake_track(_synthetic_centerline(), TRACK_WIDTH, TRACK_TRANSITION_M)
	assert_true(m._cliffs_active(), "precondition: the cliff pass is armed")
	assert_false(m.cliff_offsets.is_empty(),
		"precondition: the cliff bake stamped offsets — otherwise this digest is the plain one")
	_check("cliffs", GOLDEN_CLIFFS, _digest_of(m))


# A guard on the NET ITSELF: the two digests must differ, or the cliff case is silently
# digesting plain terrain and the cliff half of the net is worthless.
func test_the_cliff_digest_is_not_the_plain_digest() -> void:
	var plain := _digest_manager()
	await plain.bake_track(_synthetic_centerline(), TRACK_WIDTH, TRACK_TRANSITION_M)
	var cliffed := _cliff_manager()
	await cliffed.bake_track(_synthetic_centerline(), TRACK_WIDTH, TRACK_TRANSITION_M)
	assert_ne(_digest_of(plain), _digest_of(cliffed),
		"cliffs must change the produced terrain — otherwise the cliff net proves nothing")


# And a guard that the digest is DETERMINISTIC: two identically-configured managers must
# agree, or a golden value could never be recorded in the first place.
func test_the_digest_is_deterministic_for_identical_inputs() -> void:
	var a := _digest_manager()
	await a.bake_track(_synthetic_centerline(), TRACK_WIDTH, TRACK_TRANSITION_M)
	var b := _digest_manager()
	await b.bake_track(_synthetic_centerline(), TRACK_WIDTH, TRACK_TRANSITION_M)
	assert_eq(_digest_of(a), _digest_of(b),
		"the same synthetic inputs must produce the same terrain, run to run")
