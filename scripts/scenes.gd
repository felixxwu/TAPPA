class_name Scenes
extends RefCounted
# The canonical scene paths, and the ONE place that decides which scene is "the hub".
#
# WHY THIS SEAM EXISTS. `hq.tscn` is both the project's main scene and the
# "back to the hub" destination, and that path used to be hardcoded at SEVEN
# transition sites (podium finish, two pause-menu quits, the benchmark end, and
# three in world.gd: free-roam/no-session finish, abandoned rally, challenge run
# end). The overworld hub (see docs/superpowers/specs/2026-08-17-overworld-hq-design.md)
# is a SECOND hub selected by `GameConfig.overworld_enabled`, so every one of
# those transitions must honour the flag — a single missed site sends the player
# to the wrong hub. Routing them all through `hub_path()` makes that impossible
# to get wrong, and gives tests one helper to compare against instead of a
# literal.
#
# `is_hub_scene()` exists for the non-transition coupling: MusicDirector picks
# hub-vs-rally music from the LIVE SCENE PATH (see music_library.gd
# `is_hq_scene`), so the predicate has to accept either hub or the overworld
# would silently play a rally song as its hub theme.

const HQ := "res://hq.tscn"
const OVERWORLD := "res://overworld.tscn"
const MAIN := "res://main.tscn"
const PODIUM := "res://podium.tscn"
const STANDINGS := "res://standings.tscn"


# The scene to load for "return to the hub". OVERWORLD only when the dev flag is
# on; otherwise the shipped HQ, so behaviour with the flag off is unchanged.
static func hub_path() -> String:
	# NEVER the overworld under --headless, whatever the flag says.
	#
	# `overworld_enabled` is a DEV switch a developer leaves on for days, and the test suite reads
	# the same authored config. With it on, every "return to the hub" transition in a test loaded
	# overworld.tscn FOR REAL — which left an `Overworld` under /root, leaked its terrain into the
	# shared physics space, and broke car-settling in unrelated files (caught by
	# tests/headless/test_world_isolation.gd). The suite must be immune to the state of a dev flag,
	# the same rule `hq.gd::_maybe_redirect_to_overworld` follows.
	#
	# This is not hiding the overworld from tests: `test_overworld*` instance the scene directly,
	# which is the honest way to test it, and `Scenes.OVERWORLD` is still reachable by name.
	if Platform.is_headless():
		return HQ
	if Config.data != null and Config.data.overworld_enabled:
		return OVERWORLD
	return HQ


# True for EITHER hub scene, regardless of the flag: a scene path recorded before
# a flag flip (or a live scene the flag doesn't currently select) is still a hub.
static func is_hub_scene(path: String) -> bool:
	return path == HQ or path == OVERWORLD


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
