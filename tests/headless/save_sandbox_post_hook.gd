extends GutHookScript
# GUT POST-RUN HOOK (wired via -gpost_run_script in run_tests.sh).
#
# The other half of the profile sandbox installed by save_sandbox_pre_hook.gd: it
# proves, at the end of every run, that the REAL profile
# (SaveManager.DEFAULT_PROFILE_PATH) was not created, modified or deleted while the
# tests ran. The sandbox should make that impossible — this is what tells us if a
# hole ever opens up, instead of the developer finding a fixture car in their garage.
#
# It reports by printing VIOLATION_MARKER, which run_tests.sh greps for in
# TEST_ERROR_PATTERN and fails the run on. (The vendored GUT does not honour a hook's
# set_exit_code, so the marker is the reliable channel.)

const _PreHook = preload("res://tests/headless/save_sandbox_pre_hook.gd")

# Kept in sync with TEST_ERROR_PATTERN in run_tests.sh.
const VIOLATION_MARKER := "PROFILE SANDBOX VIOLATION"

# Reported when the real profile changed but nothing in this process tried to write it. Kept
# DISTINCT from VIOLATION_MARKER on purpose: run_tests.sh greps the latter and fails on it, so a
# marker containing it as a substring would fail the run anyway and defeat the whole distinction.
const VIOLATION_MARKER_EXTERNAL := "PROFILE CHANGED OUTSIDE THE TEST RUN"


func run() -> void:
	var save: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("/root/Save")
	if save == null or not save.has_meta(_PreHook.META_REAL_PATH):
		return  # nothing was recorded (hook not installed) — nothing to compare against
	var real_path: String = save.get_meta(_PreHook.META_REAL_PATH)
	var before: int = int(save.get_meta(_PreHook.META_REAL_MTIME))
	var after := FileAccess.get_modified_time(real_path) if FileAccess.file_exists(real_path) else -1
	if after == before:
		return

	# The file DID change — but an mtime comparison cannot say WHO changed it, and that
	# distinction is the difference between a real bug and a wasted six-minute run.
	#
	# What made this necessary: a run failed here twice while the suite was demonstrably
	# innocent. The developer had launched the GAME while the suite was running, and the game
	# legitimately writes its own profile. The tell was that `user://auth.json`, the overworld
	# chunk cache and a log file were all written in the same minute — none of which a
	# sandboxed run touches, because they are redirected too.
	#
	# So consult the production side instead of guessing: SaveManager refuses a headless write
	# to the real path and COUNTS the refusals. A test that tried to write the real profile is
	# therefore recorded, and one that did not, is not. Two outcomes:
	#
	#   refused > 0  — a test really did aim at the real profile. Fail the run; the refusal's
	#                  own push_error carries the stack naming the caller.
	#   refused == 0 — nothing in this process attempted it, so the change came from outside
	#                  (a concurrent game launch is the usual cause). Say so loudly and let the
	#                  run stand: failing here would punish the suite for someone else's write,
	#                  and a guard that cries wolf gets switched off.
	#
	# The refusal makes a real test-side write impossible in the first place; this hook is now
	# the report on it rather than the only line of defence.
	var refused := 0
	if "refused_real_writes" in save:
		refused = int(save.refused_real_writes)
	if refused <= 0:
		print(("%s (EXTERNAL): %s changed during the run (mtime %d -> %d), but NO test attempted "
			+ "a write to it — SaveManager refused none. Almost certainly something outside the "
			+ "suite wrote it, e.g. the game being launched while the tests ran. Not failing the "
			+ "run. If you were not running the game, treat this as a hole in the sandbox and "
			+ "investigate.") % [VIOLATION_MARKER_EXTERNAL, real_path, before, after])
		return

	# Deliberately blunt wording: this means a test wrote the developer's own save.
	print("%s: %s changed during the test run (mtime %d -> %d), and SaveManager refused %d "
		% [VIOLATION_MARKER, real_path, before, after, refused]
		+ "real write(s) — a test aimed at the REAL player profile instead of a throwaway one. "
		+ "The refusal's own error carries the stack; find it and redirect it "
		+ "(tests/headless/save_test_helpers.gd).")
	gut.logger.error("%s: %s was written during the test run" % [VIOLATION_MARKER, real_path])
	set_exit_code(1)
