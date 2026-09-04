extends GutTest
# THE BOOT-PULL GATE (Cloud.await_initial_sync / initial_pull_pending /
# _settle_initial_sync). Cloud kicks off its first pull deferred at startup, so a
# returning player on a new device can be mid-download while the game is already
# interactive — and anything that writes the profile in that window marks it unsynced,
# turning the arriving download into a divergence prompt over a career they never lost.
#
# What is pinned here, all of it Cloud-level:
#   * the gate ALWAYS releases — offline, hung, or never signed in;
#   * a player with no stored credential is not gated at all;
#   * settling is idempotent, and signing out releases anyone waiting.
#
# Nothing here depends on real elapsed time: the timeout path is exercised with a zero
# budget, and the success path by settling the gate explicitly.
#
# HALF THIS FILE WAS DELETED IN STAGE 9, AND THE GATE NOW HAS NO CONSUMER.
# The other fifteen tests booted hq.tscn and asserted its ROUTING: that a restored career
# skipped the starter pick, that an arriving download closed an open starter picker, and
# that an unresolved conflict blocked a new career from beginning on top of it
# (todo/challenge-career-reuse-drift.md item 10 — reported by a real player). Both the
# diegetic hub and the starter picker are deleted (decisions 9 and 28: a fresh profile is
# handed money and sent to the car shop instead), so those tests could not be ported.
#
# THE HAZARD THEY GUARDED IS NOT GONE. HubShell does not await the initial sync at all, so
# a returning player can buy a car or start a run while their real profile is still in
# flight. `Cloud.initial_pull_pending`, `await_initial_sync` and `sync.blocked_by_conflict`
# are all still live and still tested below — what is missing is the caller. See
# features/cloud-save.md -> "Boot-time race".

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_cloud_boot_gate_profile.json"

var _save: Node


func before_each() -> void:
	get_viewport().gui_release_focus()
	Config.reset()
	CarFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	Cloud.initial_pull_pending = false


func after_each() -> void:
	Cloud.initial_pull_pending = false
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# --- The gate itself ----------------------------------------------------------

func test_a_player_with_no_credential_is_never_gated() -> void:
	# The whole point: signing in is optional, so someone who never has must see
	# no change at all — not even a frame of waiting.
	assert_false(Cloud.initial_pull_pending)
	assert_true(await Cloud.await_initial_sync(0.0),
		"nothing pending means nothing to wait for")


func test_the_wait_is_bounded_and_always_returns() -> void:
	# A hung socket or a dead server must not strand the player. A zero budget is
	# the same code path as an expired one, without depending on the clock.
	Cloud.initial_pull_pending = true
	assert_false(await Cloud.await_initial_sync(0.0),
		"the wait gives up rather than blocking forever")
	assert_true(Cloud.initial_pull_pending,
		"giving up on the WAIT does not cancel the pull — it still lands later")


func test_settling_releases_the_gate() -> void:
	Cloud.initial_pull_pending = true
	# A dictionary, not a local bool: GDScript lambdas capture locals by VALUE,
	# so assigning to one inside the closure would never be visible out here.
	var out := {"released": false}
	var waiter := func() -> void:
		out["released"] = await Cloud.await_initial_sync(30.0)
	waiter.call()
	await get_tree().process_frame
	assert_false(bool(out["released"]), "still waiting while the pull is in flight")
	Cloud._settle_initial_sync()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(bool(out["released"]), "the pull landing lets the player through")
	assert_false(Cloud.initial_pull_pending)


func test_settling_is_idempotent() -> void:
	# The resumed-from-background path reuses _kick_off_initial_pull, which must
	# not re-arm or double-emit a gate nobody is waiting on any more.
	Cloud.initial_pull_pending = true
	var seen := {"count": 0}
	var counter := func() -> void: seen["count"] = int(seen["count"]) + 1
	Cloud.initial_sync_settled.connect(counter)
	Cloud._settle_initial_sync()
	Cloud._settle_initial_sync()
	Cloud.initial_sync_settled.disconnect(counter)
	assert_eq(int(seen["count"]), 1)


func test_signing_out_releases_anyone_waiting() -> void:
	# Nothing is coming any more, so the gate must not outlive the session.
	#
	# Deliberately NOT Cloud.sign_out(): that reaches AuthService and deletes
	# user://auth.json, so running the suite on a developer's machine would log
	# them out of their real account. The behaviour under test is the release,
	# which is _settle_initial_sync — the one line sign_out adds.
	Cloud.initial_pull_pending = true
	Cloud._settle_initial_sync()
	assert_false(Cloud.initial_pull_pending)
	# And the wait it releases returns immediately thereafter.
	assert_true(await Cloud.await_initial_sync(0.0))


