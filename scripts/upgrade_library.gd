class_name UpgradeLibrary
extends RefCounted
# Docs: features/engine-swap.md, features/forced-induction.md, features/upgrade-catalogue.md — update in the same change as this file.
# Tests: tests/headless/test_engine.gd, tests/headless/test_turbo.gd, tests/headless/test_upgrade_library.gd — extend in the same change.
#
# THE EFFECTS FUNNEL. This file is no longer a catalogue.
#
# It used to own the persistent parts model: an authored `UPGRADES` table, seven
# slots, star gates, prerequisite chains, an auto-build solver, and the
# install/buy paths in Save that fed them. All of that is DELETED by the
# roguelike pivot (todo/roguelike-pivot.md → "What gets deleted" → the persistent
# parts model). Parts are replaced by RR-style boosts: temporary, run-scoped, and
# picked between stages.
#
# What survives is the MECHANISM those parts drove, kept deliberately (see
# todo/roguelike-pivot-plan.md 2a, "keep in place. The catalogue around them goes;
# the funnel stays and becomes the in-run boost applier in stage 5"):
#
#   EFFECTS      — the descriptor table saying what each effect key DOES
#   _cfg_set     — the loud single writer onto a live GameConfig
#   apply        — walks the active effects and writes them (pipeline step 2)
#   effective_meta / grip_meta — the power-to-weight and grip mirrors of the same
#                  table, so a display/rating figure cannot drift from physics
#
# `active_effects` is the SEAM where the input comes from: a car's `boosts` list.
# Nothing writes that key yet, so every loop below runs zero times today — but the
# funnel is live and complete, and stage 5's whole job is to put picked boosts on
# the car dict. Nothing else here needs to change when they arrive.
#
# Also still here: `stock_drive_mode` / `resolve_drive_override`, the drive-mode
# resolver car.gd and effective_meta read. It never depended on the catalogue —
# only on what Save records as paid for.
#
# Distinguish from TUNING: tuning (features/tuning.md) is free, reversible per-car
# config nudges, and is now UNGATED on every axis (decision 24) — the aero gate
# that used to live here went with the aero part.

# --- Effect descriptor table -------------------------------------------------
# The single source of truth for what each `effect` key DOES, so apply() (live cfg)
# and effective_meta() (power-to-weight inputs) can't silently drift — adding an
# effect means adding one row here. Each row:
#   field    — the target GameConfig / meta field ("" for induction)
#   op       — "mult" (field *= val), "add" (field += val), "set" (field = val — an
#              ABSOLUTE figure that replaces the baseline rather than scaling it),
#              "install_induction" (special: enable one flag, clear the rival's, splat the
#              sub-dict), or "write_fields" (splat a sub-dict, no flag)
#   feeds_pw — whether it changes a power-to-weight input (mass / torque), so
#              effective_meta must mirror it; the rest are cfg-only.
#   feeds_grip — whether it changes a MAX-LATERAL-G input (tyre μ / downforce), so
#              grip_meta must mirror it. Separate from feeds_pw because grip does NOT
#              move a car's class: eligibility is judged on power-to-weight alone, and
#              folding grip into effective_meta would let a set of tyres re-gate which
#              rallies a car may enter (see grip_meta).
#
# A "mult"/"add" row may also carry `cfg_fields` — see _cfg_fields — for the case where the
# live config spells the same quantity differently from the meta.
#
# FORCED-INDUCTION rows carry three more keys so the two parts share ONE op rather than a
# copied match arm each (a third induction type would then be a row, not more branches):
#   enable    — the cfg flag this part switches ON
#   clears    — {field: value} the RIVAL part's state is reset to. Turbo and supercharger
#               share the "turbo" slot, so fitting one must un-fit the other. Slot
#               exclusivity in Save._enable_exclusive already means only one can be
#               ENABLED, and the baseline may carry the other from the stock engine — but
#               making the clear SYMMETRIC here keeps it structural rather than resting on
#               that convention, so a future stock engine authoring a real
#               supercharger_boost_gain can't stack both multipliers under a fitted turbo.
#               Values are written as authored (typed), not coerced from a bare `false`.
#   gain_key  — the sub-dict key effective_meta reads to rate the car at peak boost.
#
#   Every name here must EXIST somewhere, and nothing enforces that at runtime:
#   an effect naming something nobody declares applies silently and does nothing —
#   the part reads as fitted and no gameplay test fails. Note the two namespaces:
#   `field` is the CAR META spelling (a key on the car dict, e.g. `tire_compound`),
#   while `cfg_fields`, `clears` and `enable` are LIVE CONFIG spellings and must be
#   `@export`s on GameConfig (scripts/game_config.gd). If you add an effect here,
#   add its target in the same change. `test_upgrade_library.gd` →
#   `test_every_effect_target_name_exists` is the guard.
const EFFECTS := {
	"install_turbo": {
		"field": "", "op": "install_induction", "feeds_pw": true,
		"enable": "turbo_enabled", "gain_key": "turbo_boost_gain",
		# A turbo cancels the blower BOTH ways: the audio flag and the belt gain that
		# switches its physics on (game_config.has_supercharger_physics).
		"clears": {"supercharger_enabled": false, "supercharger_boost_gain": 0.0},
	},
	"install_supercharger": {
		"field": "", "op": "install_induction", "feeds_pw": true,
		"enable": "supercharger_enabled", "gain_key": "supercharger_boost_gain",
		"clears": {"turbo_enabled": false},
	},
	# Nitrous writes its config fields and NOTHING else. feeds_pw is deliberately FALSE:
	# nitrous is a per-stage resource, not a permanent power level, so it must never reach
	# effective_meta's power-to-weight — a bottle the player empties in one stage must not
	# read as a permanent power level anywhere a build is compared or displayed.
	"install_nitrous": {"field": "", "op": "write_fields", "feeds_pw": false},
	"mass_mult":           {"field": "mass", "op": "mult", "feeds_pw": true},
	# Race tyres. `field` names the META spelling (a car's rubber is ONE `tire_compound`
	# coefficient) while `cfg_fields` names the live-config spelling (a PER-AXLE pair, seeded
	# from that same compound by car.gd::_apply_physics_spec and then shifted apart by the
	# grip_balance tuning slider). Multiplying both axles here — before TuningLibrary runs —
	# leaves the player's front/rear balance intact and just scales it.
	"tire_grip_mult": {
		"field": "tire_compound", "op": "mult", "feeds_pw": false, "feeds_grip": true,
		"cfg_fields": ["wheel_friction_slip_front", "wheel_friction_slip_rear"],
	},
	# The SURFACE-DEPENDENT half of the tyre model, and the only pair of effects in this
	# table whose value depends on where the car is (GameConfig.tire_surface_mult applies
	# them; see features/drivetrain-and-tires.md). Meta and config spell them the same, so
	# no cfg_fields override is needed.
	#
	# `mult` rather than `set` deliberately: it makes 1.0 the identity on BOTH sides, so a
	# car with no such compound fitted needs no entry anywhere — the meta key is simply
	# absent (readers default it to 1.0) and the config field is the 1.0 car.gd re-seeds.
	#
	# feeds_grip so grip_meta carries them to the lap-time model; feeds_pw stays FALSE for
	# the same reason the flat compound's does — rubber must never move rally eligibility.
	# Note this does NOT move the menu's GRIP row, which reads `tire_compound` alone: a
	# single headline number cannot honestly state a figure that changes with the surface.
	"tire_snow_grip_mult": {
		"field": "tire_snow_grip_mult", "op": "mult", "feeds_pw": false, "feeds_grip": true,
	},
	"tire_tarmac_grip_mult": {
		"field": "tire_tarmac_grip_mult", "op": "mult", "feeds_pw": false, "feeds_grip": true,
	},
	# Sequential gearbox: an ABSOLUTE shift time, not a scaling of the car's own. "set" is
	# order-independent and idempotent, so unlike "mult" it needs no argument about
	# re-fielding compounding it (shift_time is re-seeded from the fitted engine by
	# EngineLibrary.apply in step 1 either way).
	"shift_time_set":      {"field": "shift_time", "op": "set", "feeds_pw": false},
	"downforce_front":     {"field": "downforce_front", "op": "add", "feeds_pw": false, "feeds_grip": true},
	"downforce_rear":      {"field": "downforce_rear", "op": "add", "feeds_pw": false, "feeds_grip": true},
	# THE TWO `flag` ROWS ARE GONE. `unlocks_aero_tuning` and `unlocks_drivetrain_swap`
	# existed so a fitted part could open a tuning slider; tuning is ungated on every axis
	# now (todo/roguelike-pivot.md decision 24) and there are no parts to fit, so the "flag"
	# op has no rows and no meaning. The `_:` arm in apply() still absorbs an unknown op.
}

# The LIVE-CONFIG fields a "mult"/"add" row writes. Usually just `field`: the meta and the
# config call the quantity by the same name (`mass`, `downforce_front`), so one name serves
# both. `cfg_fields` overrides for a row whose two vocabularies diverge — race tyres are one
# `tire_compound` on a car's meta and two per-axle `wheel_friction_slip_*` fields on the live
# config — which keeps that mapping DATA in the table above rather than a branch in apply().
static func _cfg_fields(desc: Dictionary) -> Array:
	return desc.get("cfg_fields", [String(desc.get("field", ""))])

# --- The active-effect seam ---------------------------------------------------
#
# The effects currently in force on `owned_car`: its `boosts` list, whose entries are
# `{"id": String, "effect": Dictionary}` — the same `effect` sub-dict shape the authored
# parts used, so every consumer below is unchanged.
#
# EMPTY ON EVERY CAR TODAY. Nothing writes `boosts` yet: the persistent parts model that
# used to fill this list is deleted, and the in-run boost picks that replace it land in
# stage 5. Until then `apply`, `effective_meta` and `grip_meta` all run their loops zero
# times, which makes a car exactly its CarLibrary/EngineLibrary baseline plus tuning plus
# damage.
#
# WHY A PLAIN KEY ON THE CAR DICT rather than a query into a run object: it keeps the funnel
# pure and testable with no session standing up, it is the same place `tuning` and
# `swapped_engine` already live, and it means stage 5's job is to WRITE the key (on the
# owned dict handed to Car.apply_owned / Car.refit_upgrades) rather than to re-plumb five
# call sites. It is deliberately NOT persisted by Save: a run's boosts are wiped on run end
# (todo/roguelike-pivot.md, "Soft permadeath"), so they must not survive in the profile.
static func active_effects(owned_car: Dictionary) -> Array:
	return owned_car.get("boosts", [])


# --- Effect application (pipeline step 2) ------------------------------------

# Apply every ACTIVE effect on top of the CarLibrary baseline that apply_car
# already wrote into `cfg` (step 1). Pure: mutates the passed-in live `cfg` only,
# never the authored .tres. Driven by the EFFECTS table above, off whatever
# `active_effects` hands back — empty until stage 5 writes `boosts`, so this is
# currently a no-op on every car.
# Loud write for the apply path. `Object.set()` on a name the config does not
# declare is a SILENT no-op — the part reads as fitted and does nothing, and no
# gameplay test fails (see the EFFECTS header; found by the small-model-readiness
# loop, round 001). This turns that into an error the editor shows immediately.
static func _cfg_set(cfg: GameConfig, field: String, value: Variant) -> void:
	if not (field in cfg):
		push_error("UpgradeLibrary: effect writes GameConfig.%s, which does not exist — write ignored" % field)
		return
	cfg.set(field, value)


static func apply(owned_car: Dictionary, cfg: GameConfig) -> void:
	for entry in active_effects(owned_car):
		var item_id := String((entry as Dictionary).get("id", ""))
		var effect: Dictionary = (entry as Dictionary).get("effect", {})
		for key in effect:
			var val: Variant = effect[key]
			var desc: Dictionary = EFFECTS.get(key, {})
			# AN EFFECT KEY WITH NO `EFFECTS` ROW IS A SILENTLY DEAD EFFECT. `desc` is then {},
			# `op` is "", the match below selects no arm, and the authored value is never
			# written anywhere — the effect reads as active, the config is untouched, and the
			# feature simply does not happen. This is NOT the same failure `_cfg_set` guards:
			# that one catches a write to a field GameConfig does not declare, and it never
			# fires here because the value never reaches it. If you author a new effect key
			# on a boost, YOU MUST ALSO ADD ITS `EFFECTS` ROW — registering the field on
			# GameConfig (an @export, and for a tyre axis a TIRE_SURFACE_AXES row) is not
			# enough on its own. Found by the small-model-readiness loop, round 041, where a
			# wet-weather tyre shipped with the @export, the registry row and the blend arm
			# all correct and no rain grip at all. Guarded by test_upgrade_library.gd ->
			# test_every_authored_effect_key_is_registered_in_the_effects_table.
			if not EFFECTS.has(key):
				push_error("UpgradeLibrary: '%s' authors effect '%s', which has no EFFECTS row — the value is IGNORED and the part does nothing" % [item_id, key])
				continue
			match desc.get("op", ""):
				"install_induction":
					# Turn this part on, turn its slot rival off, then stamp the authored
					# fields. Order matters only in that `clears` runs BEFORE the splat, so
					# a part is free to author the very field it nominally clears.
					_cfg_set(cfg, String(desc["enable"]), true)
					for ckey in (desc["clears"] as Dictionary):
						_cfg_set(cfg, ckey, (desc["clears"] as Dictionary)[ckey])
					for tkey in (val as Dictionary):
						_cfg_set(cfg, tkey, (val as Dictionary)[tkey])
				"write_fields":
					# Straight splat of the authored fields onto the config — no enable
					# flag, no slot rival to clear (has_nitrous() reads the values
					# themselves, so a zero gain/tank IS "not fitted").
					for tkey in (val as Dictionary):
						_cfg_set(cfg, tkey, (val as Dictionary)[tkey])
				"mult":
					for f in _cfg_fields(desc):
						_cfg_set(cfg, f, float(cfg.get(f)) * float(val))
				"add":
					for f in _cfg_fields(desc):
						_cfg_set(cfg, f, float(cfg.get(f)) + float(val))
				"set":
					# Replaces the baseline outright: the authored figure IS the value, so
					# what the car brought to the slot does not enter into it.
					for f in _cfg_fields(desc):
						_cfg_set(cfg, f, float(val))
				_:
					pass  # "flag" (gates tuning sliders) + unknown ids: no cfg effect

# --- Effective car stats (display + eligibility) -----------------------------

# A copy of the CarLibrary entry `meta` with the stats that drive the power-to-
# weight figure (peak_torque, mass) adjusted by the car's ACTIVE EFFECTS, so a
# power or weight boost shifts the displayed hp/tonne.
# Pure: returns a fresh dict, never touches the authored CARS entry. Only the
# meta-level numeric stats are adjusted here; downforce doesn't feed
# power-to-weight, so it is left to the live-config `apply` above.
#
# It does REAL work with no effects at all, which is why it survived the parts
# deletion: it resolves the swapped engine (features/engine-swap.md), rates the
# car at peak boost, and applies the detune slider and the drive-mode override.
static func effective_meta(owned_car: Dictionary, meta: Dictionary) -> Dictionary:
	if meta.is_empty():
		return meta
	var out := meta.duplicate()
	# The CarLibrary entry no longer carries peak_torque/redline — they live in
	# EngineLibrary. Seed the power-to-weight inputs from the referenced engine so
	# the effect multipliers below compound on the real base (and power_to_weight
	# reads the adjusted values off this dict). Only fill what's absent, so a meta
	# that already carries explicit peak_torque/redline (e.g. a synthetic fixture)
	# keeps its own values.
	# Resolve the CURRENT engine (swapped or stock) so a swapped car's torque/redline
	# drive its power-to-weight (features/engine-swap.md). Seed mass off the swap too.
	var stock_id := String(out.get("engine", ""))
	var current_id := EngineSwap.current_engine_id(owned_car, stock_id)
	var eng := EngineLibrary.by_id(current_id)
	if not eng.is_empty():
		# Point the meta at the CURRENT engine so power_to_weight derives from the
		# fitted engine (not the stock one) after a swap.
		out["engine"] = current_id
	if not out.has("peak_torque"):
		out["peak_torque"] = eng.get("peak_torque", 0.0)
	if not out.has("redline"):
		out["redline"] = eng.get("redline_rpm", 0.0)
	if current_id != stock_id and out.has("mass"):
		var stock_eng := EngineLibrary.by_id(stock_id)
		out["mass"] = EngineSwap.recompute_mass(
			float(out["mass"]), float(stock_eng.get("mass", 0.0)), float(eng.get("mass", 0.0)))
	# Resolve the forced-induction boost gain: the stock engine's turbo, overridden by an
	# active induction effect (turbo OR supercharger). Rated "at peak boost" — the
	# displayed HP + power-to-weight eligibility reflect the full boosted torque
	# (features/forced-induction.md).
	var boost_gain := float(eng.get("turbo_boost_gain", 0.0))
	# Mirror only the power-to-weight-feeding effects (EFFECTS[*].feeds_pw), from the
	# same table apply() uses, so the two can't drift.
	for entry in active_effects(owned_car):
		var effect: Dictionary = (entry as Dictionary).get("effect", {})
		for key in effect:
			var desc: Dictionary = EFFECTS.get(key, {})
			if not bool(desc.get("feeds_pw", false)):
				continue
			match desc["op"]:
				"mult":
					var f: String = desc["field"]
					out[f] = float(out.get(f, 0.0)) * float(effect[key])
				"install_induction":
					# Whichever induction effect is active REPLACES the other (apply()
					# clears the rival), so its authored gain supersedes the stock
					# engine's. Which sub-key holds that gain comes from the descriptor, so
					# this arm never needs to know which part it is looking at.
					boost_gain = float((effect[key] as Dictionary).get(
						String(desc["gain_key"]), boost_gain))
	out["peak_torque"] = float(out.get("peak_torque", 0.0)) * (1.0 + boost_gain)
	# Detune scales the torque feeding power-to-weight, after the boost rating.
	var detune := clampf(float(owned_car.get("tuning", {}).get("engine_detune", 1.0)), 0.0, 1.0)
	out["peak_torque"] = float(out.get("peak_torque", 0.0)) * detune
	# Report the player's chosen drivetrain (gated on it being paid for) so display and
	# physics both see the swapped mode. -1 leaves stock in place.
	var drive_override := resolve_drive_override(owned_car)
	if drive_override >= 0:
		out["drive_mode"] = drive_override
	return out

# `effective_meta` plus the GRIP-feeding fields (EFFECTS[*].feeds_grip) — downforce and
# the tyre compound multiplier — for a max-lateral-G readout.
#
# effective_meta deliberately mirrors only the power-to-weight-feeding effects; grip is a
# different axis and is folded in HERE rather than by widening that function's contract,
# because CarLibrary.max_lateral_g reads both downforce and `tire_compound` off the meta it
# is handed while power-to-weight must not see either. Keeping the two calls apart is the
# whole safeguard, and CarPerformance.merged_meta is the one caller that wants both.
#
# (Was `aero_meta`, when downforce was the only thing it folded in.)
static func grip_meta(owned_car: Dictionary, meta: Dictionary) -> Dictionary:
	var out := effective_meta(owned_car, meta)
	if out.is_empty():
		return out
	out = out.duplicate()
	for entry in active_effects(owned_car):
		var effect: Dictionary = (entry as Dictionary).get("effect", {})
		for key in effect:
			var desc: Dictionary = EFFECTS.get(key, {})
			if not bool(desc.get("feeds_grip", false)):
				continue
			var f: String = desc["field"]
			match String(desc["op"]):
				"add":
					out[f] = float(out.get(f, 0.0)) + float(effect[key])
				"mult":
					# 1.0 is the neutral identity a missing compound reads as — the same
					# default CarLibrary.max_lateral_g falls back to.
					out[f] = float(out.get(f, 1.0)) * float(effect[key])
	return out

# The layout a car was BUILT with, which it can always return to for free.
static func stock_drive_mode(owned_car: Dictionary) -> int:
	return int(CarLibrary.for_owned(owned_car).get("drive_mode", CarLibrary.RWD))


# The drive mode the player chose for this car (0/1/2), or -1 meaning "use the car's
# authored stock drive_mode". Gated on the mode being PAID FOR, so a stored override the
# player never bought is inert. The single resolver used by physics (car.gd) and display
# (effective_meta).
static func resolve_drive_override(owned_car: Dictionary) -> int:
	var mode := int(owned_car.get("drivetrain_override", -1))
	if mode < 0:
		return -1
	# Gated on the mode being PAID FOR (Save.drive_mode_available: the car's own stock
	# layout, or one it has bought). A stored override the player has not paid for is inert
	# rather than free, which keeps the price from being bypassed by anything that writes
	# the field directly. MONEY SEAM: nothing sells a conversion right now (the parts-model
	# purchase path is deleted and money lands in stage 6), so in practice only the car's
	# stock layout is available — see Save.drive_mode_available.
	return mode if Save.drive_mode_available(owned_car, mode) else -1

