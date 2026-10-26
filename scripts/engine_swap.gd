class_name EngineSwap
extends RefCounted
# Docs: features/engine-swap.md — update in the same change as this file.
# Tests: tests/headless/test_engine_swap.gd, tests/headless/test_save_manager.gd, tests/headless/test_upgrade_library.gd — extend in the same change.
# Pure engine-swap logic: resolve which engine a car is currently running, format
# an engine's layout label, and the mass + weight-distribution math for treating the
# engine as an independent point mass. No scene / save coupling — car.gd applies the result.

# The engine a car is currently running: its swapped-in engine if set, else the
# CarLibrary stock engine id passed in.
static func current_engine_id(owned: Dictionary, stock_id: String) -> String:
	var swapped := String(owned.get("swapped_engine", ""))
	return swapped if not swapped.is_empty() else stock_id


# A layout key formatted for display: uppercased, with any qualifier suffix after
# the first "_" dropped — "v8" -> "V8", "v12_uneven" -> "V12". Layout keys index
# EngineLibrary.FIRING, where a qualified key ("v12_uneven") is a separate firing
# table for the SAME physical layout, so only the leading token is the layout name.
# Derived from the string, so a future qualified table needs no change here. "" if empty.
static func layout_label_from(layout: String) -> String:
	return layout.get_slice("_", 0).to_upper()


# The engine's layout key (EngineLibrary) formatted for display. "" if unknown.
static func layout_label(engine_id: String) -> String:
	return layout_label_from(String(EngineLibrary.by_id(engine_id).get("layout", "")))


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
