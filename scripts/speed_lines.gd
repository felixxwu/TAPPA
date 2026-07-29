extends CanvasLayer
# Anime "edge speed lines" overlay (see features/rendering.md). The look lives in
# shaders/speed_lines.gdshader, applied to a full-screen ColorRect on this layer
# (above the PS1 post-process, below the HUD). This script just drives the
# shader's `intensity` from the car's airspeed: nothing below speed_lines_start_kmh,
# ramping to full by speed_lines_full_kmh, and eased over time so the streaks fade
# in/out rather than pop. All tunables live in GameConfig under "Speed Lines".

# Below this eased intensity the streaks are invisible, so the overlay rect is
# hidden outright rather than asking the GPU to shade a transparent full screen.
const VISIBLE_EPSILON := 0.002

@export var car: VehicleBody3D

@onready var _rect: ColorRect = $ColorRect

var _mat: ShaderMaterial
# Current eased strength, lerped toward the speed-derived target each frame.
var _intensity := 0.0
# Last value written to the shader, so an unchanged intensity costs nothing.
var _last_pushed := -1.0


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
	_apply_intensity(0.0)  # starts hidden: stationary car, no streaks to shade


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
	_apply_intensity(_intensity)


# Push the eased strength to the shader, and hide the full-screen rect entirely
# while it's imperceptible. Below the epsilon the shader still rasterises every
# pixel (an atan plus three sin-based hashes) only to blend a fully transparent
# result — pure GPU cost for nothing on the slowest devices. The parameter write
# is skipped when unchanged so an idle car doesn't touch the material each frame.
func _apply_intensity(value: float) -> void:
	var draw := value > VISIBLE_EPSILON
	if draw != _rect.visible:
		_rect.visible = draw
	if not is_equal_approx(value, _last_pushed):
		_last_pushed = value
		_mat.set_shader_parameter("intensity", value)


# --- Shader pre-warm ---------------------------------------------------------
# Under gl_compatibility a material's shader variant compiles on its FIRST VISIBLE
# DRAW. This overlay starts hidden (a stationary car has no streaks, and
# _apply_intensity hides the rect outright rather than shading a transparent full
# screen), so without this the full-screen program — an atan plus three sin-based
# hashes per pixel — used to compile the first time the car crossed
# speed_lines_start_kmh: i.e. mid-acceleration off the start line, as a one-frame
# stutter.
#
# world.gd's warm block auto-discovers every node implementing this
# warm_up()/clear_warm_up() pair and primes it behind the loading cover. The 3D
# corridor pre-warm can't reach this one — it's a CanvasLayer overlay, not
# something a camera fly can bring into view — so the contract is the only route.
# See features/rendering.md -> "Shader pre-warm".


# Show the rect for the warm-up frame so its program compiles. `intensity` stays
# at 0, so the shader outputs fully transparent — the compile happens with nothing
# actually drawn on screen, whatever is layered above or below us. The position
# argument is meaningless for a full-screen overlay (the contract passes a world
# point for the 3D effects) and is ignored.
func warm_up(_pos: Vector3) -> void:
	if _mat == null:
		return  # speed lines disabled in config: no material, nothing to compile
	_rect.visible = true


# Undo warm_up(): restore the hidden, zero-intensity resting state.
func clear_warm_up() -> void:
	if _mat == null:
		return
	_apply_intensity(0.0)
