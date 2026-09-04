class_name Scenes
extends RefCounted
# Docs: features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_menu_flow.gd, tests/headless/test_menu_nav.gd, tests/headless/test_menu_page.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'Scenes' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).
# The canonical scene paths, and the ONE place that decides which scene is "the hub".
#
# WHY THIS SEAM EXISTS. The hub scene is both the project's main scene and the
# "back to the hub" destination, and that path used to be hardcoded at SEVEN
# transition sites (podium finish, two pause-menu quits, the benchmark end, and
# three in world.gd: free-roam/no-session finish, abandoned rally, challenge run
# end). Routing them all through `hub_path()` means a new hub shell is swapped in
# at ONE line, and gives tests one helper to compare against instead of a literal.
# That is exactly what the roguelike pivot needed: `hq.tscn` and `overworld.tscn`
# were both deleted in stage 2b (todo/roguelike-pivot-plan.md) and only this file
# had to learn the replacement.
#
# `is_hub_scene()` exists for the non-transition coupling: MusicDirector picks
# hub-vs-rally music from the LIVE SCENE PATH (see music_library.gd
# `is_hq_scene`), so the predicate has to agree with `hub_path()` or the hub would
# silently play a rally song as its theme. There is one hub again today, so the
# two collapse to the same constant — keep them as separate functions anyway:
# the pivot may reintroduce a second shell, and the callers are already routed.

# The hub shell. A PLACEHOLDER today (hub.tscn is a Control and a label) — stage 3
# of the pivot replaces the file, not this constant.
const HUB := "res://hub.tscn"
const MAIN := "res://main.tscn"
# PODIUM and STANDINGS are DELETED, not renamed: podium.tscn (decision 19) and
# standings.tscn (decision 30) no longer exist, so the constants were paths to nothing —
# a load() away from a crash for anyone who trusted them. The run summary is a HubShell
# page and the between-stage beat is RunPickPanel; neither is a scene.
# The player's car scene — spawned as the live drivable car (car.gd), a frozen
# display prop (HQ/podium/wreck), or a dev-tool subject (exhaust_lab.gd,
# bake_car_silhouettes.gd). Used to be "res://car.tscn" hardcoded at seven sites
# under three different local names (CAR_SCENE / CAR_SCENE_PATH / WRECK_CAR_SCENE);
# this is now the one definition, same as HUB/MAIN above.
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


# The scene to load for "return to the hub". One shell today; the indirection is
# what let the hub be swapped out without touching the six transition sites.
static func hub_path() -> String:
	return HUB


# True for the hub shell. Kept as a predicate rather than an `==` at every call site
# so a second shell (or a versioned path) stays a one-line change here.
static func is_hub_scene(path: String) -> bool:
	return path == HUB


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
# world.gd already had a per-instance `scene_change_hook` seam for this, but it was OPT-IN:
# every test holding a live world had to remember to install it, and dozens don't. Worse, the
# obvious-looking seam — RallySession.auto_load_scenes — does NOT cover this path at all: it
# guards start_rally/advance, while RallySession.abandon() emits rally_finished unguarded and
# world.gd turns THAT into a real transition. Two seams, neither complete, and a test author
# had no way to know which one they needed.
#
# So the default is now safe: a test run arms this once and every transition below is inert,
# whether or not the test knew a transition was reachable. Tests that assert on WHERE the
# game wanted to go read `last_blocked_path` (or keep using world.gd's hook, which still
# intercepts first). Production never arms it and behaves exactly as before.
static var block_real_changes := false

# The path most recently suppressed by the switch above. Purely diagnostic — it lets a test
# assert the DESTINATION without performing the transition, which is what most of them
# actually wanted to check.
static var last_blocked_path := ""


# Every production scene transition goes through here. Routing them all through one function
# is what makes the kill switch above total: a new transition added anywhere inherits the
# protection instead of quietly reintroducing the leak.
static func change_to(tree: SceneTree, path: String) -> void:
	if block_real_changes:
		last_blocked_path = path
		return
	tree.change_scene_to_file(path)
