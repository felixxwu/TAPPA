extends CanvasLayer
# Anime "edge speed lines" overlay (see features/rendering.md). The look lives in
# shaders/speed_lines.gdshader, applied to a full-screen ColorRect on this layer
# (above the PS1 post-process, below the HUD). This script just drives the
# shader's `intensity` from the car's airspeed: nothing below speed_lines_start_kmh,
# ramping to full by speed_lines_full_kmh, and eased over time so the streaks fade
# in/out rather than pop. All tunables live in GameConfig under "Speed Lines".

@export var car: VehicleBody3D

@onready var _rect: ColorRect = $ColorRect

var _mat: ShaderMaterial
# Current eased strength, lerped toward the speed-derived target each frame.
var _intensity := 0.0


func _ready() -> void:
	var cfg: GameConfig = Config.data
	visible = cfg.speed_lines_enabled
	if not cfg.speed_lines_enabled:
		set_process(false)
		return
	_mat = _rect.material as ShaderMaterial
	# Static look pushed once from config (mirrors world.gd's post-process wiring).
	_mat.set_shader_parameter("line_color", cfg.speed_lines_color)
	_mat.set_shader_parameter("density", cfg.speed_lines_density)
	_mat.set_shader_parameter("inner_radius", cfg.speed_lines_inner_radius)
	_mat.set_shader_parameter("outer_radius", cfg.speed_lines_outer_radius)
	_mat.set_shader_parameter("flicker_speed", cfg.speed_lines_flicker_speed)
	_mat.set_shader_parameter("intensity", 0.0)


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"speed_lines", Time.get_ticks_usec() - __t)


func _timed_process(delta: float) -> void:
	if _mat == null or not is_instance_valid(car):
		return
	var cfg: GameConfig = Config.data
	var kmh := car.linear_velocity.length() * 3.6
	# Map [start, full] km/h → [0, 1], then scale by the configured cap.
	var span := maxf(1.0, cfg.speed_lines_full_kmh - cfg.speed_lines_start_kmh)
	var target := clampf((kmh - cfg.speed_lines_start_kmh) / span, 0.0, 1.0)
	target *= cfg.speed_lines_max_intensity
	# Ease toward the target so the lines build/fade smoothly with speed.
	_intensity = lerpf(_intensity, target, clampf(delta * cfg.speed_lines_response, 0.0, 1.0))
	_mat.set_shader_parameter("intensity", _intensity)
