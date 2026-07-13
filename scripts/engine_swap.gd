class_name EngineSwap
extends RefCounted
# Pure engine-swap logic: resolve which engine a car is currently running, format
# the swapped-in name, and the mass + weight-distribution math for treating the
# engine as an independent point mass. No scene / save coupling — Save owns the
# mutations (swap_engines / set_engine_detune) and car.gd applies the result.
# See features/engine-swap.md.

# The engine a car is currently running: its swapped-in engine if set, else the
# CarLibrary stock engine id passed in.
static func current_engine_id(owned: Dictionary, stock_id: String) -> String:
	var swapped := String(owned.get("swapped_engine", ""))
	return swapped if not swapped.is_empty() else stock_id


# The engine's layout key (EngineLibrary) uppercased — "v8" -> "V8". "" if unknown.
static func layout_label(engine_id: String) -> String:
	return String(EngineLibrary.by_id(engine_id).get("layout", "")).to_upper()


# The car's display name, prefixed with the swapped-in engine's layout when the
# car is running a non-stock engine ("V8 Twingo"); the plain name otherwise.
static func display_name(entry: Dictionary, owned: Dictionary) -> String:
	var name := String(entry.get("name", ""))
	var stock := String(entry.get("engine", ""))
	var current := current_engine_id(owned, stock)
	if current != stock and not current.is_empty():
		var label := layout_label(current)
		if not label.is_empty():
			return "%s %s" % [label, name]
	return name


# Total mass with the engine component swapped out: M' = M - m0 + m1.
static func recompute_mass(m_total: float, m_stock_engine: float, m_new_engine: float) -> float:
	return m_total - m_stock_engine + m_new_engine


# Static front-axle weight fraction after swapping the engine (treated as a point
# mass at engine_pos, the fraction of the ENGINE's weight on the front axle):
#   WF' = ((WF*M - m0*EF) + m1*EF) / (M - m0 + m1)
# When EF == WF this reduces to WF (mass-only change).
static func recompute_weight_front(m_total: float, wf: float, m_stock_engine: float,
		m_new_engine: float, engine_pos: float) -> float:
	var new_total := recompute_mass(m_total, m_stock_engine, m_new_engine)
	if new_total <= 0.0:
		return wf
	var chassis_front := wf * m_total - m_stock_engine * engine_pos
	return (chassis_front + m_new_engine * engine_pos) / new_total


# The power-to-weight (kW/kg) `entry`'s car would have after receiving
# `donor_engine_id`'s engine. Previews an owned dict with swapped_engine = donor and
# runs it through the existing effective_meta -> power_to_weight path, which already
# resolves the swapped engine, recomputes mass for the engine-mass delta, and folds
# in installed upgrades (upgrade_library.gd). Pure — no scene / save mutation.
# Returns kW/kg; callers multiply by CarLibrary.KW_KG_TO_HP_TONNE to display hp/tonne.
static func pw_after_swap(owned: Dictionary, entry: Dictionary, donor_engine_id: String) -> float:
	var preview := owned.duplicate(true)
	preview["swapped_engine"] = donor_engine_id
	return CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(preview, entry))


# Two owned cars may exchange engines only when both exist, neither is wrecked,
# and both sit at their CarLibrary max HP (100% health).
static func can_swap(car_a: Dictionary, car_b: Dictionary) -> bool:
	return at_full_health(car_a) and at_full_health(car_b)


# Public health probe: true when the car exists and sits at its CarLibrary max HP.
# A car below full health can still take part in a swap, but only after a Repair
# Kit restores it (the HQ swap flow spends one kit per damaged car — see hq.gd).
static func at_full_health(car: Dictionary) -> bool:
	if car.is_empty():
		return false
	var entry := CarLibrary.by_id(String(car.get("model_id", "")))
	if entry.is_empty():
		return false
	var max_hp := float(entry.get("max_hp", 0.0))
	return max_hp > 0.0 and float(car.get("hp", 0.0)) >= max_hp
