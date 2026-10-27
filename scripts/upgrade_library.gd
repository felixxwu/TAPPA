class_name UpgradeLibrary
extends RefCounted
# Docs: features/engine-swap.md, features/forced-induction.md, features/upgrade-catalogue.md — update in the same change as this file.
# Tests: tests/headless/test_engine.gd, tests/headless/test_turbo.gd, tests/headless/test_upgrade_library.gd — extend in the same change.
#
# THE EFFECTS FUNNEL: the only way anything modifies a car's config.
#
#   EFFECTS      — the descriptor table saying what each effect key DOES
#   _cfg_set     — the loud single writer onto a live GameConfig
#   apply        — walks the active effects and writes them
#
# `active_effects` is the input: a car's `boosts` list, filled by LootRules.fielded on a
# duplicated owned-car dict so it never reaches the saved profile.
#
# `stock_drive_mode` / `resolve_drive_override` are the drive-mode resolver car.gd reads.
#
# Distinguish from TUNING (features/tuning.md): free, reversible per-car config nudges.

# --- Effect descriptor table -------------------------------------------------
# The single source of truth for what each `effect` key DOES; adding an effect means
# adding one row here. Each row:
#   field    — the target GameConfig / meta field ("" for induction)
#   op       — "mult" (field *= val), "add" (field += val), "set" (field = val — an
#              ABSOLUTE figure that replaces the baseline rather than scaling it),
#              "mult_floor" (field = max(field * val, floor_field) — a proportional
#              reduction that can't push the field past a floor; see `floor_field` below),
#              "install_induction" (special: enable one flag and splat the sub-dict),
#              or "write_fields" (splat a sub-dict, no flag)
#
# A "mult"/"add" row may also carry `cfg_fields` — see _cfg_fields — for the case where the
# live config spells the same quantity differently from the meta.
#
# FORCED-INDUCTION rows carry `enable`, the cfg flag the part switches ON, so the two parts
# share ONE op. Turbo and supercharger stack (a real twincharger): EngineSim.step()
# multiplies both factors unconditionally.
#
#   Every name here must EXIST somewhere, and nothing enforces that at runtime:
#   an effect naming something nobody declares applies silently and does nothing.
#   Note the two namespaces: `field` is the CAR META spelling (a key on the car dict,
#   e.g. `tire_compound`), while `cfg_fields` and `enable` are LIVE CONFIG spellings and
#   must be `@export`s on GameConfig. `test_upgrade_library.gd` →
#   `test_every_effect_target_name_exists` is the guard.
const EFFECTS := {
	"install_turbo": {
		"field": "", "op": "install_induction",
		"enable": "turbo_enabled",
	},
	"install_supercharger": {
		"field": "", "op": "install_induction",
		"enable": "supercharger_enabled",
	},
	# Nitrous writes its config fields and NOTHING else.
	"install_nitrous": {"field": "", "op": "write_fields"},
	"mass_mult":           {"field": "mass", "op": "mult"},
	# Lightweight parts (BoostLibrary "lightweight"): a proportional weight cut that can't
	# push a car below min_lightweight_mass — so it's a real upgrade on a heavy car and a
	# genuine no-op on one already at/under
	# the floor, rather than a % that keeps scaling a car that's already light. `floor_field`
	# names the GameConfig field _cfg_set/mult_floor reads the floor from — a LIVE CONFIG
	# spelling like `enable`/`cfg_fields`, not a meta one.
	"mass_mult_floor": {
		"field": "mass", "op": "mult_floor", "floor_field": "min_lightweight_mass",
	},
	# Race tyres. `field` names the META spelling (a car's rubber is ONE `tire_compound`
	# coefficient) while `cfg_fields` names the live-config spelling (a PER-AXLE pair, seeded
	# from that same compound by car.gd::_apply_physics_spec and then shifted apart by the
	# grip_balance tuning slider). Multiplying both axles here — before TuningLibrary runs —
	# leaves the player's front/rear balance intact and just scales it.
	"tire_grip_mult": {
		"field": "tire_compound", "op": "mult",
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
	# These do NOT move the menu's GRIP row, which reads `tire_compound` alone: a
	# single headline number cannot honestly state a figure that changes with the surface.
	"tire_snow_grip_mult": {
		"field": "tire_snow_grip_mult", "op": "mult",
	},
	"tire_tarmac_grip_mult": {
		"field": "tire_tarmac_grip_mult", "op": "mult",
	},
	# Sequential gearbox: an ABSOLUTE shift time, not a scaling of the car's own. "set" is
	# order-independent and idempotent, so unlike "mult" it needs no argument about
	# re-fielding compounding it (shift_time is re-seeded from the fitted engine by
	# EngineLibrary.apply in step 1 either way).
	"shift_time_set":      {"field": "shift_time", "op": "set"},
	"downforce_front":     {"field": "downforce_front", "op": "add"},
	"downforce_rear":      {"field": "downforce_rear", "op": "add"},
	# "set", not "mult": Big brakes replaces the car's own brake_torque with a fixed
	# absolute figure (see run_boost_brake_torque_n) rather than scaling whatever it
	# shipped with, so it lands at the same strength on every car.
	"brake_torque_set": {"field": "brake_torque", "op": "set"},
	# The engine-swap boost's row. peak_torque is the PER-CAR published figure engine.gd
	# builds its curve from (cfg.peak_torque, engine.gd::_torque_at) — a plain mult on it
	# is "a stronger engine was fitted". NOT global_torque_scale: that field is a hidden
	# uniform de-rate (see BoostLibrary's header), never a per-car effect target.
	"engine_power_mult": {"field": "peak_torque", "op": "mult"},
}

# The LIVE-CONFIG fields a "mult"/"add" row writes. Usually just `field`: the meta and the
# config call the quantity by the same name (`mass`, `downforce_front`), so one name serves
# both. `cfg_fields` overrides for a row whose two vocabularies diverge — race tyres are one
# `tire_compound` on a car's meta and two per-axle `wheel_friction_slip_*` fields on the live
# config — which keeps that mapping DATA in the table above rather than a branch in apply().
static func _cfg_fields(desc: Dictionary) -> Array:
	return desc.get("cfg_fields", [String(desc.get("field", ""))])

# --- The active-effect seam ---------------------------------------------------
# The effects in force on `owned_car`: its `boosts` list of `{"id": String, "effect": Dictionary}`.
# Empty means a car is exactly its CarLibrary/EngineLibrary baseline plus tuning plus damage.
static func active_effects(owned_car: Dictionary) -> Array:
	return owned_car.get("boosts", [])


# Whether the "aero" boost (BoostLibrary.CATALOGUE["aero"], the rear wing) is
# currently active on `owned_car` — i.e. present by id in its `boosts` list. Car.gd
# reads this to decide whether to reveal the wing mesh: unlike every other boost
# (a pure GameConfig number), aero also drives a visual, so it needs its own fitted
# check rather than a value car.gd would have to re-derive from active_effects itself.
static func aero_fitted(owned_car: Dictionary) -> bool:
	for entry in active_effects(owned_car):
		if String((entry as Dictionary).get("id", "")) == "aero":
			return true
	return false


# --- Effect application (pipeline step 2) ------------------------------------

# Apply every ACTIVE effect on top of the CarLibrary baseline that apply_car
# already wrote into `cfg` (step 1). Pure: mutates the passed-in live `cfg` only,
# never the authored .tres. Driven by the EFFECTS table above, off whatever
# `active_effects` hands back — a no-op outside a run, when nothing has written `boosts`.
# Loud write for the apply path. `Object.set()` on a name the config does not
# declare is a SILENT no-op — the part reads as fitted and does nothing, and no
# gameplay test fails (see the EFFECTS header; found by the small-model-readiness
# loop, round 001). This turns that into an error the editor shows immediately.
static func _cfg_set(cfg: GameConfig, field: String, value: Variant) -> void:
	if not (field in cfg):
		push_error("UpgradeLibrary: effect writes GameConfig.%s, which does not exist — write ignored" % field)
		return
	cfg.set(field, value)


# A "mult_floor" row's clamp floor, read off whichever config source the caller has
# (apply() has a live `cfg`). A missing/typo'd `floor_field`, or one naming a
# GameConfig property that doesn't exist, degrades to NO clamp (mass_mult behaves like a
# plain "mult") rather than a silent 0.0 floor or a crash — same "effect reads as active,
# nothing enforces it" failure shape _cfg_set guards against for a write, just for a read.
static func _floor_value(source: Object, desc: Dictionary) -> float:
	var floor_field := String(desc.get("floor_field", ""))
	if floor_field.is_empty() or not (floor_field in source):
		push_error("UpgradeLibrary: mult_floor row names floor_field '%s', which does not exist on GameConfig — clamp disabled" % floor_field)
		return -INF
	return float(source.get(floor_field))


# --- The reseed pre-pass -----------------------------------------------------
#
# Every row today targets a PER-CAR field, which car.gd's apply_car re-seeds from the
# CarLibrary baseline before apply() runs, so a "mult" always lands on a fresh value.
# A row that writes a GLOBAL tunable has no such re-seed — Config.data is long-lived — so
# it must carry `reseed: true`, and this restores it from the authored .tres
# (Config.authored_value) first. Without that, each fielding would compound the effect
# and removing it would never give the authored number back.
static func _reseed_globals(cfg: GameConfig) -> void:
	for key in EFFECTS:
		var desc: Dictionary = EFFECTS[key]
		if not bool(desc.get("reseed", false)):
			continue
		for field in _cfg_fields(desc):
			var field_name := String(field)
			if field_name == "":
				continue
			_cfg_set(cfg, field_name, Config.authored_value(field_name, cfg.get(field_name)))


static func apply(owned_car: Dictionary, cfg: GameConfig) -> void:
	_reseed_globals(cfg)
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
					# Turn this part on and stamp its authored fields. Does NOT clear a rival
					# induction part any more — turbo and supercharger stack (a real
					# twincharger) now that they're mid-run boosts rather than sharing one
					# purchase slot; see this table's own header for why.
					_cfg_set(cfg, String(desc["enable"]), true)
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
				"mult_floor":
					# Same as "mult", but never pushes the field past floor_field.
					var floor_val := _floor_value(cfg, desc)
					for f in _cfg_fields(desc):
						_cfg_set(cfg, f, maxf(float(cfg.get(f)) * float(val), floor_val))
				"add":
					for f in _cfg_fields(desc):
						_cfg_set(cfg, f, float(cfg.get(f)) + float(val))
				"set":
					# Replaces the baseline outright: the authored figure IS the value, so
					# what the car brought to the slot does not enter into it.
					for f in _cfg_fields(desc):
						_cfg_set(cfg, f, float(val))
				_:
					pass  # unknown ops: no cfg effect

# The layout a car was BUILT with, which it can always return to for free.
static func stock_drive_mode(owned_car: Dictionary) -> int:
	return int(CarLibrary.for_owned(owned_car).get("drive_mode", CarLibrary.RWD))


# The drive mode the player chose for this car (0/1/2), or -1 meaning "use the car's
# authored stock drive_mode". Written onto the fielded owned-car dict by LootRules.fielded.
static func resolve_drive_override(owned_car: Dictionary) -> int:
	var mode := int(owned_car.get("drivetrain_override", -1))
	if mode < 0:
		return -1
	return mode if Drivetrain.DriveMode.values().has(mode) else -1

