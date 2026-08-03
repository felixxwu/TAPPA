extends GutTest
# CarPreviewAudio plays a short engine rev for the focused car in the HQ lineup.
# These test the rev ENVELOPE / behaviour (throttle held then released, revs climb
# then fall back to idle, a new rev cancels the old) — never the 0.5s hold or any
# RPM number, which are tunable. Driven headless via _advance() (no audio device),
# against a synthetic engine so no real catalogue entry is depended on.

var _preview: CarPreviewAudio


func before_each() -> void:
	CarFixtures.install()
	UpgradeFixtures.install()
	# Not added to the tree: rev() then skips the audio-server reset, and _advance()
	# runs the sim/envelope directly, so no audio device is needed.
	_preview = CarPreviewAudio.new()


func after_each() -> void:
	_preview.free()
	UpgradeFixtures.restore()
	CarFixtures.restore()


# Step the preview forward by `total` seconds in small chunks (mimicking frames).
func _advance_for(total: float) -> void:
	var step := 1.0 / 120.0
	var t := 0.0
	while t < total:
		_preview._advance(step)
		t += step


func test_hold_phase_drives_full_throttle_and_climbs_revs() -> void:
	_preview.rev("fx_i4")
	var idle: float = _preview._cfg.idle_rpm
	# During the hold the engine sees full throttle...
	_preview._advance(1.0 / 120.0)
	assert_eq(_preview._engine.throttle, 1.0, "throttle held down during the rev")
	# ...and the free-revving flywheel climbs above idle.
	_advance_for(_preview._cfg.preview_rev_hold_seconds)
	assert_gt(_preview._engine.rpm(), idle + 1.0, "revs climb above idle while gas is held")


func test_release_falls_back_to_idle_and_ends() -> void:
	_preview.rev("fx_i4")
	var idle: float = _preview._cfg.idle_rpm
	# Run past the hold, then well into the coast-down.
	_advance_for(_preview._cfg.preview_rev_hold_seconds + 5.0)
	assert_eq(_preview._engine.throttle, 0.0, "throttle released after the hold")
	assert_false(_preview._active, "preview ends once revs settle back to idle")
	assert_almost_eq(_preview._engine.rpm(), idle, 2.0, "revs fall back to idle")


func test_new_rev_cancels_the_previous_one() -> void:
	_preview.rev("fx_i4")
	_advance_for(_preview._cfg.preview_rev_hold_seconds + 5.0)
	assert_false(_preview._active, "first rev has finished")
	# Flicking to another car restarts the envelope from idle.
	var idle: float = _preview._cfg.idle_rpm
	_preview.rev("fx_v8")
	assert_true(_preview._active, "a new rev is active")
	assert_gt(_preview._hold_left, 0.0, "the hold timer is reset for the new car")
	assert_almost_eq(_preview._engine.rpm(), idle, 1.0, "the new rev starts from idle")


func test_unknown_engine_id_is_a_no_op() -> void:
	_preview.rev("does_not_exist")
	assert_false(_preview._active, "an unknown engine id starts no rev")


func test_fitted_forced_induction_is_heard_in_the_preview() -> void:
	# The preview must reflect the car's FITTED upgrades, not just the factory engine —
	# otherwise a turbo or supercharger the player bolted on is silent in the lineup.
	var blown := {"installed_upgrades": ["fx_supercharger"], "disabled_upgrades": []}
	_preview.rev("fx_i4", blown)
	assert_true(_preview._cfg.supercharger_enabled, "the fitted blower reaches the preview config")
	assert_gt(_preview._cfg.supercharger_boost_gain, 0.0, "with its belt boost physics")
	assert_gt(_preview._cfg.engine_supercharger_whine_gain, 0.0, "and its whine audio layer")
	var turbo := {"installed_upgrades": ["fx_turbo_big"], "disabled_upgrades": []}
	_preview.rev("fx_i4", turbo)
	assert_true(_preview._cfg.turbo_enabled, "a fitted turbo reaches the preview config too")


func test_bare_engine_audition_ignores_upgrades() -> void:
	# Called without an owned car (or with a car that has nothing fitted), the preview
	# is the stock engine — no leakage from whatever the fielded car happens to have.
	var prev_gain: float = Config.data.supercharger_boost_gain
	var prev_turbo: bool = Config.data.turbo_enabled
	Config.data.supercharger_boost_gain = 1.0  # a blown car currently in the field
	Config.data.turbo_enabled = true
	_preview.rev("fx_i4")
	assert_eq(_preview._cfg.supercharger_boost_gain, 0.0,
		"a stock-engine audition doesn't inherit the fielded car's blower")
	assert_false(_preview._cfg.turbo_enabled, "nor its turbo")
	# Config.data is a shared autoload — put it back so no later test inherits this.
	Config.data.supercharger_boost_gain = prev_gain
	Config.data.turbo_enabled = prev_turbo


func test_a_disabled_part_is_not_heard() -> void:
	# Toggling a fitted part off in the garage must silence it here as well, the same
	# way it goes inert on the fielded car.
	var off := {"installed_upgrades": ["fx_supercharger"], "disabled_upgrades": ["fx_supercharger"]}
	_preview.rev("fx_i4", off)
	assert_eq(_preview._cfg.supercharger_boost_gain, 0.0, "a switched-off blower stays silent")
