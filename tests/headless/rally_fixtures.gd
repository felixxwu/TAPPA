class_name RallyFixtures
extends RefCounted
# A synthetic rally catalogue for tests, mirroring CarFixtures. Install it
# (install()) to run against a stable, test-owned rally roster that never tracks
# the shipped RALLIES, so adding / renaming / retuning a real rally can't break a
# logic / session / eligibility test. Always restore() in teardown.
#
# The roster spans the axes tests exercise: an open (no-restriction) workhorse
# with events, a drive-mode + power-band gate (RWD and FWD), a country gate, an
# intra-region reveal gate (reveal_after), and a showdown. All live in the real
# "home" region (a structural id RegionLibrary always ships) so region/reveal
# grouping resolves. Events set a very low water_level so track generation never
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
			"difficulty": 1, "showdown": false, "map_pos": Vector2(0.2, 0.7),
			"restriction": {},  # open class — the "any rally with events" workhorse
			"events": [_event(1001), _event(1002), _event(1003)],
		},
		{
			"id": "fx_rwd_band", "name": "Fixture RWD Band", "region": "home",
			"difficulty": 2, "showdown": false, "map_pos": Vector2(0.4, 0.6),
			"restriction": {"drive_mode": RWD, "pw_min": 150.0, "pw_max": 270.0},
			"events": [_event(2001), _event(2002), _event(2003)],
		},
		{
			"id": "fx_fwd_band", "name": "Fixture FWD Band", "region": "home",
			"difficulty": 1, "showdown": false, "map_pos": Vector2(0.3, 0.55),
			"restriction": {"drive_mode": FWD, "pw_min": 80.0, "pw_max": 140.0},
			"events": [_event(2101), _event(2102), _event(2103)],
		},
		{
			"id": "fx_country_us", "name": "Fixture US Muscle", "region": "home",
			"difficulty": 2, "showdown": false, "map_pos": Vector2(0.5, 0.4),
			"restriction": {"country": "US", "pw_min": 150.0, "pw_max": 300.0},
			"events": [_event(3001), _event(3002), _event(3003)],
		},
		{
			"id": "fx_gated", "name": "Fixture Gated", "region": "home",
			"difficulty": 3, "showdown": false, "reveal_after": 2,
			"map_pos": Vector2(0.6, 0.3),
			"restriction": {"pw_min": 200.0, "pw_max": 320.0},
			"events": [_event(4001), _event(4002), _event(4003)],
		},
		{
			"id": "fx_showdown", "name": "Fixture Showdown", "region": "home",
			"difficulty": 4, "showdown": true, "map_pos": Vector2(0.5, 0.1),
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
