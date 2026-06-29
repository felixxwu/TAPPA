extends AudioStreamPlayer
# Bridges the simulated engine to audio: reads EngineSim state each frame and
# pushes synthesized PCM into an AudioStreamGenerator. The DSP lives in
# EngineAudioSynth; this node only owns the generator and the per-frame pull.

const MIX_RATE := 22050.0
# Generator buffer depth. The fill runs in _process on the main thread, so the
# buffer is the only thing keeping audio alive across a slow frame: if the gap
# between _process calls exceeds it, the buffer drains and the engine note
# crackles/drops. On the single-threaded web build a chunk-crossing frame can be
# tens of ms, so 0.1 s left almost no headroom. 0.15 s covers the worst post-
# optimisation frame (the deferred distant-terrain rebuild) with margin, while
# keeping throttle→rev audio latency low enough to still feel responsive. Raise
# toward ~0.2 if underruns persist on the weakest devices (at a little more lag).
const BUFFER_SECONDS := 0.15

var _synth: EngineAudioSynth
var _playback: AudioStreamGeneratorPlayback
var _scratch := PackedVector2Array()


func _ready() -> void:
	var cfg: GameConfig = Config.data
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = BUFFER_SECONDS
	stream = gen
	_synth = EngineAudioSynth.new(cfg, MIX_RATE)
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback


# Rebuild the synth from the current config — call after a car swap changes the
# engine_type (cylinder count + firing order), which the synth caches at init.
func reconfigure() -> void:
	_synth = EngineAudioSynth.new(Config.data, MIX_RATE)


func _process(_delta: float) -> void:
	if _playback == null:
		return  # headless / no audio device
	var engine: EngineSim = get_parent().drivetrain.engine
	var n := _playback.get_frames_available()
	if n <= 0:
		return
	# Size the scratch buffer to exactly n frames so we can push it directly,
	# avoiding a per-frame slice() allocation. resize only fires when n changes.
	if _scratch.size() != n:
		_scratch.resize(n)
	_synth.fill(_scratch, engine.rpm(), engine.throttle, engine.shift_timer > 0.0, n, engine.limiting)
	_playback.push_buffer(_scratch)
