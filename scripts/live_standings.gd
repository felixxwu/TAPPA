class_name LiveStandings
extends RefCounted
# Docs: features/hud.md, features/stage.md — update in the same change as this file.
# Tests: tests/headless/test_live_standings.gd, tests/headless/test_stage_manager.gd, tests/headless/test_hud.gd — extend in the same change. These are the PRIMARY ones, not all of them: `grep -rn 'LiveStandings' tests/headless/` for the rest.
#
# Pure, scene-free maths behind the permanent in-run standings readout: where the
# player sits in the rival field RIGHT NOW, and how far they are from the next
# position up (or, when they're leading, the cushion they hold over P2). No nodes,
# no Config reads — StageManager feeds it numbers and hands the answer to the HUD.
#
# The model is the one real rally live timing uses: a projection that CARRIES THE
# CURRENT GAP FORWARD. The player's projected finishing time is the leader's total
# plus whatever they are up or down on the leader at this instant — i.e. "if the rest
# of the stage goes like the leader's did". That is deliberately not "extrapolate my
# average pace" (elapsed / fraction), which reads wildly optimistic on a slow opening
# sector and swings every corner; the gap-carry is stable and only moves when the
# player actually gains or loses time.
#
# Everything here is in MILLISECONDS (ints), matching RallySession event times.


# The leader's fraction of stage TIME completed at track progress `frac`, read off the
# per-turn split table StageManager is wired with: `turn_progress[i]` is the progress
# fraction at the end of turn i, `turn_time_frac[i]` the leader's cumulative time
# fraction there. Linearly interpolated between boundaries, with (0, 0) as the implicit
# first point and the table's tail held flat past the last boundary.
#
# Returns -1.0 when there is no usable table — the caller has no projection then, which
# is a real state (a plain dev boot has no rival field at all) and not an error.
static func time_frac_at(frac: float, turn_progress: Array, turn_time_frac: Array) -> float:
	var n: int = mini(turn_progress.size(), turn_time_frac.size())
	if n <= 0:
		return -1.0
	var prev_p := 0.0
	var prev_t := 0.0
	for i in n:
		var p := float(turn_progress[i])
		var t := float(turn_time_frac[i])
		if frac <= p:
			# Degenerate span (two boundaries at the same progress): take the later
			# time rather than dividing by zero.
			if p - prev_p <= 0.0001:
				return t
			var u := (frac - prev_p) / (p - prev_p)
			return prev_t + (t - prev_t) * clampf(u, 0.0, 1.0)
		prev_p = p
		prev_t = t
	return prev_t


# The player's projected finishing time (ms), or -1 when it can't be derived (no split
# table, no leader time). See the gap-carry note in the header: projected = the
# leader's total + the player's live delta to the leader at this progress.
static func project_total_ms(elapsed_ms: int, frac: float, turn_progress: Array,
		turn_time_frac: Array, leader_total_ms: int) -> int:
	if leader_total_ms <= 0:
		return -1
	var tf := time_frac_at(frac, turn_progress, turn_time_frac)
	if tf < 0.0:
		return -1
	var leader_here_ms := int(round(float(leader_total_ms) * clampf(tf, 0.0, 1.0)))
	return maxi(0, leader_total_ms + (elapsed_ms - leader_here_ms))


# Where a projected finishing time slots into the rival field, and the gap that matters.
#
# `rival_times_ms` is every classified rival's event time (ms) — order doesn't matter,
# this sorts its own copy, so callers can hand over whatever RallySession gives them.
#
# Returns:
#   position: 1-based place, counting the player (1 = leading the event)
#   field:    how many cars are classified, INCLUDING the player
#   gap_ms:   distance to the position that matters — the rival directly AHEAD when the
#             player isn't leading (always >= 0: the time they must find), or the
#             cushion back to P2 when they are (also >= 0). `leading` says which.
#   leading:  true when the player is P1, so there is no position above to chase
#
# A tie goes to the player (a rival must be strictly faster to be ahead), which is why
# a run reads P1 off the start line: at zero progress the projection IS the leader's
# time, and the player is on the leader's pace until they lose some of it.
#
# An empty field returns position 1 of 1 with no gap — nothing to compare against.
static func standing(projected_ms: int, rival_times_ms: Array) -> Dictionary:
	var times: Array = []
	for t in rival_times_ms:
		var ms := int(t)
		if ms >= 0:
			times.append(ms)
	times.sort()
	var field: int = times.size() + 1
	if times.is_empty() or projected_ms < 0:
		return {"position": 1, "field": field, "gap_ms": 0, "leading": true}
	var ahead := 0
	for ms in times:
		if ms < projected_ms:
			ahead += 1
	var position := ahead + 1
	if position == 1:
		# Leading: the gap worth showing is the cushion back to the quickest rival.
		return {"position": 1, "field": field, "gap_ms": int(times[0]) - projected_ms,
			"leading": true}
	return {"position": position, "field": field,
		"gap_ms": projected_ms - int(times[ahead - 1]), "leading": false}
