class_name SceneTestHelpers
extends RefCounted
# Helpers for tests that need a booted main.tscn but NOT its terrain/track/foliage.
#
# WHY THIS EXISTS — world.gd._ready() generates a full rally track and scatters
# trees + bushes synchronously when main.tscn is instantiated. Under headless
# that is ~15 s of CPU PER INSTANCE (the DFS track search dominates at ~7 s, the
# two foliage scatters another ~7 s). Tests that only inspect the car, HUD or
# cameras don't care about the track's shape or its foliage, so paying that cost
# in every before_each is pure waste.
#
# minimal_world() trims the generation to a 1-turn track with no trees/bushes
# (trees_per_turn = 0 zeroes BOTH fields — bushes reuse the same scatter params),
# cutting the per-instance build to well under a second while still producing a
# fully wired world: car, HUD, cameras and a (short) TrackProgress are all built
# exactly as in the full game. Call it INSTEAD of Config.reset() right before
# instantiating main.tscn.


# Reset Config to the authored baseline, then strip world generation down to the
# cheapest thing that still boots a complete scene. Mutates the live Config
# singleton, so a later Config.reset() (e.g. in another file's before_each)
# restores the full baseline.
static func minimal_world() -> void:
	Config.reset()
	var cfg: GameConfig = Config.data
	cfg.track_turn_count = 1  # shortest track the search reliably places
	cfg.trees_per_turn = 0    # no trees AND no bushes (shared scatter params)
