extends GutTest
# THE OVERWORLD SKY CROSS-FADE (features/overworld.md -> "Region look").
#
# The overworld's Sky runs shaders/overworld_sky.gdshader — two panorama samplers plus a
# `sky_blend` weight — instead of a PanoramaSkyMaterial, which holds exactly one texture and so
# could only ever SNAP between regions. Crossing a region line now sweeps that weight on the same
# tween as the background/fog colour fade, so the haze and the sky always agree.
#
# Every test here is SCENE-FREE and renderer-free: the fade rule lives in the pure statics
# Overworld.sky_fade_plan / Overworld.sky_live_slot / Overworld.sky_panorama_path precisely so it
# can be exercised without a viewport, a tween or a 15-second world build.
#
# WHAT IS PINNED, and what deliberately is not. The fade DURATION (overworld_region_fade_s) and
# every region's authored `sky_panorama` are tunables / authored content, so nothing here asserts
# a duration or a texture path from the shipped RegionLibrary — the looks below are synthetic
# dictionaries with just the one key the resolver reads. What must hold for ANY reasonable values:
#   - a crossing starts at weight 0 and a completed fade lands exactly on 1 (or, on an alternating
#     slot, exactly on 0) — never somewhere in between;
#   - a crossing arriving MID-fade continues from the weight already on screen, never resetting it
#     discontinuously to 0;
#   - a region authoring no panorama resolves to the configured default, unconditionally, so one
#     region's sky cannot follow the player out of it;
#   - the collapse after a fade leaves the DESTINATION slot holding the region the player is now
#     in, with the weight parked on a clean 0-or-1 for the next crossing.

const OverworldScript := preload("res://scripts/overworld.gd")

const SKY_A := "res://textures/sky_a.png"
const SKY_B := "res://textures/sky_b.png"
const SKY_DEFAULT := "res://textures/sky_default.png"


# --- The first crossing ---------------------------------------------------------------------

func test_first_crossing_starts_at_zero_and_targets_full() -> void:
	var plan := OverworldScript.sky_fade_plan(0.0)
	assert_true(plan["target_b"], "from a clean slate the incoming sky goes into slot B")
	assert_almost_eq(float(plan["from"]), 0.0, 0.0001,
		"the sweep starts at 0 — slot A alone is on screen before a crossing")
	assert_almost_eq(float(plan["to"]), 1.0, 0.0001,
		"and ends fully on the incoming sky, never part-way")


func test_completed_fade_lands_on_the_incoming_slot() -> void:
	var plan := OverworldScript.sky_fade_plan(0.0)
	var landed := float(plan["to"])
	assert_eq(OverworldScript.sky_live_slot(landed), "b",
		"after the fade completes the incoming region's slot is the one on screen")
	assert_true(landed == 0.0 or landed == 1.0,
		"the collapse parks the weight on an exact 0 or 1, so the next crossing starts clean")


# --- The mid-fade crossing ------------------------------------------------------------------

func test_mid_fade_crossing_continues_from_the_live_weight() -> void:
	# A crossing arriving 30% into a fade must pick the sweep up where it is.
	var plan := OverworldScript.sky_fade_plan(0.3)
	assert_almost_eq(float(plan["from"]), 0.3, 0.0001,
		"the new sweep starts from the weight already on screen, not from 0")
	assert_almost_eq(float(plan["to"]), 1.0, 0.0001,
		"and still runs to a full reveal of the incoming sky")


func test_mid_fade_crossing_never_resets_the_weight_to_zero() -> void:
	for w in [0.05, 0.2, 0.5, 0.5001, 0.8, 0.95]:
		var blend := float(w)
		var plan := OverworldScript.sky_fade_plan(blend)
		assert_almost_eq(float(plan["from"]), blend, 0.0001,
			"a crossing at weight %s continues from there — a reset to 0 would pop" % blend)


func test_mid_fade_crossing_overwrites_the_least_visible_slot() -> void:
	# Two samplers cannot hold three skies, so the incoming panorama replaces whichever slot is
	# currently contributing LESS. That caps the visible step at half a unit of weight.
	var low := OverworldScript.sky_fade_plan(0.2)
	assert_true(low["target_b"], "slot A dominates below 0.5, so B takes the incoming sky")
	assert_almost_eq(float(low["to"]), 1.0, 0.0001, "and the weight sweeps towards B")
	var high := OverworldScript.sky_fade_plan(0.8)
	assert_false(high["target_b"], "slot B dominates above 0.5, so A takes the incoming sky")
	assert_almost_eq(float(high["to"]), 0.0, 0.0001, "and the weight sweeps back towards A")


func test_sweep_step_is_never_worse_than_half_a_unit() -> void:
	# The whole point of alternating slots rather than collapsing B into A: the discontinuity a
	# mid-fade crossing can introduce is bounded by how much of the overwritten slot was visible.
	for w in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var blend := float(w)
		var plan := OverworldScript.sky_fade_plan(blend)
		var overwritten_weight: float = blend if bool(plan["target_b"]) else 1.0 - blend
		assert_lte(overwritten_weight, 0.5 + 0.0001,
			"at weight %s the replaced slot contributed at most half the sky" % blend)


func test_plan_clamps_a_weight_outside_the_unit_range() -> void:
	assert_almost_eq(float(OverworldScript.sky_fade_plan(-2.0)["from"]), 0.0, 0.0001,
		"a negative weight cannot leak into the shader uniform")
	assert_almost_eq(float(OverworldScript.sky_fade_plan(3.0)["from"]), 1.0, 0.0001,
		"nor can a weight above 1")


# --- The slot the player is actually looking at ----------------------------------------------

func test_live_slot_follows_the_collapsed_weight() -> void:
	assert_eq(OverworldScript.sky_live_slot(0.0), "a",
		"weight 0 means slot A alone is on screen")
	assert_eq(OverworldScript.sky_live_slot(1.0), "b",
		"weight 1 means slot B alone is on screen")


func test_two_crossings_alternate_slots_and_stay_collapsed() -> void:
	# Crossing, letting it finish, then crossing again: each fade must END on an exact 0 or 1 with
	# the region the player is now in in the live slot.
	var blend := 0.0
	var first := OverworldScript.sky_fade_plan(blend)
	blend = float(first["to"])
	assert_eq(OverworldScript.sky_live_slot(blend), "b",
		"after the first crossing the new region is in slot B")
	var second := OverworldScript.sky_fade_plan(blend)
	blend = float(second["to"])
	assert_eq(OverworldScript.sky_live_slot(blend), "a",
		"the second crossing hands the live sky back to slot A")
	assert_true(blend == 0.0 or blend == 1.0,
		"every completed fade leaves a clean, fully-collapsed weight")


# --- Resolving which panorama a region wants --------------------------------------------------

func test_region_without_a_panorama_falls_back_to_the_default() -> void:
	var look: Dictionary = {}
	assert_eq(OverworldScript.sky_panorama_path(look, SKY_DEFAULT), SKY_DEFAULT,
		"a region authoring no sky gets the configured default, not the last region's sky")


func test_region_with_a_panorama_uses_its_own() -> void:
	var look: Dictionary = {"sky_panorama": SKY_A}
	assert_eq(OverworldScript.sky_panorama_path(look, SKY_DEFAULT), SKY_A,
		"an authored sky wins over the default")


func test_empty_authored_panorama_is_treated_as_absent() -> void:
	var look: Dictionary = {"sky_panorama": ""}
	assert_eq(OverworldScript.sky_panorama_path(look, SKY_DEFAULT), SKY_DEFAULT,
		"an explicitly blank sky_panorama means 'no opinion', not 'no sky'")


func test_resolution_is_unconditional_across_a_crossing() -> void:
	# The documented past bug: a conditional assign let one region's sky follow the player out of
	# it. Leaving a region that authors a sky for one that does not must return to the default.
	var authored: Dictionary = {"sky_panorama": SKY_B}
	var bare: Dictionary = {}
	assert_eq(OverworldScript.sky_panorama_path(authored, SKY_DEFAULT), SKY_B,
		"inside the authored region, its own sky")
	assert_eq(OverworldScript.sky_panorama_path(bare, SKY_DEFAULT), SKY_DEFAULT,
		"and stepping out of it returns to the default — the sky does not follow the player")


func test_no_default_configured_resolves_to_nothing_rather_than_a_stale_sky() -> void:
	assert_eq(OverworldScript.sky_panorama_path({}, ""), "",
		"with neither a region sky nor a default, the caller falls back to the scene's own")


# --- The shader itself -------------------------------------------------------------------------

func test_sky_shader_declares_both_panoramas_and_a_blend_weight() -> void:
	var shader := load("res://shaders/overworld_sky.gdshader") as Shader
	assert_not_null(shader, "the overworld sky shader exists")
	if shader == null:
		return
	var code := shader.code
	assert_true(code.contains("shader_type sky"), "it is a sky shader")
	assert_true(code.contains("panorama_a") and code.contains("panorama_b"),
		"two panorama samplers, so two skies can be on screen at once")
	assert_true(code.contains("sky_blend"), "and a weight to mix them by")
	assert_true(code.contains("SKY_COORDS"),
		"sampled through the engine's own equirectangular mapping, so blend 0 matches the "
		+ "PanoramaSkyMaterial it replaced exactly")


func test_overworld_sky_uses_the_two_panorama_material() -> void:
	# Scene RESOURCE check only — no instantiation, no renderer, no world build.
	var packed := load("res://overworld.tscn") as PackedScene
	assert_not_null(packed, "overworld.tscn loads")
	if packed == null:
		return
	var state := packed.get_state()
	var found := false
	for i in range(state.get_node_count()):
		if state.get_node_name(i) != "WorldEnvironment":
			continue
		for p in range(state.get_node_property_count(i)):
			if state.get_node_property_name(i, p) != "environment":
				continue
			var env := state.get_node_property_value(i, p) as Environment
			assert_not_null(env, "the overworld ships an Environment")
			if env == null or env.sky == null:
				continue
			found = true
			var mat := env.sky.sky_material
			assert_true(mat is ShaderMaterial,
				"the overworld's sky is a two-panorama ShaderMaterial, not a PanoramaSkyMaterial")
			var sm := mat as ShaderMaterial
			if sm != null and sm.shader != null:
				assert_true(sm.shader.resource_path.ends_with("overworld_sky.gdshader"),
					"and it runs the overworld sky shader")
			if sm != null:
				assert_almost_eq(float(sm.get_shader_parameter("sky_blend")), 0.0, 0.0001,
					"it ships fully on slot A, so the first frame looks exactly as it did")
	assert_true(found, "found the overworld's WorldEnvironment sky")


func test_stage_sky_is_untouched_by_the_overworld_material() -> void:
	# The overworld's sub-resources are scene-local COPIES; main.tscn must still be a plain
	# PanoramaSkyMaterial, so nothing here can leak into a stage.
	var packed := load("res://main.tscn") as PackedScene
	assert_not_null(packed, "main.tscn loads")
	if packed == null:
		return
	var state := packed.get_state()
	for i in range(state.get_node_count()):
		if state.get_node_name(i) != "WorldEnvironment":
			continue
		for p in range(state.get_node_property_count(i)):
			if state.get_node_property_name(i, p) != "environment":
				continue
			var env := state.get_node_property_value(i, p) as Environment
			if env == null or env.sky == null:
				continue
			assert_true(env.sky.sky_material is PanoramaSkyMaterial,
				"the STAGE sky is unchanged — the overworld's swap is scene-local")
