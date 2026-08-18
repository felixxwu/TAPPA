extends GutTest
# The profile SANDBOX that keeps a test run off the developer's real save file.
#
# A headless run once overwrote user://profile.json with a blank default carrying
# synthetic fixture cars, because a test mutated the live Save autoload without
# redirecting profile_path first. The run is now sandboxed once, up front, by GUT's
# pre-run hook (tests/headless/save_sandbox_pre_hook.gd + the test_sandbox_path seam
# in scripts/save_manager.gd), and the post-run hook checks the real file's mtime.
#
# These tests assert the SEAM's behaviour — not that the hook is wired, which is
# run_tests.sh's job — so they hold whether or not the run installed a sandbox.

const PreHook = preload("res://tests/headless/save_sandbox_pre_hook.gd")

var _save: Node
var _saved_sandbox := ""
var _saved_path := ""


func before_each() -> void:
	_save = get_node("/root/Save")
	_saved_sandbox = _save.test_sandbox_path
	_saved_path = _save.profile_path


func after_each() -> void:
	_save.test_sandbox_path = _saved_sandbox
	_save.profile_path = _saved_path


func test_a_sandbox_remaps_the_default_profile_path() -> void:
	# The whole point: a test (or a scene's own lifecycle) that leaves the autoload on
	# its default path writes the sandbox file, never the player's profile.
	_save.test_sandbox_path = "user://test_sandbox_seam.json"
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	assert_eq(_save.profile_path, "user://test_sandbox_seam.json",
		"the default path is remapped onto the sandbox while one is installed")
	assert_ne(_save.profile_path, _save.DEFAULT_PROFILE_PATH,
		"the real profile path is unreachable during a sandboxed run")


func test_an_explicit_redirect_still_wins_over_the_sandbox() -> void:
	# Per-test isolation must keep working: only the DEFAULT path is remapped, so a
	# test that asks for its own throwaway file gets exactly that file.
	_save.test_sandbox_path = "user://test_sandbox_seam.json"
	_save.profile_path = "user://test_sandbox_explicit.json"
	assert_eq(_save.profile_path, "user://test_sandbox_explicit.json",
		"an explicit redirect is left alone")


func test_without_a_sandbox_the_default_path_is_untouched() -> void:
	# The real game never sets test_sandbox_path, so the setter must be the identity
	# function there — the player's profile still lives at DEFAULT_PROFILE_PATH.
	_save.test_sandbox_path = ""
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	assert_eq(_save.profile_path, _save.DEFAULT_PROFILE_PATH,
		"no sandbox installed means no remapping")


func test_the_running_suite_is_sandboxed() -> void:
	# Wiring check: run_tests.sh passes the pre-run hook, so a live run must not be
	# pointing at the real profile. Skipped (not failed) when the suite is driven
	# some other way — e.g. the GUT editor panel, which has no hook configured.
	if not _save.has_meta(PreHook.META_REAL_PATH):
		pending("no sandbox hook installed (not run via run_tests.sh)")
		return
	assert_eq(_save.test_sandbox_path, PreHook.SANDBOX_PATH,
		"the pre-run hook installed the run-scoped sandbox")
	assert_ne(_saved_path, _save.DEFAULT_PROFILE_PATH,
		"nothing in this run is pointed at the real player profile")


# --- The credential sandbox (AuthService) -----------------------------------
#
# Third store to get a run-scoped sandbox, after the profile and real scene changes. AuthService
# WRITES user://auth.json and `sign_out()` DELETES it, and `refresh()` calls sign_out() itself on
# a non-network rejection — so an unredirected test could sign the developer out of the real game.
# It had not fired only because the tests that build one happen to seat an expiry an hour out.
#
# Asserts the SEAM, never a path value: that the default is remapped, that an explicit redirect
# still wins, and that clearing the sandbox restores the real default (so production is untouched).
func test_the_credential_default_is_remapped_while_a_sandbox_is_installed() -> void:
	var was := AuthService.test_sandbox_path
	var auth := AuthService.new()
	AuthService.test_sandbox_path = "user://test_sandbox_auth_seam.json"
	assert_eq(auth._path(), "user://test_sandbox_auth_seam.json",
		"an instance left on the default path is remapped onto the sandbox")
	assert_ne(auth._path(), AuthService.AUTH_PATH,
		"the real credential file is unreachable during a sandboxed run")

	# Per-test isolation must keep working: only the DEFAULT is remapped.
	auth.auth_path = "user://test_sandbox_auth_explicit.json"
	assert_eq(auth._path(), "user://test_sandbox_auth_explicit.json",
		"an explicit redirect is left alone")

	# And with no sandbox, the real game's path is untouched — the setter must be the identity
	# function in production, or signing in would write somewhere the next launch cannot find.
	AuthService.test_sandbox_path = ""
	auth.auth_path = AuthService.AUTH_PATH
	assert_eq(auth._path(), AuthService.AUTH_PATH,
		"no sandbox installed means no remapping")
	AuthService.test_sandbox_path = was


func test_the_running_suite_sandboxes_credentials() -> void:
	assert_ne(AuthService.test_sandbox_path, "",
		"the pre-run hook must install a credential sandbox for the whole run")
