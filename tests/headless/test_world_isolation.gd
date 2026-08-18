extends GutTest
# GUARD: no test may leave a whole GAME SCENE parked under /root.
#
# WHY THIS FILE EXISTS. Several production paths end in
# `get_tree().change_scene_to_file(...)` — RallySession._load_event_scene,
# ChallengeSession.continue_to_next_stage, hq.gd, pause_menu.gd, podium.gd,
# benchmark_mode.gd. Under the headless runner that is not a no-op and it is not
# scoped to the test that triggered it: the requested scene is instantiated and
# added to /root, where NOTHING ever frees it, so it stays for the whole rest of
# the run — in the SAME World3D and the SAME physics space every other test uses.
#
# The damage is silent and order-dependent (green in `--fast <file>`, red in a full
# run), and it is not one failure mode but two:
#   * a settling car lands on the leaked scene's terrain/car colliders instead of
#     the fixture's flat ground, so it rests at a crooked attitude with wildly
#     asymmetric wheel loads and never truly comes to rest
#     (test_live_refit_suspension's tyre-load comparison);
#   * a camera pick ray hits the leaked geometry before its intended target, so
#     picking silently misses (hq.gd `_car_index_at`, exercised by
#     test_menu_flow's HQ car-park tap).
# That is exactly what test_ghost_wiring.gd did: it called
# RallySession.start_rally() with `auto_load_scenes` left at its default `true`.
#
# HOW THIS IS PREVENTED NOW. It is no longer a rule tests must remember. The run's
# pre-run hook (save_sandbox_pre_hook.gd) arms `Scenes.block_real_changes`, and every
# production transition routes through `Scenes.change_to`, so a real scene change
# cannot happen during a test run whether or not the author knew one was reachable.
#
# That replaced two partial, opt-in seams that between them did NOT cover the ground:
# `world.gd`'s per-instance `scene_change_hook` had to be installed per test file, and
# `RallySession.auto_load_scenes` — the one that looks like the seam for this — guards
# start_rally/advance only, while `abandon()` emits `rally_finished` unguarded and
# world.gd turns THAT into a real transition. Tests calling `abandon()` in teardown to
# "clean up" were the ones leaking. Both seams still work and still take precedence;
# they are just no longer load-bearing.
#
# This file remains the backstop: if a scene ever gets parked under /root anyway, the
# suppression has a hole and that should be found, not worked around.
#
# Named `test_world_isolation` deliberately: GUT runs files in directory order, so
# a guard only catches polluters that sort BEFORE it — `world` puts this near the
# end of the run.

# Root scripts of the scenes a stray change_scene_to_file would install. Matched by
# script path rather than node name so a scene rename can't quietly disarm the guard.
const GAME_SCENE_SCRIPTS := [
	"res://scripts/world.gd",     # main.tscn
	"res://scripts/hq.gd",        # hq.tscn
	"res://scripts/overworld.gd", # overworld.tscn
	"res://scripts/podium.gd",    # podium.tscn
	"res://scripts/standings.gd", # standings.tscn
]


func _leaked_scene_names() -> Array:
	var leaked: Array = []
	for child in get_tree().root.get_children():
		var script: Script = child.get_script()
		if script == null:
			continue
		if GAME_SCENE_SCRIPTS.has(script.resource_path):
			leaked.append("%s (%s)" % [child.name, script.resource_path])
	return leaked


func test_no_game_scene_is_parked_under_root() -> void:
	var leaked := _leaked_scene_names()
	assert_eq(leaked, [],
		"an earlier test left a whole game scene under /root — almost certainly a "
		+ "change_scene_to_file that escaped, e.g. start_rally() with "
		+ "RallySession.auto_load_scenes left true. Turn the seam off in that file's "
		+ "before_all/before_each; do NOT relax this guard.")


# The guard above can only fire if the thing it looks for is actually reachable, so
# pin the two seams that make a scene change escapable in the first place. If either
# defaults to something else, the guard's premise (and half the suite's isolation)
# has moved and this should be revisited rather than silently trusted.
func test_the_scene_change_seams_still_exist() -> void:
	assert_true("auto_load_scenes" in RallySession,
		"RallySession still exposes the auto_load_scenes seam tests switch off")
	assert_true("auto_load_scenes" in ChallengeSession,
		"ChallengeSession still exposes the auto_load_scenes seam tests switch off")


# The run-scoped suppression is what makes the guard above pass by CONSTRUCTION rather
# than by every author remembering a rule, so assert it is actually armed. If the pre-run
# hook stops running (or stops setting this), the suite would still look green for a while
# and then start failing in unrelated files — the exact silent, order-dependent breakage
# this whole file exists to make loud.
func test_real_scene_changes_are_suppressed_for_this_run() -> void:
	assert_true(Scenes.block_real_changes,
		"the pre-run hook must arm Scenes.block_real_changes so no production transition "
		+ "can park a live scene under /root mid-run")


# The suppression must SWALLOW the transition and still RECORD where it was headed —
# recording it is what lets a test assert a destination without performing it, which is what
# most of them actually wanted. Asserting the flag alone would pass even if change_to had
# been reduced to a bare `return`, leaving no way to tell a suppressed transition from one
# that was never requested.
func test_a_suppressed_change_records_its_destination() -> void:
	var before := Scenes.last_blocked_path
	Scenes.change_to(get_tree(), Scenes.PODIUM)
	assert_eq(Scenes.last_blocked_path, Scenes.PODIUM,
		"a suppressed transition records the path it wanted, for tests to assert on")
	assert_eq(_leaked_scene_names(), [],
		"and it does NOT actually load the scene")
	Scenes.last_blocked_path = before
