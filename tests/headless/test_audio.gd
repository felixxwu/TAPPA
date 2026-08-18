extends GutTest
# Covers scripts/audio.gd — the `Audio` autoload / SFX seam. Docs: features/sfx.md.
#
# What is (and isn't) asserted here: this file pins the SAFETY and the CONTRACT of the
# seam — the autoload exists, the SFX bus exists, calling it headless does nothing and
# cannot crash, repeated calls are harmless, and the config gate turns it off. It
# deliberately pins NO frequency, duration, volume or decay VALUE: those are tunables
# in game_config.tres (CLAUDE.md → Testing), and a designer retuning the beep must not
# turn this file red.


func _audio() -> AudioManager:
	return get_node_or_null("/root/Audio") as AudioManager


func test_audio_autoload_is_registered() -> void:
	# The singleton is named "Audio" (project.godot [autoload]); the class is AudioManager.
	var a := get_node_or_null("/root/Audio")
	assert_not_null(a, "Audio autoload exists")
	assert_true(a is AudioManager, "the Audio autoload is an AudioManager")


func test_sfx_bus_exists_and_sends_to_master() -> void:
	# A named bus per source is the convention (Music / Engine / SFX). The bus graph is
	# safe headless — only playback isn't — so this contract holds in tests too.
	var idx := AudioServer.get_bus_index(AudioManager.BUS)
	assert_true(idx > 0, "an SFX bus exists and is not bus 0 (Master)")
	if idx > 0:
		assert_eq(str(AudioServer.get_bus_send(idx)), "Master", "SFX sends to Master")


func test_headless_never_creates_playback() -> void:
	# THE invariant this whole seam exists to hold once: headless must never play().
	# A playing generator playback is freed under the dummy driver's mix thread at
	# teardown and SIGSEGVs intermittently (features/testing.md).
	var a := _audio()
	assert_not_null(a)
	assert_false(a.is_available(), "no playback is created headless")


func test_play_beep_is_a_safe_no_op_headless_and_is_repeatable() -> void:
	# The call site never has to guard: it returns false rather than erroring, and
	# calling it many times in a row neither crashes nor rebuilds anything.
	var a := _audio()
	assert_not_null(a)
	for i in 5:
		assert_false(a.play_beep(), "play_beep() is a no-op headless (call %d)" % i)
	assert_false(a.play_beep(1200.0, 0.25, 3.0), "explicit args are a no-op too")
	assert_false(a.is_available(), "repeated calls did not spin up playback")


func test_beep_spec_is_empty_when_sfx_disabled() -> void:
	# sfx_enabled=false must silence the whole facility, not just skip some layers.
	var a := _audio()
	assert_not_null(a)
	var cfg := Config.data
	var was: bool = cfg.sfx_enabled
	cfg.sfx_enabled = false
	var spec := a.beep_spec()
	cfg.sfx_enabled = was
	assert_true(spec.is_empty(), "a disabled SFX layer resolves to nothing to play")


func test_beep_spec_fills_defaults_and_honours_overrides() -> void:
	# No value is pinned: only that omitted args resolve to SOMETHING usable and that
	# an explicitly-passed pitch/length is the one that comes back.
	var a := _audio()
	assert_not_null(a)
	var spec := a.beep_spec()
	assert_false(spec.is_empty(), "the default beep resolves to a playable spec")
	assert_true(spec["frequency_hz"] > 0.0, "default pitch is positive")
	assert_true(spec["duration_sec"] > 0.0, "default length is positive")
	var custom := a.beep_spec(1234.0, 0.3)
	assert_almost_eq(float(custom["frequency_hz"]), 1234.0, 0.001, "explicit pitch wins")
	assert_almost_eq(float(custom["duration_sec"]), 0.3, 0.001, "explicit length wins")


func test_beep_spec_volume_db_is_an_offset_not_a_replacement() -> void:
	var a := _audio()
	assert_not_null(a)
	var base: float = a.beep_spec()["volume_db"]
	var louder: float = a.beep_spec(0.0, 0.0, 6.0)["volume_db"]
	assert_almost_eq(louder - base, 6.0, 0.001, "volume_db adds to the configured level")


func test_render_beep_produces_a_finite_decaying_stereo_buffer() -> void:
	# The pure DSP, exercised with synthetic parameters (no config, no audio device).
	var buf := AudioManager.render_beep(2000, 440.0, 22050.0, 0.5, 12.0)
	assert_eq(buf.size(), 2000, "one frame per requested sample")
	var peak_head := 0.0
	var peak_tail := 0.0
	for i in buf.size():
		var f: Vector2 = buf[i]
		assert_almost_eq(f.x, f.y, 0.0000001, "frame %d is centred (L == R)" % i)
		assert_true(is_finite(f.x), "frame %d is finite" % i)
		assert_true(absf(f.x) <= 0.5 + 0.0001, "frame %d never exceeds the amplitude" % i)
		if i < 200:
			peak_head = maxf(peak_head, absf(f.x))
		elif i >= buf.size() - 200:
			peak_tail = maxf(peak_tail, absf(f.x))
	assert_true(peak_head > peak_tail, "the beep decays — the tail is quieter than the head")


func test_render_beep_rejects_degenerate_input() -> void:
	assert_eq(AudioManager.render_beep(0, 440.0, 22050.0, 0.5, 12.0).size(), 0,
		"zero frames renders nothing")
	assert_eq(AudioManager.render_beep(-10, 440.0, 22050.0, 0.5, 12.0).size(), 0,
		"a negative frame count renders nothing")
	assert_eq(AudioManager.render_beep(100, 440.0, 0.0, 0.5, 12.0).size(), 0,
		"a zero mix rate renders nothing rather than dividing by zero")
