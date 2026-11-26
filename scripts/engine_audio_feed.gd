class_name EngineAudioFeed extends RefCounted
# Docs: features/engine-audio.md — update in the same change as this file.
# Tests: tests/headless/test_engine_audio.gd — extend in the same change.
# Hands the engine's audio inputs from the main thread to the synth, optionally on a worker thread that fills the generator.

var synth: EngineAudioSynth
var _mutex := Mutex.new()
var _thread: Thread
var _quit := false

var _rpm := 0.0
var _throttle := 0.0
var _shift_cut := false
var _fuel_cut := false
var _limiting := false
var _boost := 0.0
var _turbo_spin := 0.0
var _antilag := false
var _nitrous_on := false
var _wheel_speed := 0.0
var _silent := false

# One-shot cues are counters so each fires on exactly one render, however many renders happen between publishes.
var _bov_seq := 0
var _trigger_seq := 0
var _empty_seq := 0
var _bov_seen := 0
var _trigger_seen := 0
var _empty_seen := 0


func _init(p_synth: EngineAudioSynth) -> void:
	synth = p_synth


func publish(rpm: float, throttle: float, shift_cut: bool, fuel_cut: bool, limiting: bool, boost: float, turbo_spin: float, bov: bool, antilag: bool, nitrous_on: bool, nitrous_trigger: bool, nitrous_empty: bool, wheel_speed: float) -> void:
	_mutex.lock()
	_rpm = rpm
	_throttle = throttle
	_shift_cut = shift_cut
	_fuel_cut = fuel_cut
	_limiting = limiting
	_boost = boost
	_turbo_spin = turbo_spin
	_antilag = antilag
	_nitrous_on = nitrous_on
	_wheel_speed = wheel_speed
	_silent = false
	_bov_seq += int(bov)
	_trigger_seq += int(nitrous_trigger)
	_empty_seq += int(nitrous_empty)
	_mutex.unlock()


func set_silent(value: bool) -> void:
	_mutex.lock()
	_silent = value
	_mutex.unlock()


func render(buffer: PackedVector2Array, n: int) -> void:
	_mutex.lock()
	var silent := _silent
	var rpm := _rpm
	var throttle := _throttle
	var shift_cut := _shift_cut
	var fuel_cut := _fuel_cut
	var limiting := _limiting
	var boost := _boost
	var turbo_spin := _turbo_spin
	var antilag := _antilag
	var nitrous_on := _nitrous_on
	var wheel_speed := _wheel_speed
	var bov := _bov_seq != _bov_seen
	var trigger := _trigger_seq != _trigger_seen
	var empty := _empty_seq != _empty_seen
	if not silent:
		_bov_seen = _bov_seq
		_trigger_seen = _trigger_seq
		_empty_seen = _empty_seq
	_mutex.unlock()
	if silent:
		buffer.fill(Vector2.ZERO)
		return
	synth.fill(buffer, rpm, throttle, shift_cut, n, fuel_cut, limiting, boost, turbo_spin, bov, antilag, nitrous_on, trigger, empty, wheel_speed)


func is_running() -> bool:
	return _thread != null


func start(frames_available: Callable, push: Callable) -> void:
	stop()
	_mutex.lock()
	_quit = false
	_mutex.unlock()
	_thread = Thread.new()
	_thread.start(_run.bind(frames_available, push))


func stop() -> void:
	if _thread == null:
		return
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_thread.wait_to_finish()
	_thread = null


func _run(frames_available: Callable, push: Callable) -> void:
	var buf := PackedVector2Array()
	while true:
		_mutex.lock()
		var quit := _quit
		_mutex.unlock()
		if quit:
			return
		var n: int = frames_available.call()
		if n > 0:
			buf.resize(n)
			render(buf, n)
			push.call(buf)
		OS.delay_msec(3)
