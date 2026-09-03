extends GutHookScript
# GUT PRE-RUN HOOK (wired via -gpre_run_script in run_tests.sh).
#
# WHY THIS EXISTS: a headless run once OVERWROTE the developer's real save profile
# at user://profile.json with a blank default carrying synthetic fixture cars
# (fx_light_rwd). Any test that mutates the Save autoload without first pointing
# Save.profile_path somewhere throwaway writes the REAL file — and there are dozens
# of tests that instantiate main.tscn or the hub shell (Scenes.hub_path), either of which can
# save from inside the scene's own lifecycle rather than from the test body. Relying
# on every one of those files to remember the redirect is how the data loss happened.
#
# So the run installs a RUN-SCOPED SANDBOX once, up front: Save.test_sandbox_path
# makes the SaveManager remap any attempt to use DEFAULT_PROFILE_PATH onto a
# throwaway file (see scripts/save_manager.gd), so an unredirected test — or a test
# that "restores" the real path in its teardown — is harmless by default. Per-test
# redirects (SaveTestHelpers) still work exactly as before and stay the way a test
# gets its own isolated profile.
#
# The paired post-run hook (save_sandbox_post_hook.gd) asserts the real file was
# genuinely left alone, so a future hole in the sandbox is reported loudly instead
# of costing somebody their career again.

# The one profile file a test run is allowed to write when it does not redirect.
const SANDBOX_PATH := "user://test_run_sandbox_profile.json"

# Meta keys left on the Save autoload for the post-run guard to read.
const META_REAL_PATH := "test_run_real_profile_path"
const META_REAL_MTIME := "test_run_real_profile_mtime"


func run() -> void:
	var save: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("/root/Save")
	if save == null:
		gut.logger.error("Save autoload missing — cannot sandbox the test run's profile writes")
		return
	var real_path: String = save.DEFAULT_PROFILE_PATH
	# Record the real file's state BEFORE any test runs so the post-run guard can tell
	# whether the run touched it. -1 means "did not exist", which is just as valid a
	# baseline as a timestamp: if it exists afterwards, something wrote it.
	save.set_meta(META_REAL_PATH, real_path)
	save.set_meta(META_REAL_MTIME,
		FileAccess.get_modified_time(real_path) if FileAccess.file_exists(real_path) else -1)

	save.test_sandbox_path = SANDBOX_PATH
	# Re-assign the default so the sandbox takes effect immediately (the setter does the
	# remap), then start from a clean default profile inside the sandbox.
	save.profile_path = save.DEFAULT_PROFILE_PATH
	save.save_disabled = false
	save.load_or_new()
	gut.logger.info("profile writes sandboxed to %s for this run" % save.profile_path)

	_suppress_real_scene_changes()
	_sandbox_credentials()


# SECOND run-scoped safety default, hosted here because GUT takes exactly ONE pre-run script.
# Same lesson as the profile sandbox above, learned the same way.
#
# A headless run cannot survive a real change_scene_to_file, and the failure is quiet rather
# than loud: the requested scene is instantiated and parked under /root, where it OUTLIVES the
# test that triggered it, drops its terrain into the shared physics space, and breaks
# car-settling assertions in unrelated files that run much later. test_world_isolation.gd
# catches the parked scene, but only at the end of a run and only by name — it reports WHAT
# leaked, never who.
#
# The seams that existed before were both opt-in and neither was complete:
#   * world.gd's per-instance `scene_change_hook` — every test holding a live main.tscn had to
#     remember to install it, and most do not.
#   * RallySession.auto_load_scenes — LOOKS like the seam for this and is not. It guards
#     start_rally/advance only, while RallySession.abandon() emits rally_finished unguarded and
#     world.gd turns that into a real transition. Several files call abandon() in teardown
#     precisely because it seemed like the safe way to clean up.
#
# So an author had to know which of two partial seams covered a transition they could not
# easily predict was reachable. Making the safe state the DEFAULT removes the guesswork:
# Scenes.change_to is the one point every production transition routes through, so arming this
# flag makes them all inert. Tests asserting WHERE the game tried to go read
# Scenes.last_blocked_path; world.gd's hook still runs first for tests that use it.
func _suppress_real_scene_changes() -> void:
	Scenes.block_real_changes = true
	Scenes.last_blocked_path = ""
	gut.logger.info("real scene changes suppressed for this run (Scenes.block_real_changes)")


# THIRD run-scoped default, same lesson a third time. AuthService writes user://auth.json and
# `sign_out()` DELETES it — and `refresh()` calls sign_out() itself on a non-network rejection.
# Only two test files redirected `auth_path`; five others build an AuthService (or mutate the live
# Cloud.auth) with the real path armed. It had not fired only because those tests all seat an
# expiry an hour out, so `ensure_fresh_token` returns before refreshing — a coincidence, not a
# guard. Meanwhile the suite had already grown workarounds: two leaderboard tests hand-roll
# sign-out as field assignments rather than call sign_out(), and test_cloud_boot_gate.gd explains
# in prose that calling it would delete the real file. Scattered workarounds are the tell that the
# default is wrong, so make the safe state the default here as with the profile and scene changes.
func _sandbox_credentials() -> void:
	AuthService.test_sandbox_path = "user://test_run_sandbox_auth.json"
	gut.logger.info("credential writes sandboxed to %s for this run"
		% AuthService.test_sandbox_path)
