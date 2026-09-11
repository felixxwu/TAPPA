class_name CarStats
extends RefCounted
# Docs: features/car-stats.md — update in the same change as this file.
# Tests: tests/headless/test_car_stats.gd — extend in the same change.
#
# THE CAR SPEC SHEET, as data. One ordered list of the stats a car is judged on, plus
# the three things a display needs per stat: how to read it off a car, how to format it,
# and WHICH DIRECTION IS AN IMPROVEMENT. That last one is the whole reason this file
# exists separately from the panel that draws it: "500 is better than 400" is true of
# power and false of weight, and a UI that guesses gets the colours backwards on half
# the sheet. `direction` is the single source of truth for that, so the plain readout,
# the buy-a-car popup and the upgrade confirmation can never disagree about whether a
# change was good news.
#
# Deliberately NOT StatBar (scripts/stat_bar.gd): that draws a 20-block bar scaled
# against the whole roster (CarStatBounds), which answers "how does this car compare
# with the others". This answers "what are this car's numbers, and what would this
# change do to them" — a before/after on absolute figures, where a bar's roster-relative
# scale would hide a small but real gain inside one block.
#
# EVERY FIGURE COMES OFF `UpgradeLibrary.grip_meta`, never the raw CarLibrary entry, so a
# swapped engine, an active boost, the detune slider and a drive-mode override are all
# already folded in. A panel reading the authored entry directly would show the showroom
# car, not the one the player is about to drive.
#
# WHAT THIS SHEET CANNOT SHOW, and why a caller must not rely on it alone. An effect only
# reaches a car's META if `UpgradeLibrary.EFFECTS` marks it `feeds_pw` or `feeds_grip`;
# everything else is applied straight onto the car's LIVE GameConfig by `apply()` and never
# touches the meta at all. Three of the seven boosts are in that second group —
# `shift_time_set` (Quick-shift gearbox), `brake_force_mult` (Big brakes) and `drag_mult`
# (Streamlined body) — and there is no row here for shift time, brake force or drag, so
# taking any of those three moves NOTHING on this sheet. That is not a bug to fix by
# widening `effective_meta`, whose narrow contract is a deliberate safeguard (its own header
# explains it); it is a limit a caller has to cover. `world.gd::_confirm_pick` therefore
# prints the boost's own `BoostLibrary.current_effect_text_for` figure alongside the sheet,
# so a confirmation is never a wall of unchanged numbers.
#
# WHY grip_meta AND NOT effective_meta, which is the more obvious call: `effective_meta`
# deliberately folds in only the effects that feed power-to-weight, and its header says
# so. The GRIP-feeding pair — `tire_compound` and the two `downforce_*` fields, which is
# what `CarLibrary.max_lateral_g` reads — is folded in by `grip_meta`, which returns
# `effective_meta`'s output PLUS those. Read the sheet off `effective_meta` and the Grip
# row goes flat for exactly the two boosts a player expects to move it (Sticky tyres and
# the Aero kit), while every other row stays correct — a silent, plausible-looking wrong
# answer. `grip_meta` is a strict superset, so one call serves the whole sheet.

# Higher-is-better (BETTER), lower-is-better (WORSE), and "neither, don't colour it"
# (NEUTRAL — a categorical stat like the drivetrain, where AWD is not an upgrade over
# RWD, just a different car).
const BETTER := 1
const WORSE := -1
const NEUTRAL := 0

# The sheet, in display order. `unit` is appended to the formatted figure; `decimals`
# is how many the figure carries (grip is the only sub-unit stat, and 1.05 G vs 1.0 G
# is a difference worth seeing). `direction` is the improvement sense described above.
#
# Order matters and is not alphabetical: power and weight lead because they are what a
# player actually chooses between, power-to-weight follows as the figure that combines
# them, and the categorical drivetrain sits last because it is the one row that never
# carries a colour.
const ROWS: Array[Dictionary] = [
	{"id": "power", "label": "Power", "unit": "hp", "decimals": 0, "direction": BETTER},
	{"id": "torque", "label": "Torque", "unit": "Nm", "decimals": 0, "direction": BETTER},
	{"id": "mass", "label": "Weight", "unit": "kg", "decimals": 0, "direction": WORSE},
	{"id": "pw", "label": "Power/weight", "unit": "hp/t", "decimals": 0, "direction": BETTER},
	{"id": "grip", "label": "Grip", "unit": "G", "decimals": 2, "direction": BETTER},
	{"id": "redline", "label": "Redline", "unit": "rpm", "decimals": 0, "direction": BETTER},
	{"id": "durability", "label": "Durability", "unit": "HP", "decimals": 0, "direction": BETTER},
	{"id": "drive", "label": "Drivetrain", "unit": "", "decimals": 0, "direction": NEUTRAL},
]


# The whole sheet for one car, as {stat id: float}. `owned_car` is a saved OwnedCar (or
# {} for a plain catalogue preview) and `meta` its CarLibrary entry — the same pair
# every other effective-stat caller passes.
#
# The drivetrain rides along as a float holding the DriveMode int, so the returned dict
# is uniformly numeric and a caller can diff two sheets without special-casing a type.
# `format` turns it back into "RWD" via CarLibrary.drive_text.
static func values(owned_car: Dictionary, meta: Dictionary) -> Dictionary:
	if meta.is_empty():
		return {}
	var eff := UpgradeLibrary.grip_meta(owned_car, meta)
	var cfg: GameConfig = Config.data
	return {
		"power": CarLibrary.horsepower(eff),
		"torque": float(eff.get("peak_torque", 0.0)),
		"mass": float(eff.get("mass", 0.0)),
		"pw": CarLibrary.power_to_weight_hp_tonne(eff),
		# Rated WITH downforce at the shared reference speed, which is why `label_for`
		# prints that speed on the row: grip grows with v², so the bare number without
		# its speed reads as a promise the car only keeps at one velocity
		# (CarLibrary.max_lateral_g's own header spells this out).
		"grip": CarLibrary.max_lateral_g(eff, cfg, cfg.grip_reference_kmh),
		"redline": float(eff.get("redline", 0.0)),
		"durability": float(eff.get("max_hp", 0.0)),
		"drive": float(int(eff.get("drive_mode", -1))),
	}


# The sheet the car WOULD have if `pick` were taken, for the confirmation popup's "after"
# column. `pick` is a boost entry in `UpgradeLibrary.active_effects`' own shape
# ({"id": String, "effect": Dictionary} — what `BoostLibrary.boost_for` returns), a
# drivetrain conversion ({"drivetrain": DriveMode int}), or an engine swap
# ({"engine_swap": EngineLibrary id}).
#
# PURE PREVIEW. The owned dict is DEEP-duplicated before anything is appended, because the
# dict `Save.get_car` hands back is the live profile reference: appending a candidate boost
# to it would fit the boost for real, and persist a merely-previewed pick into the player's
# save. This is the same trap (and the same fix) that world.gd::_field_car documents at
# length for the run's own boost merge.
#
# Returns the unmodified sheet for an empty or unrecognised `pick`, so a caller that has
# nothing to preview renders a plain single-figure panel rather than an empty one.
static func preview(owned_car: Dictionary, meta: Dictionary, pick: Dictionary) -> Dictionary:
	if meta.is_empty() or pick.is_empty():
		return values(owned_car, meta)
	var probe := owned_car.duplicate(true)
	if pick.has("drivetrain"):
		probe["drivetrain_override"] = int(pick["drivetrain"])
	elif pick.has("engine_swap"):
		# The exact field car.gd::_apply_engine_swap / world.gd::_owned_with_run_effects
		# read for a swapped engine — see features/engine-swap.md.
		probe["swapped_engine"] = String(pick["engine_swap"])
	elif pick.has("effect"):
		var boosts: Array = (probe.get("boosts", []) as Array).duplicate()
		boosts.append(pick)
		probe["boosts"] = boosts
	else:
		return values(owned_car, meta)
	return values(probe, meta)


# The row descriptor for `id`, or {} if it names no stat.
static func row(id: String) -> Dictionary:
	for entry in ROWS:
		if String((entry as Dictionary).get("id", "")) == id:
			return entry
	return {}


# The row's display label. Grip's carries the reference speed it was rated at, read live
# off GameConfig so retuning the speed can never leave the label quoting the old one.
static func label_for(id: String) -> String:
	var entry := row(id)
	if entry.is_empty():
		return ""
	var label := String(entry.get("label", ""))
	if id == "grip":
		return "%s @ %d km/h" % [label, int(round(Config.data.grip_reference_kmh))]
	return label


# The figure as the player reads it: rounded to the row's decimals, with its unit. The
# drivetrain resolves through CarLibrary.drive_text instead — it is an enum wearing a
# float, per `values`. "" for an unknown id.
static func format(id: String, value: float) -> String:
	var entry := row(id)
	if entry.is_empty():
		return ""
	if id == "drive":
		return CarLibrary.drive_text(int(round(value)))
	var unit := String(entry.get("unit", ""))
	var text := "%.*f" % [int(entry.get("decimals", 0)), value]
	return text if unit.is_empty() else "%s %s" % [text, unit]


# Which way is up for this stat: BETTER, WORSE, or NEUTRAL. NEUTRAL for an unknown id
# too, so a caller that has somehow acquired a bad stat id draws it uncoloured rather
# than claiming a change is an improvement.
static func direction(id: String) -> int:
	var entry := row(id)
	if entry.is_empty():
		return NEUTRAL
	return int(entry.get("direction", NEUTRAL))


# Did moving `before` -> `after` make this stat better (+1), worse (-1), or neither (0)?
# NEUTRAL stats and equal figures both answer 0, which is what makes "no colour" and "no
# change" the same case for a display.
#
# The comparison is on the FORMATTED figures, not the raw floats: a change too small to
# survive rounding is not visible to the player, and colouring an apparently identical
# pair red would read as a bug. This is why grip carries two decimals — so a real but
# small grip gain still shows up here rather than being rounded into "no change".
static func change(id: String, before: float, after: float) -> int:
	var dir := direction(id)
	if dir == NEUTRAL:
		return 0
	if format(id, before) == format(id, after):
		return 0
	return dir if after > before else -dir
