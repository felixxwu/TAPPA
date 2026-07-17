extends GutTest
# CarPreviewAudio plays a short engine rev for the focused car in the HQ lineup.
# These test the rev ENVELOPE / behaviour (throttle held then released, revs climb
# then fall back to idle, a new rev cancels the old) — never the 0.5s hold or any
# RPM number, which are tunable. Driven headless via _advance() (no audio device),
# against a synthetic engine so no real catalogue entry is depended on.

var _preview: CarPreviewAudio


func before_each() -> void:
	CarFixtures.install()
	# Not added to the tree: rev() then skips the audio-server reset, and _advance()
	# runs the sim/envelope directly, so no audio device is needed.
	_preview = CarPreviewAudio.new()


func after_each() -> void:
	_preview.free()
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
