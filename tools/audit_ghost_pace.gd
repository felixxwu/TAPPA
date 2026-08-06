extends Node
# Audit: can the rival ghost's pace solve actually hit its target on every career stage,
# with the CURRENT GameConfig exponents? (features/rival-ghost.md)
#
# This exists because the grip/power split has a structural ceiling. With
# rival_ghost_grip_exponent at 0 the ghost corners at the car's true limit, so the only
# lever left is straight-line pace — and a stage with little straight may not have enough
# to give away. When that happens the solve clamps and falls back to uniform scaling,
# which is the very thing the design rejects. Numbers per stage beat guessing.
#
# Reports two paces per stage:
#   P1     — the fastest classified rival. The ONLY rival a ghost is built for today, so
#            this column is the one that gates shipping.
#   SLOWEST — the slowest classified rival. Not used today; it bounds a future
#            multi-rival field, so a failure here is a warning, not a blocker.
#
# Run headless (no rendering needed):
#   godot --headless --path . res://tools/audit_ghost_pace.tscn

const RivalPace = preload("res://scripts/rival_pace.gd")


func _ready() -> void:
	var cfg: GameConfig = Config.data
	print("ghost-pace audit  grip_exponent=%.2f power_exponent=%.2f skill=[%.2f..%.2f]" % [
		cfg.rival_ghost_grip_exponent, cfg.rival_ghost_power_exponent,
		cfg.rival_ghost_skill_min, cfg.rival_ghost_skill_max])
	print("%-22s %-3s %-9s %-9s %-9s %-8s %-9s" % [
			"rally", "ev", "P1 need", "max@kmin", "max@k.02", "P1", "slowest"])

	var p1_fail := 0
	var _worst_need := 1.0
	var slow_fail := 0
	var stages := 0

	for rally in RallyLibrary.RALLIES:
		var rally_id := String(rally.get("id", "?"))
		var events: Array = rally.get("events", [])
		# Same private path real play uses, so the tracks are the CACHED ones the rival
		# times were derived from.
		var tracks: Array = await RallySession._generate_event_tracks(rally)
		var field := RallyLibrary.generate_opponent_field(rally, tracks, events)
		for ev_i in events.size():
			var event: Dictionary = (events[ev_i] as Dictionary).duplicate()
			event["region"] = rally.get("region", "")
			var track: Dictionary = tracks[ev_i] if ev_i < tracks.size() else {}
			if track.is_empty():
				continue
			stages += 1
			var rows := _classified(field, ev_i)
			if rows.is_empty():
				print("%-24s %-3d (no classified rival)" % [rally_id, ev_i])
				continue
			var fastest: Dictionary = rows[0]
			var slowest: Dictionary = rows[rows.size() - 1]
			var f := _probe(track, event, fastest)
			var s := _probe(track, event, slowest)
			if not bool(f["ok"]):
				p1_fail += 1
			var need := float(f.get("need_k", 1.0))
			if need >= 0.0:
				_worst_need = minf(_worst_need, need)
			else:
				_worst_need = -1.0
			if not bool(s["ok"]):
				slow_fail += 1
			print("%-22s %-3d %-9s %-9s %-9s %-8s %-9s" % [
				rally_id, ev_i,
				"%.3fx" % float(f["pace"]),
				"%.3fx" % float(f["ceil_kmin"]),
				"%.3fx" % float(f["ceil_tiny"]),
				_verdict(f), _verdict(s)])

	print("")
	print("stages audited: %d" % stages)
	print("worst-case skill factor any P1 stage needs: %.3f" % _worst_need)
	print("  -> set rival_ghost_skill_min at or below this for the current exponents")
	print("P1 solves that CLAMPED (blocks shipping): %d" % p1_fail)
	print("slowest-rival solves that clamped (future multi-ghost only): %d" % slow_fail)
	get_tree().quit(1 if p1_fail > 0 else 0)


# Rivals with a real time this event, fastest first — the same filter
# RallySession.current_event_leaders applies (t >= 0 excludes DNFs and wrecks).
func _classified(field: Array, ev_i: int) -> Array:
	var rows: Array = []
	for opp in field:
		var times: Array = opp.get("event_times_ms", [])
		if ev_i >= times.size():
			continue
		var t := int(times[ev_i])
		if t < 0:
			continue
		rows.append({"time_ms": t, "car_id": String(opp.get("car_id", "")),
			"engine_id": String(opp.get("engine_id", ""))})
	rows.sort_custom(func(a, b): return int(a["time_ms"]) < int(b["time_ms"]))
	return rows


# How much slowdown the CURRENT exponents can actually deliver on this stage, at a given
# skill factor: the ratio of the degraded total to the ungraded one. This is the ceiling
# the target has to fit under — if the required pace exceeds it even at a tiny k, the stage
# is structurally unreachable and no bracket widening will fix it.
func _achievable(track: Dictionary, event: Dictionary, meta: Dictionary, k: float) -> float:
	var cfg: GameConfig = Config.data
	var base := LapTimeModel.optimum_ms(track, meta, event)
	if base <= 0:
		return 1.0
	var slowed := LapTimeModel.optimum_ms(track, meta, event,
			pow(k, cfg.rival_ghost_grip_exponent), pow(k, cfg.rival_ghost_power_exponent))
	return float(slowed) / float(base)


# Solve for one rival on one stage and report whether the envelope could actually reach
# the target, or had to clamp.
func _probe(track: Dictionary, event: Dictionary, row: Dictionary) -> Dictionary:
	var entry := CarLibrary.by_id(String(row["car_id"]))
	if entry.is_empty():
		return {"ok": true, "pace": 0.0, "skipped": true}
	var eid := String(row.get("engine_id", ""))
	var owned: Dictionary = {"swapped_engine": eid} if eid != "" else {}
	var meta := UpgradeLibrary.effective_meta(owned, entry)
	var target := int(row["time_ms"])
	var optimum := LapTimeModel.optimum_ms(track, meta, event)
	var pace: RivalPace = RivalPace.solve(track, meta, event, target)
	return {
		"ok": not pace.used_fallback(),
		"pace": (float(target) / float(optimum)) if optimum > 0 else 0.0,
		"k": pace.solved_k(),
		"residual": pace.residual_ms(),
		"ceil_kmin": _achievable(track, event, meta, Config.data.rival_ghost_skill_min),
		"ceil_tiny": _achievable(track, event, meta, 0.02),
		"need_k": _required_k(track, event, meta, float(target) / float(maxi(optimum, 1))),
	}


# The smallest skill factor this stage needs in order to reach `want` slowdown. Bisected on
# the achievable ratio, which is monotonic in k. Returns -1 if even k=0.01 is not enough.
func _required_k(track: Dictionary, event: Dictionary, meta: Dictionary, want: float) -> float:
	if want <= 1.0:
		return 1.0
	if _achievable(track, event, meta, 0.01) < want:
		return -1.0
	var lo := 0.01     # slowest
	var hi := 1.0      # fastest
	for _i in 18:
		var mid := (lo + hi) * 0.5
		if _achievable(track, event, meta, mid) >= want:
			lo = mid   # still slow enough, can afford more skill
		else:
			hi = mid
	return lo


func _verdict(r: Dictionary) -> String:
	if bool(r.get("skipped", false)):
		return "skip"
	if bool(r["ok"]):
		return "ok k=%.2f" % float(r["k"])
	return "CLAMP"
