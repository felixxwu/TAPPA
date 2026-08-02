extends GutTest
# The boot-pull vs. starter-pick race.
#
# Cloud kicks off its first pull deferred at startup; HQ boots and reveals the
# title in about a second. A returning player on a new device could therefore
# press Start and be offered a STARTER CAR while their real career was still in
# flight — and granting one marks the profile unsynced, turning the arriving
# download into a divergence prompt over a career they never lost.
#
# What must hold, and is pinned here:
#   * the gate ALWAYS releases — offline, hung, or never signed in;
#   * a player with no stored credential is not gated at all;
#   * if the career lands while the player waits, they go to the garage rather
#     than being handed a free starter on top of it;
#   * if it lands while the picker is already open, the picker backs out.
#
# Nothing here depends on real elapsed time: the timeout path is exercised with a
# zero budget, and the success path by settling the gate explicitly.

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


# --- HQ routing ---------------------------------------------------------------
# The headless guard in hq.gd covers only the loading COVER; the decision and the
# wait run the same either way, so everything below is real behaviour rather than
# a test-only path.

func _boot_hq() -> Node3D:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	return hq


func test_a_restored_career_skips_the_starter_pick() -> void:
	# The career landed while the player waited: they already own cars, so
	# handing them a free starter would both duplicate and overwrite.
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = true
	_save.grant_car("fx_light_rwd")

	await hq._on_exterior_start()

	assert_ne(hq._carpark_mode, hq.CarparkMode.STARTER,
		"a player with a career is never offered a starter")


func test_a_genuine_first_run_still_reaches_the_starter_pick() -> void:
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = false

	await hq._on_exterior_start()

	assert_eq(hq._carpark_mode, hq.CarparkMode.STARTER,
		"a real first run is unaffected by any of this")


func test_hq_actually_waits_for_a_pending_pull_then_proceeds() -> void:
	# The behaviour the whole gate exists for, asserted at the HQ level: pressing
	# Start while the career is still in flight must NOT reach the starter picker
	# until the pull settles — and must reach it promptly once it does.
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = false
	hq.cloud_restore_wait_sec = 30.0  # long enough that only settling can release
	Cloud.initial_pull_pending = true

	# Fire and forget: the coroutine parks inside the wait.
	hq._on_exterior_start()
	for _i in 5:
		await get_tree().process_frame
	assert_ne(hq._carpark_mode, hq.CarparkMode.STARTER,
		"the picker must not open while the player's career is still arriving")

	Cloud._settle_initial_sync()
	for _i in 5:
		await get_tree().process_frame
	assert_eq(hq._carpark_mode, hq.CarparkMode.STARTER,
		"settling releases the gate promptly — not after the full timeout")


func test_a_second_start_press_during_the_wait_is_ignored() -> void:
	# The cover blocks the mouse but not ui_accept, so Start keeps focus while the
	# gate is up. Without a guard, a second Enter would run a second coroutine and
	# open a second starter picker (or race one against a garage transition).
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = false
	hq.cloud_restore_wait_sec = 30.0
	Cloud.initial_pull_pending = true

	hq._on_exterior_start()
	await get_tree().process_frame
	assert_true(hq._awaiting_cloud, "the first press is parked in the wait")
	hq._on_exterior_start()  # the impatient second press
	await get_tree().process_frame

	Cloud._settle_initial_sync()
	for _i in 5:
		await get_tree().process_frame
	assert_false(hq._awaiting_cloud)
	assert_eq(hq._carpark_mode, hq.CarparkMode.STARTER)
	assert_eq(hq._view, hq.View.CARPARK, "one picker, not two and not a garage race")


func test_hq_does_not_wait_when_nothing_is_pending() -> void:
	# The offline / never-signed-in player. No credential means no pending pull,
	# so Start behaves exactly as it did before this gate existed.
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = false
	hq.cloud_restore_wait_sec = 30.0
	Cloud.initial_pull_pending = false

	hq._on_exterior_start()
	await get_tree().process_frame
	assert_eq(hq._carpark_mode, hq.CarparkMode.STARTER,
		"no pull pending means no wait at all")


func test_hq_gives_up_on_a_pull_that_never_lands() -> void:
	# A hung request must not strand the player: the bounded wait expires and the
	# picker opens anyway.
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = false
	hq.cloud_restore_wait_sec = 0.0  # an expired budget, without spending seconds
	Cloud.initial_pull_pending = true

	await hq._on_exterior_start()

	assert_eq(hq._carpark_mode, hq.CarparkMode.STARTER,
		"the gate always releases; it never blocks local play")


func test_a_download_closes_an_open_starter_picker() -> void:
	# The player got to the picker before the gate was armed. The download has
	# now given them a career; leaving the picker up would let them choose a
	# second free car on top of it.
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = false
	await hq._on_exterior_start()
	assert_eq(hq._carpark_mode, hq.CarparkMode.STARTER)

	_save.profile["starter_picked"] = true
	_save.grant_car("fx_light_rwd")
	hq._on_cloud_profile_replaced()

	assert_ne(hq._carpark_mode, hq.CarparkMode.STARTER,
		"the picker backs out rather than granting a duplicate starter")


# --- An UNRESOLVED CONFLICT must not let a new career begin ----------------------
#
# todo/challenge-career-reuse-drift.md item 10. Waiting for the pull is not enough on
# its own: the pull can settle as a CONFLICT (both sides moved on), in which case the
# download was NOT applied and a real career may be sitting in the cloud. Releasing
# the gate there offers a starter pick anyway, and picking one WRITES to the profile
# — so "keep this device" stops meaning "keep what I had" and starts meaning "keep
# the fresh save I was just handed". Reported by a player: signed in, progress
# apparently lost, happily allowed to pick a starter, conflict popup never shown.

# Put the sync layer into the blocked-by-conflict state the real pull would leave.
func _raise_conflict() -> void:
	Cloud.sync.blocked_by_conflict = true


func _clear_conflict() -> void:
	Cloud.sync.blocked_by_conflict = false


func test_an_unresolved_conflict_blocks_the_starter_pick() -> void:
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = false
	_raise_conflict()

	await hq._on_exterior_start()

	assert_ne(hq._carpark_mode, hq.CarparkMode.STARTER,
		"no new career may begin on top of an unresolved conflict")
	assert_false(bool(_save.profile.get("starter_picked", false)),
		"and nothing was written to the profile, so the local side of the conflict is intact")
	_clear_conflict()


func test_the_starter_pick_proceeds_once_the_conflict_is_settled() -> void:
	# The gate must RELEASE, not merely block — a player who resolves in favour of this
	# device still has no career, so they must reach the picker.
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = false
	_raise_conflict()
	await hq._on_exterior_start()
	assert_ne(hq._carpark_mode, hq.CarparkMode.STARTER, "setup: blocked while unresolved")

	_clear_conflict()
	await hq._on_exterior_start()
	assert_eq(hq._carpark_mode, hq.CarparkMode.STARTER,
		"once settled, a player with no career reaches the picker as normal")


func test_no_conflict_leaves_the_first_run_path_untouched() -> void:
	# The guard must not gate the ordinary offline/never-signed-in first run.
	var hq := await _boot_hq()
	_save.profile["starter_picked"] = false
	_clear_conflict()

	await hq._on_exterior_start()

	assert_eq(hq._carpark_mode, hq.CarparkMode.STARTER,
		"a player with no conflict is unaffected by the conflict guard")


# --- The title reveal ---------------------------------------------------------
# Same gate, wider scope. HQ used to build the title from the LOCAL profile and let
# _on_cloud_profile_replaced rebuild it when the download landed a second later, so
# the player watched their garage pop in. _await_boot_pull holds the whole build
# until the pull settles; what is pinned here is the RELATIONSHIP (built once, after
# the pull) and the two escapes — no credential, and a pull that never lands.
# See todo/challenge-career-reuse-drift.md item 13.

# Instantiate WITHOUT waiting: _ready runs synchronously up to its first await, so a
# caller can still connect to lineup_built before any title has been built. The wait
# budget has to be set BEFORE the node enters the tree — _ready reads it on the way
# into the wait, so a later assignment arrives after the deadline is already fixed.
func _boot_hq_unawaited(wait_sec := -1.0) -> Node3D:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	if wait_sec >= 0.0:
		hq.cloud_restore_wait_sec = wait_sec
	add_child_autofree(hq)
	return hq


# lineup_built fires once per title-lineup build, so counting it counts rebuilds.
func _count_title_builds(hq: Node3D) -> Array:
	var built := [0]
	hq.lineup_built.connect(func() -> void: built[0] += 1)
	return built


func test_the_title_is_not_built_until_a_pending_pull_settles() -> void:
	Cloud.initial_pull_pending = true
	var hq := _boot_hq_unawaited()
	var built := _count_title_builds(hq)

	for _i in 5:
		await get_tree().process_frame
	assert_eq(built[0], 0,
		"the title must not be built from the local profile while the career is arriving")

	Cloud._settle_initial_sync()
	for _i in 5:
		await get_tree().process_frame
	assert_eq(built[0], 1,
		"once the pull settles the title is built exactly once, from the settled profile")


func test_a_signed_out_player_reveals_the_title_without_waiting() -> void:
	# The escape that made the old code refuse to gate the title at all: someone who
	# never signed in must not wait for something that is never coming.
	Cloud.initial_pull_pending = false
	var hq := _boot_hq_unawaited()
	var built := _count_title_builds(hq)

	for _i in 5:
		await get_tree().process_frame
	assert_eq(built[0], 1, "no credential means no wait — the title builds straight away")


func test_a_pull_that_never_lands_still_reveals_the_title() -> void:
	# GUARANTEED EXIT: a hung pull degrades to "you keep playing locally", so the
	# player must still reach a title rather than sitting on the loading cover.
	Cloud.initial_pull_pending = true
	var hq := _boot_hq_unawaited(0.0)  # the timeout path, with no real elapsed time
	var built := _count_title_builds(hq)

	for _i in 5:
		await get_tree().process_frame

	assert_eq(built[0], 1, "the wait is capped — a pull that never lands cannot strand the player")
	assert_true(Cloud.initial_pull_pending,
		"and giving up on the WAIT does not cancel the pull itself")


func test_a_pull_that_settles_as_a_conflict_still_reveals_the_title() -> void:
	# A conflict does NOT apply the download, so the title reveals against the local
	# profile — and the conflict must survive the reveal rather than being swallowed
	# by the gate that now sits in front of it (item 10).
	Cloud.initial_pull_pending = true
	var hq := _boot_hq_unawaited()
	var built := _count_title_builds(hq)
	_raise_conflict()

	Cloud._settle_initial_sync()
	for _i in 5:
		await get_tree().process_frame

	assert_eq(built[0], 1, "a conflicted pull still lets the player reach the title")
	assert_true(ConflictPrompt.is_blocked(),
		"and the conflict is still live for the start gate to catch")
	_clear_conflict()


func test_a_download_landing_during_the_boot_wait_does_not_touch_an_unbuilt_hq() -> void:
	# The crash this pins: _ready CONNECTS the cloud signals and only then awaits the
	# boot pull — it has to, because that pull is what emits them. So on a signed-in
	# boot, profile_replaced fires while _pins_root / _overlays / the lineup are all
	# still null, and the rebuild the handler runs died on a null node
	# ("Cannot call method 'get_children' on a null value"). The handler must no-op
	# until the build has happened; _build_hq then reads the settled profile anyway.
	Cloud.initial_pull_pending = true
	var hq := _boot_hq_unawaited()
	var built := _count_title_builds(hq)
	await get_tree().process_frame
	assert_eq(built[0], 0, "the HQ is parked in the boot wait, with nothing built yet")

	Cloud.profile_replaced.emit()  # the download lands mid-wait
	await get_tree().process_frame
	assert_eq(built[0], 0, "the handler does not try to rebuild views that do not exist")

	Cloud._settle_initial_sync()
	for _i in 5:
		await get_tree().process_frame
	assert_eq(built[0], 1,
		"and the build that follows the wait still runs exactly once, from the settled profile")
	assert_not_null(hq._pins_root, "a fully built HQ has its pin root, so later signals are safe")
