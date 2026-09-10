class_name RallyFixtures
extends RefCounted
# A synthetic rally catalogue for tests, mirroring CarFixtures. Install it
# (install()) to run against a stable, test-owned rally roster that never tracks
# the shipped RALLIES, so adding / renaming / retuning a real rally can't break a
# logic / session / eligibility test. Always restore() in teardown.
#
# The roster spans the axes tests exercise: an open (no-restriction) workhorse
# with events, a drive-mode gate (RWD and FWD), a country gate, a body/engine gate,
# a SPECIAL, and a rally parked outside the others. Restrictions are purely
# CATEGORICAL, like the shipped roster — there is no power band any more (see
# RallyLibrary.ineligibility_reason). All live in the real "home" region (a structural
# id RegionLibrary always ships) so region grouping resolves.
#
# The `map_pos` / `reveal_radius` fields are INERT AUTHORED DATA: they used to place each
# fixture's pin and reveal circle on the diegetic HQ map, but the map — and with it
# RallyLibrary.rally_revealed / lit_sources — is deleted (todo/roguelike-pivot.md). They
# are kept only in step with the shipped RALLIES rows, which still author the same fields
# as dead data; nothing reads either. Events set a very low water_level so track
# generation never has to route around lakes — a fixture stage generates fast and
# deterministically.
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
			# map_pos/reveal_radius are inert authored data (see the header note) — the
			# reveal circle this used to light is deleted with the HQ map.
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
			# The one body-gated fixture (its pin's old "outside the lit circle" placement
			# went with the map).
			"difficulty": 3, "special": false, "map_pos": Vector2(0.50, 0.78),
			"restriction": {"doors_max": 2},  # two-door only — a body gate, not a performance one
			"events": [_event(4001), _event(4002), _event(4003)],
		},
		{
			"id": "fx_showdown", "name": "Fixture Special", "region": "home",
			# No restriction and no completion gate — a test that just wants "a special
			# rally to run" can enter it directly.
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
