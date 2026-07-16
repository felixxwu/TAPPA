class_name MusicSchedule
extends RefCounted
# Pure timing math for the interactive music loop scheduler. No nodes, no
# AudioServer, no state — every function takes bpm/time as arguments so it is
# fully unit-testable headless. See features/music.md for the model.
#
# File structure contract (4/4): every song is 8 bars lead-in + 32 bars main
# loop + 8 bars lead-out. The main loop is what repeats; lead-in/lead-out are
# summed (full volume) across the seam. bpm is per-song, so bar duration is
# derived per call, never a global constant.

const BEATS_PER_BAR := 4.0
const LEAD_IN_BARS := 8.0
const MAIN_LOOP_BARS := 32.0
const LEAD_OUT_BARS := 8.0
const EPS := 0.001  # keeps clamped late-comp strictly inside the lead-in


static func sec_per_bar(bpm: float) -> float:
	return (60.0 / bpm) * BEATS_PER_BAR


static func lead_in_sec(bpm: float) -> float:
	return sec_per_bar(bpm) * LEAD_IN_BARS


static func loop_body_sec(bpm: float) -> float:
	return sec_per_bar(bpm) * MAIN_LOOP_BARS


# Wall-clock time at which the incoming song's voice must START so that its
# lead-in ENDS exactly at next_handoff (where its main loop begins).
static func fire_start(next_handoff: float, incoming_bpm: float) -> float:
	return next_handoff - lead_in_sec(incoming_bpm)


static func should_fire(now: float, start: float) -> bool:
	return now >= start


# Late-compensation offset (wufo3's sampleStart): how far past `start` we are,
# clamped to [0, lead_in) so we only ever skip into the lead-in, never the loop.
static func late_by(now: float, start: float, incoming_bpm: float) -> float:
	return clampf(now - start, 0.0, lead_in_sec(incoming_bpm) - EPS)


# After launching a song, the next handoff is one of ITS main loops later.
static func advance_handoff(next_handoff: float, launched_bpm: float) -> float:
	return next_handoff + loop_body_sec(launched_bpm)


# First-play grid seed: the first main loop begins at play_now + lead_in, and the
# first handoff is one loop body after that.
static func seed_handoff(play_now: float, bpm: float) -> float:
	return play_now + lead_in_sec(bpm) + loop_body_sec(bpm)


# Web/native stall guard: if `now` blew past the handoff, advance it (by whole
# loop bodies of the current song) until fire_start is at most one lead-in in the
# past — dropping the missed re-trigger rather than skipping into a loop body.
static func catch_up(next_handoff: float, now: float, bpm: float) -> float:
	var nh := next_handoff
	while now > nh:
		nh = advance_handoff(nh, bpm)
	return nh
