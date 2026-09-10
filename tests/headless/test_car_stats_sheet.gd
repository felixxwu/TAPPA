extends GutTest
# CarStats (scripts/car_stats.gd), the SHEET module — the car spec sheet as data (ROWS,
# values, preview, format, direction, change). NOT the same subject as
# tests/headless/test_car_stats.gd, which is the scene-free half of CarLibrary's OWN
# derived-stat coverage (roster invariants over the shipped CARS table, max_lateral_g /
# horsepower / tire_load_factor). Keep the two apart — this file is CarStats the class,
# that one is CarLibrary.
#
# Per CLAUDE.md, nothing here pins a shipped car's figures or a boost's magnitude: every
# input is a synthetic dict/meta built in the test, and every assertion is about the
# CONTRACT (direction, formatting, change sign, the grip_meta seam, preview's
# non-mutation) rather than a number a designer might retune tomorrow.

const SYNTHETIC_META := {
	"mass": 1200.0, "peak_torque": 300.0, "redline": 6000.0, "max_hp": 800.0,
	"drive_mode": 0, "tire_compound": 0.9,
	"weight_front": 0.5, "downforce_front": 0.0, "downforce_rear": 0.0,
	"wheel_width_front": 0.2, "wheel_width_rear": 0.2,
}


func _synthetic_meta(overrides := {}) -> Dictionary:
	var meta := SYNTHETIC_META.duplicate(true)
	for key in overrides:
		meta[key] = overrides[key]
	return meta


# --- direction -----------------------------------------------------------------

func test_direction_of_mass_is_worse_power_is_better() -> void:
	assert_eq(CarStats.direction("mass"), CarStats.WORSE, "lower mass is an improvement")
	assert_eq(CarStats.direction("power"), CarStats.BETTER, "higher power is an improvement")


func test_direction_of_drive_is_neutral() -> void:
	assert_eq(CarStats.direction("drive"), CarStats.NEUTRAL,
		"drivetrain is categorical, not a better/worse axis")


func test_direction_of_an_unknown_id_is_neutral() -> void:
	assert_eq(CarStats.direction("not_a_real_stat"), CarStats.NEUTRAL)


# --- change --------------------------------------------------------------------

func test_change_is_sign_correct_for_a_worse_stat() -> void:
	assert_eq(CarStats.change("mass", 1200.0, 1400.0), CarStats.WORSE,
		"more mass is a worse change")
	assert_eq(CarStats.change("mass", 1400.0, 1200.0), CarStats.BETTER,
		"less mass is a better change")


func test_change_is_sign_correct_for_a_better_stat() -> void:
	assert_eq(CarStats.change("power", 300.0, 400.0), CarStats.BETTER)
	assert_eq(CarStats.change("power", 400.0, 300.0), CarStats.WORSE)


func test_change_is_zero_for_a_neutral_stat_even_when_the_value_moved() -> void:
	assert_eq(CarStats.change("drive", 0.0, 1.0), 0,
		"drivetrain moved (RWD -> AWD) but has no better/worse sense")


func test_change_is_zero_when_the_figures_round_to_the_same_text() -> void:
	# power has 0 decimals, so a sub-unit move is invisible to the player.
	assert_eq(CarStats.change("power", 300.2, 300.4), 0,
		"a change too small to survive rounding reads as no change")


func test_change_is_zero_for_an_unknown_id() -> void:
	assert_eq(CarStats.change("not_a_real_stat", 1.0, 2.0), 0)


# --- format ----------------------------------------------------------------------

func test_format_drive_renders_via_drive_text_not_a_number() -> void:
	var text := CarStats.format("drive", float(CarLibrary.AWD))
	assert_eq(text, CarLibrary.drive_text(CarLibrary.AWD),
		"drive resolves through CarLibrary.drive_text, not a raw figure")
	assert_false(text.is_valid_float(), "the rendered drivetrain is not a bare number")


func test_format_appends_the_rows_unit() -> void:
	var row := CarStats.row("power")
	var text := CarStats.format("power", 400.0)
	assert_true(text.ends_with(String(row.get("unit", ""))), "power's figure carries its unit")


func test_format_grip_carries_more_decimals_than_a_whole_number_row() -> void:
	var grip_decimals := int(CarStats.row("grip").get("decimals", 0))
	var power_decimals := int(CarStats.row("power").get("decimals", 0))
	assert_gt(grip_decimals, power_decimals,
		"grip is the sub-unit stat; derive from the row's own decimals, not a hardcoded 2")
	var grip_text := CarStats.format("grip", 1.05)
	assert_true(grip_text.begins_with("1.05" if grip_decimals == 2 else "1"),
		"grip's formatted text carries its authored decimal count")


# --- label_for ---------------------------------------------------------------------

func test_label_for_grip_follows_a_live_config_change() -> void:
	var prev := Config.data.grip_reference_kmh
	Config.data.grip_reference_kmh = 77.0
	var label := CarStats.label_for("grip")
	Config.data.grip_reference_kmh = prev
	assert_true(label.contains("77"), "the label quotes the live reference speed, not a stale one")


# --- values ------------------------------------------------------------------------

func test_values_is_empty_for_empty_meta() -> void:
	assert_eq(CarStats.values({}, {}), {}, "no catalogue entry means no sheet")


func test_values_a_heavier_car_has_a_worse_mass_and_lower_power_to_weight() -> void:
	var light := CarStats.values({}, _synthetic_meta({"mass": 1000.0, "max_hp": 800.0}))
	var heavy := CarStats.values({}, _synthetic_meta({"mass": 2000.0, "max_hp": 800.0}))
	assert_gt(heavy["mass"], light["mass"], "the heavier synthetic car reads a higher mass")
	assert_lt(heavy["pw"], light["pw"], "and a lower power-to-weight for the same power")


func test_values_a_grip_feeding_boost_moves_the_grip_row() -> void:
	# Regression test for the grip_meta-not-effective_meta bug: a boost that only feeds
	# tire_grip_mult must still move the Grip row, which reads off grip_meta.
	var meta := _synthetic_meta()
	var plain := CarStats.values({}, meta)
	var boosted := CarStats.values({"boosts": [{"id": "fx_grip", "effect": {"tire_grip_mult": 1.5}}]}, meta)
	assert_gt(boosted["grip"], plain["grip"],
		"a grip-feeding boost must move CarStats' grip row (grip_meta, not effective_meta)")


# --- preview -----------------------------------------------------------------------

func test_preview_does_not_mutate_the_passed_in_owned_dict() -> void:
	var owned := {"boosts": [], "drivetrain_override": -1}
	var meta := _synthetic_meta()
	CarStats.preview(owned, meta, {"id": "fx", "effect": {"peak_torque_mult": 1.2}})
	assert_eq((owned["boosts"] as Array).size(), 0,
		"previewing a boost pick must not append it to the caller's own boosts array")
	assert_eq(int(owned["drivetrain_override"]), -1,
		"previewing must not touch the caller's own drivetrain_override")


func test_preview_of_a_boost_pick_moves_the_stat_it_targets() -> void:
	var meta := _synthetic_meta()
	var before := CarStats.values({}, meta)
	var after := CarStats.preview({}, meta, {"id": "fx", "effect": {"peak_torque_mult": 1.5}})
	assert_gt(after["torque"], before["torque"], "the previewed boost's stat moved")


func test_preview_of_a_drivetrain_pick_moves_the_drive_row() -> void:
	var meta := _synthetic_meta({"drive_mode": CarLibrary.RWD})
	var before := CarStats.values({}, meta)
	var after := CarStats.preview({}, meta, {"drivetrain": CarLibrary.AWD})
	assert_ne(after["drive"], before["drive"], "a drivetrain pick moves the drive row")
	assert_eq(int(after["drive"]), CarLibrary.AWD)


func test_preview_of_an_empty_or_unrecognised_pick_returns_the_plain_sheet() -> void:
	var meta := _synthetic_meta()
	var plain := CarStats.values({}, meta)
	assert_eq(CarStats.preview({}, meta, {}), plain, "an empty pick previews as the plain sheet")
	assert_eq(CarStats.preview({}, meta, {"unrelated_key": 1}), plain,
		"an unrecognised pick shape previews as the plain sheet")
