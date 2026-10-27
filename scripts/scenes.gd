class_name Scenes
extends RefCounted
# Docs: features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_world_isolation.gd, tests/headless/test_menu_nav.gd, tests/headless/test_menu_page.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'Scenes' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).
# The canonical scene paths and the one scene-change point.

const MAIN := "res://main.tscn"
# The title screen (the game's main scene) and the free-roam world it leads into.
const TITLE := "res://title.tscn"
const FREE_ROAM := "res://free_roam.tscn"
# The player's car scene — spawned as the live drivable car, a frozen display prop, or a
# dev-tool subject (exhaust_lab.gd).
const CAR := "res://car.tscn"

# Cached PackedScene for CAR, loaded on first use. `preload()` needs a literal
# string constant — `preload(Scenes.CAR)` does not compile ("Preloaded path must
# be a constant string"), so the three sites that used to `preload()` the car
# scene at compile time now call this instead. It's still only loaded once
# (Godot's own resource cache would dedupe repeat loads anyway), just on first
# use rather than at script-parse time — not a per-call load(), so no hot-path
# regression.
static var _car_scene: PackedScene


static func car_scene() -> PackedScene:
	if _car_scene == null:
		_car_scene = load(CAR)
	return _car_scene


# ==========================================================================================
# The single enforced scene-change point
# ==========================================================================================

# Run-scoped kill switch for REAL scene changes, armed once by the GUT pre-run hook
# (tests/headless/save_sandbox_pre_hook.gd, which hosts every run-scoped safety default
# because GUT allows only one pre-run script) and never set in production.
#
# WHY THIS EXISTS — the same lesson as Save's run-scoped profile sandbox, learned the same
# way. A headless test cannot survive a real change_scene_to_file: it replaces the GUT runner
# scene, and what actually happened is subtler and worse — the new scene is instantiated and
# parked under /root, where it outlives the test that caused it, leaks its terrain into the
# SHARED physics space, and breaks car-settling assertions in unrelated files that run much
# later (see tests/headless/test_world_isolation.gd).
#
# So the default is safe: a test run arms this once and every transition below is inert,
# whether or not the test knew a transition was reachable. Tests that assert on WHERE the
# game wanted to go read `last_blocked_path`. Production never arms it and behaves exactly as before.
static var block_real_changes := false

# The path most recently suppressed by the switch above. Purely diagnostic — it lets a test
# assert the DESTINATION without performing the transition, which is what most of them
# actually wanted to check.
static var last_blocked_path := ""


# Every production scene transition goes through here. Routing them all through one function
# is what makes the kill switch above total: a new transition added anywhere inherits the
# protection instead of quietly reintroducing the leak.
#
# It also UNPAUSES the tree, for every caller: a pause page (settings Wipe, a rest-stop / map
# page, the pause menu) paused the tree to open, and the next scene's CardCarousel tweens and
# MenuNav run on the tree's pause state — arriving paused is a soft-lock. No caller wants to
# stay paused across a change. Done before the test kill switch so tests can assert it.
static func change_to(tree: SceneTree, path: String) -> void:
	tree.paused = false
	if block_real_changes:
		last_blocked_path = path
		return
	# The world builds for seconds before its first frame; without this cover (adopted and freed by
	# free_roam.gd._warm_up) the screen sits blank grey meanwhile.
	if path == FREE_ROAM and not Platform.is_headless():
		tree.root.add_child(LoadingScreen.new())
	tree.change_scene_to_file(path)
