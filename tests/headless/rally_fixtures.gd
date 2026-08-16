class_name RallyFixtures
extends RefCounted
# A synthetic rally catalogue for tests, mirroring CarFixtures. Install it
# (install()) to run against a stable, test-owned rally roster that never tracks
# the shipped RALLIES, so adding / renaming / retuning a real rally can't break a
# logic / session / eligibility test. Always restore() in teardown.
#
# The roster spans the axes tests exercise: an open (no-restriction) workhorse
# with events, a drive-mode gate (RWD and FWD), a country gate, a body/engine gate,
# a MAP-REVEAL gate (a pin parked outside HQ's lit circle), and a SPECIAL.
# Restrictions are purely CATEGORICAL, like the shipped roster — there is no
# power band any more (see RallyLibrary.ineligibility_reason). All live in the
# real "home" region (a structural id RegionLibrary always ships) so region grouping
# resolves.
#
# `map_pos` is load-bearing here, not decoration: reveal is geometric now
# (RallyLibrary.rally_revealed), so a fixture's PIN POSITION is what decides whether it is
# enterable. Every rally meant to be open from a fresh profile is parked inside HQ's lit
# circle at RallyLibrary.HQ_MAP_POS; fx_gated is deliberately outside it, and fx_open
# authors a wide reveal_radius that reaches fx_gated — so "complete fx_open to open
# fx_gated" is the reveal case a test can exercise. Keep the two facts in sync if you move
# either pin. Positions are well inside 0..1 so no fixture depends on edge clamping. Events set a very low water_level so track generation never
# has to route around lakes — a fixture stage generates fast and deterministically.
#
# Eligibility (RallyLibrary.is_eligible) reads the CAR catalogue, so a test that
# checks eligibility should also CarFixtures.install() its cars; RallyFixtures only
# overrides the rally list.

const RWD := CarLibrary.RWD
const FWD := CarLibrary.FWD
const AWD := CarLibrary.AWD


# A stage event that generates quickly: a short track, no water to route around.
static func _event(seed: int, turn_count := 8) -> Dictionary:
	return {
		"seed": seed, "turn_count": turn_count,
		"forestiness": 0.4, "surface_mix": 0.5, "straightness": 0.6,
		"cliffiness": 0.3, "water_level": -50.0, "terrain_layer1_amplitude": 12.0,
	}


static func rallies() -> Array[Dictionary]:
	var list: Array[Dictionary] = [
		{
			"id": "fx_open", "name": "Fixture Open", "region": "home",
			# Sits inside HQ's lit circle, and lights a WIDE circle of its own so completing
			# it reveals fx_gated — the fixture's one reveal-progression edge.
			"difficulty": 1, "special": false, "map_pos": Vector2(0.50, 0.56),
			"reveal_radius": 0.30,
			"restriction": {},  # open class — the "any rally with events" workhorse
			"events": [_event(1001), _event(1002), _event(1003)],
		},
		{
			"id": "fx_rwd_band", "name": "Fixture RWD Band", "region": "home",
			"difficulty": 2, "special": false, "map_pos": Vector2(0.56, 0.52),
			"restriction": {"drive_mode": RWD},
			"events": [_event(2001), _event(2002), _event(2003)],
		},
		{
			"id": "fx_fwd_band", "name": "Fixture FWD Band", "region": "home",
			"difficulty": 1, "special": false, "map_pos": Vector2(0.44, 0.52),
			"restriction": {"drive_mode": FWD},
			"events": [_event(2101), _event(2102), _event(2103)],
		},
		{
			"id": "fx_country_us", "name": "Fixture US Muscle", "region": "home",
			"difficulty": 2, "special": false, "map_pos": Vector2(0.50, 0.44),
			"restriction": {"country": "US"},
			"events": [_event(3001), _event(3002), _event(3003)],
		},
		{
			"id": "fx_gated", "name": "Fixture Gated", "region": "home",
			# OUTSIDE HQ's lit circle on purpose: dark on a fresh profile, revealed once
			# fx_open is completed (whose reveal_radius reaches this pin).
			"difficulty": 3, "special": false, "map_pos": Vector2(0.50, 0.78),
			"restriction": {"doors_max": 2},  # two-door only — a body gate, not a performance one
			"events": [_event(4001), _event(4002), _event(4003)],
		},
		{
			"id": "fx_showdown", "name": "Fixture Special", "region": "home",
			# Parked inside HQ's lit circle so it is open from the start — a test that just
			# wants "a special rally to run" can enter it without completing anything first.
			"difficulty": 4, "special": true, "map_pos": Vector2(0.42, 0.46),
			"restriction": {},  # open so any car can finish
			"events": [_event(9001), _event(9002), _event(9003)],
		},
	]
	return _deep_copy(list)


static func install() -> void:
	RallyLibrary.override_for_test(rallies())


static func restore() -> void:
	RallyLibrary.reset()


static func _deep_copy(list: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in list:
		out.append(d.duplicate(true))
	return out
