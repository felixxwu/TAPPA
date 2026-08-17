extends GutTest
# Tyre mirroring in the rival field (features/rally-roster.md): every rival runs whatever
# rubber the player runs, so a surface-specialised compound cannot buy the player time the
# performance rating never charged for.
#
# The rating benchmarks at a FROZEN grip, so it structurally cannot price a tyre whose
# value depends on the stage. Matching the field cancels the term instead of pricing it.
#
# Nothing here pins an authored value: no test asserts which tyres exist, what their
# multipliers are, or which is faster. The assertions are about the MECHANISM — the
# player's tyre reaches the rivals, the surface terms survive the meta merge, and the
# stored build matches the one the time was solved from.

const SNOW := "tire_snow_grip_mult"
const TARMAC := "tire_tarmac_grip_mult"


# Any catalogue part in the tyre slot that actually carries a surface term. Found by
# SEARCHING the catalogue rather than naming an id, so retuning or renaming the tyres
# can't break this file (CLAUDE.md).
func _surface_tire_id() -> String:
	for part in UpgradeLibrary.all():
		if String(part.get("slot", "")) != UpgradeLibrary.TIRE_SLOT:
			continue
		var effect: Dictionary = part.get("effect", {})
		if effect.has(SNOW) or effect.has(TARMAC):
			return String(part.get("id", ""))
	return ""


func _owned_with(tire_id: String) -> Dictionary:
	var installed: Array = [] if tire_id == "" else [tire_id]
	return {"installed_upgrades": installed, "disabled_upgrades": []}


# The whole feature rests on this: if merged_meta drops the surface terms, the mirroring
# still "works" but every rival solves at the 1.0 identity and the fix is a silent no-op.
# That is exactly how it was broken before, so assert the carrier, not just the caller.
func test_merged_meta_carries_the_surface_tire_terms() -> void:
	var tire_id := _surface_tire_id()
	if tire_id == "":
		pass_test("no surface-specialised tyre in the catalogue; nothing to carry")
		return
	var base := {"mass": 1200.0, "tire_compound": 1.0}
	var meta := CarPerformance.merged_meta(_owned_with(tire_id), base)
	var effect: Dictionary = UpgradeLibrary.by_id(tire_id).get("effect", {})
	for key in [SNOW, TARMAC]:
		if effect.has(key):
			assert_true(meta.has(key),
				"%s must survive the meta merge or the rival field never sees it" % key)
			assert_ne(float(meta[key]), 1.0,
				"%s reached the meta as the identity — the part did not apply" % key)


# The rating must NOT move, or mirroring would quietly re-tier every car. It cannot move:
# the benchmark passes a frozen mu_override that bypasses the surface model entirely.
func test_carrying_the_surface_terms_leaves_the_rating_untouched() -> void:
	var tire_id := _surface_tire_id()
	if tire_id == "":
		pass_test("no surface-specialised tyre in the catalogue")
		return
	var base := {"mass": 1200.0, "tire_compound": 1.0}
	var plain := CarPerformance.merged_meta({}, base).duplicate()
	var with_tire := CarPerformance.merged_meta(_owned_with(tire_id), base).duplicate()
	# Neutralise every term the rating IS allowed to see, leaving only the surface ones.
	for key in with_tire.keys():
		if key != SNOW and key != TARMAC:
			with_tire[key] = plain.get(key, with_tire[key])
	assert_eq(CarPerformance.rating(with_tire), CarPerformance.rating(plain),
		"the surface tyre terms must stay invisible to the frozen-grip benchmark")


# --- The mirror itself ------------------------------------------------------------

func test_player_tire_id_reads_the_fitted_tyre() -> void:
	var tire_id := _surface_tire_id()
	if tire_id == "":
		pass_test("no surface-specialised tyre in the catalogue")
		return
	assert_eq(RallyLibrary.player_tire_id(_owned_with(tire_id)), tire_id)


func test_player_tire_id_reads_stock_as_empty() -> void:
	assert_eq(RallyLibrary.player_tire_id(_owned_with("")), "",
		"a car with nothing in the tyre slot is running stock")
	assert_eq(RallyLibrary.player_tire_id({}), "",
		"an absent car dict must not claim a fitted tyre")


# A tyre parked in the garage (installed but disabled) is not being run, so the field
# must not run it either.
func test_a_disabled_tyre_is_not_mirrored() -> void:
	var tire_id := _surface_tire_id()
	if tire_id == "":
		pass_test("no surface-specialised tyre in the catalogue")
		return
	assert_eq(RallyLibrary.player_tire_id({
		"installed_upgrades": [tire_id], "disabled_upgrades": [tire_id],
	}), "", "a disabled tyre is not fitted and must not reach the rivals")


# The swap replaces the slot rather than stacking on it — one tyre per car, and the rest
# of the rival's build must survive untouched.
func test_swapping_tyres_replaces_the_slot_and_keeps_everything_else() -> void:
	var tire_id := _surface_tire_id()
	if tire_id == "":
		pass_test("no surface-specialised tyre in the catalogue")
		return
	# A second, different tyre stands in for whatever the rival had drawn.
	var other := ""
	for part in UpgradeLibrary.all():
		var pid := String(part.get("id", ""))
		if String(part.get("slot", "")) == UpgradeLibrary.TIRE_SLOT and pid != tire_id:
			other = pid
			break
	var non_tire := ""
	for part in UpgradeLibrary.all():
		if String(part.get("slot", "")) != UpgradeLibrary.TIRE_SLOT:
			non_tire = String(part.get("id", ""))
			break
	var drawn: Array = []
	if other != "":
		drawn.append(other)
	if non_tire != "":
		drawn.append(non_tire)

	var mirrored := RallyLibrary._with_tires(drawn, tire_id)
	var tyres := 0
	for item_id in mirrored:
		if UpgradeLibrary.slot_of(String(item_id)) == UpgradeLibrary.TIRE_SLOT:
			tyres += 1
	assert_eq(tyres, 1, "a rival must end up with exactly one tyre fitted")
	assert_true(mirrored.has(tire_id), "the rival should be wearing the player's tyre")
	if other != "":
		assert_false(mirrored.has(other), "the drawn tyre should have been replaced")
	if non_tire != "":
		assert_true(mirrored.has(non_tire),
			"mirroring must not disturb the rest of the rival's build")


# Stock strips the slot rather than leaving the drawn tyre in place — "snow if you are,
# stock if not".
func test_a_stock_player_strips_the_rivals_tyres() -> void:
	var tire_id := _surface_tire_id()
	if tire_id == "":
		pass_test("no surface-specialised tyre in the catalogue")
		return
	var mirrored := RallyLibrary._with_tires([tire_id], "")
	var tyres := 0
	for item_id in mirrored:
		if UpgradeLibrary.slot_of(String(item_id)) == UpgradeLibrary.TIRE_SLOT:
			tyres += 1
	# Asserted as a COUNT rather than inside the loop: stripping works by leaving no
	# tyre behind, so a per-element assertion runs zero times and the test would pass
	# by never checking anything.
	assert_eq(tyres, 0, "a stock player leaves the field on stock tyres too")
