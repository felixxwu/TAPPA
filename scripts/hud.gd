extends CanvasLayer
# On-screen readout of the car's airspeed — the chassis velocity magnitude,
# not wheel rotation, so wheelspin and lockup don't affect the number.

@export var car: VehicleBody3D

@onready var _speed_label: Label = $SpeedLabel
@onready var _gear_label: Label = $GearLabel
@onready var _rpm_label: Label = $RPMLabel
# Stage flow widgets, driven by StageManager (todo/stage-start-and-end.md):
# the big centered 3·2·1·GO, the small top-right run timer, and the placeholder
# stage-complete panel. Hidden until the stage flow calls the methods below.
@onready var _countdown_label: Label = $CountdownLabel
@onready var _elapsed_label: Label = $ElapsedLabel
@onready var _stage_complete_panel: Control = $StageCompletePanel
@onready var _stage_complete_label: Label = $StageCompletePanel/Box/StageCompleteLabel
# Finish-panel NEXT button (built in code, added to the panel's Box). Pressing it
# emits finish_next_pressed, which world.gd routes to StageManager.proceed_to_results
# to start the post-stage flow (features/stage.md). Made keyboard/gamepad navigable
# via MenuNav.attach (features/menus.md).
signal finish_next_pressed
var _next_button: Button
# In-run "vs P1" pace popup: a small top-centre readout the StageManager pulses every
# few turns, showing the player's time delta to the leading rival (− green = ahead,
# + red = behind). Built in code (not the scene) and auto-hides after a moment.
var _stage_delta_label: Label
var _stage_delta_left := 0.0
# In-run damage readout (features/damage.md): a colour-graded HP bar that
# flashes a warning when low, plus a red screen flash on each HP-losing impact.
@onready var _hp_label: Label = $HPLabel
@onready var _hp_bar: ProgressBar = $HPBar
@onready var _impact_flash: ColorRect = $ImpactFlash

# Low-HP warning pulse speed (rad/s) and the impact-flash response curve: each
# HP-losing hit bumps the red overlay's alpha by (loss fraction) * GAIN, capped at
# MAX, and the overlay fades back out at DECAY alpha/sec.
const _HP_PULSE_SPEED := 9.0
const _IMPACT_FLASH_GAIN := 6.0
const _IMPACT_FLASH_MAX := 0.6
const _IMPACT_FLASH_DECAY := 2.0

# Last displayed values, so _process only re-formats + re-assigns a label when
# its value actually changes (avoids per-frame string allocation / GC churn).
var _last_speed := -1
var _last_gear := -999
var _last_rpm := -1
# Working HP last frame, to detect HP-losing impacts (fire the flash); -1 = no
# reading yet / gauge hidden. _hp_pulse_t advances the low-HP warning oscillation.
var _last_hp := -1.0
var _hp_pulse_t := 0.0
# Last displayed health percentage, so the label only re-formats on a change.
var _last_hp_pct := -1
# The speed / gear / rpm readout is a dev diagnostic, hidden by default and
# toggled with H (`toggle_debug_arrows`) — the same gate as the debug force
# arrows, and like them only in a debug build (release/web ignore the key).
var _debug_readout := false


func _ready() -> void:
	visible = Config.data.hud_enabled
	# Speed / gear / rpm are a dev readout — hidden until H reveals them.
	_speed_label.visible = false
	_gear_label.visible = false
	_rpm_label.visible = false
	# Stage widgets start hidden; StageManager reveals them at the right moments.
	_countdown_label.visible = false
	_elapsed_label.visible = false
	_stage_complete_panel.visible = false
	# Design-system accents: the run timer reads white (neutral primary text), the
	# stage-complete banner green (success) — matching the house palette. See features/ui-design-system.md.
	_elapsed_label.add_theme_color_override("font_color", UITheme.INK)
	_stage_complete_label.add_theme_color_override("font_color", UITheme.GREEN)
	_build_stage_delta_label()
	# Build the finish-panel NEXT button and make it keyboard/gamepad navigable. Attaching
	# MenuNav to the (hidden) panel flips the button to FOCUS_ALL now and re-grabs focus
	# onto it whenever the panel is shown (features/menus.md → "Menu navigation").
	_next_button = UITheme.button("Next")
	_next_button.name = "NextButton"
	_next_button.pressed.connect(func() -> void: finish_next_pressed.emit())
	$StageCompletePanel/Box.add_child(_next_button)
	MenuNav.attach(_stage_complete_panel, {"first": _next_button})


# Build the top-centre pace-popup label in code (it has no scene node). Anchored to
# the top centre, sitting just below the run timer, and
# hidden until the StageManager pulses it via show_stage_delta().
func _build_stage_delta_label() -> void:
	_stage_delta_label = Label.new()
	_stage_delta_label.name = "StageDeltaLabel"
	_stage_delta_label.anchor_left = 0.5
	_stage_delta_label.anchor_right = 0.5
	_stage_delta_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_stage_delta_label.offset_left = -80.0
	_stage_delta_label.offset_right = 80.0
	_stage_delta_label.offset_top = 40.0
	_stage_delta_label.offset_bottom = 64.0
	_stage_delta_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stage_delta_label.add_theme_font_size_override("font_size", 20)
	_stage_delta_label.visible = false
	add_child(_stage_delta_label)


func _process(_delta: float) -> void:
	# Toggle the speed / gear / rpm readout with H, gated to debug builds like the
	# force arrows. Text below still refreshes while hidden, so it's correct the
	# instant it's shown.
	if OS.is_debug_build() and Input.is_action_just_pressed("toggle_debug_arrows"):
		_debug_readout = not _debug_readout
		_speed_label.visible = _debug_readout
		_gear_label.visible = _debug_readout
		_rpm_label.visible = _debug_readout
	var engine: EngineSim = car.drivetrain.engine
	var speed := roundi(car.linear_velocity.length() * 3.6)
	if speed != _last_speed:
		_last_speed = speed
		_speed_label.text = "%d km/h" % speed
	if engine.gear != _last_gear:
		_last_gear = engine.gear
		_gear_label.text = _gear_text(engine.gear)
	var rpm := roundi(engine.rpm())
	if rpm != _last_rpm:
		_last_rpm = rpm
		_rpm_label.text = "%d rpm" % rpm
	_update_damage(_delta)
	# Fade the pace popup out after its on-screen time elapses.
	if _stage_delta_left > 0.0:
		_stage_delta_left -= _delta
		if _stage_delta_left <= 0.0:
			_stage_delta_label.visible = false


# Drive the HP gauge + impact flash off the car's damage model. Hidden when
# hud_hp_enabled is off.
func _update_damage(delta: float) -> void:
	var dmg: DamageModel = car.damage
	var show_gauge := dmg != null and Config.data.hud_hp_enabled
	_hp_bar.visible = show_gauge
	_hp_label.visible = show_gauge
	if show_gauge:
		var frac := clampf(dmg.hp / dmg.max_hp, 0.0, 1.0) if dmg.max_hp > 0.0 else 0.0
		_hp_bar.value = frac
		# Label the gauge "Health" + a live percentage (a raw HP number is misleading —
		# it reads as horsepower). Only re-format when the rounded percent changes.
		var pct := roundi(frac * 100.0)
		if pct != _last_hp_pct:
			_last_hp_pct = pct
			_hp_label.text = "Health %d%%" % pct
		# Green (full) → amber → red (empty) via hue; flash by modulating alpha when
		# below the low-HP warning fraction so the danger is unmissable.
		var col := Color.from_hsv(frac * 0.33, 0.8, 0.95)
		if frac < Config.data.hud_low_hp_warn_frac:
			_hp_pulse_t += delta * _HP_PULSE_SPEED
			col.a = lerpf(0.35, 1.0, 0.5 + 0.5 * sin(_hp_pulse_t))
		else:
			_hp_pulse_t = 0.0
		_hp_bar.modulate = col
		# Bump the impact flash on any HP drop since last frame, sized to the loss.
		if _last_hp >= 0.0 and dmg.hp < _last_hp:
			var bump := (_last_hp - dmg.hp) / dmg.max_hp * _IMPACT_FLASH_GAIN
			_impact_flash.color.a = minf(_impact_flash.color.a + bump, _IMPACT_FLASH_MAX)
		_last_hp = dmg.hp
	else:
		_last_hp = -1.0
		_last_hp_pct = -1
	# Fade the flash back out regardless of gauge visibility.
	if _impact_flash.color.a > 0.0:
		_impact_flash.color.a = maxf(0.0, _impact_flash.color.a - delta * _IMPACT_FLASH_DECAY)


func _gear_text(gear: int) -> String:
	if gear < 0:
		return "R"
	if gear == 0:
		return "N"
	return str(gear)


# --- Stage flow (driven by StageManager, todo/stage-start-and-end.md) ---------

# Big centered countdown. ceili maps (2,3]→3, (1,2]→2, (0,1]→1; 0 (or below)
# shows "GO".
func show_countdown(seconds_left: float) -> void:
	_countdown_label.visible = true
	_countdown_label.text = str(ceili(seconds_left)) if seconds_left > 0.0 else "GO"


func hide_countdown() -> void:
	_countdown_label.visible = false


# Small top-right run timer. Gated by hud_elapsed_enabled (mirrors hud_enabled);
# one formatted string per frame is acceptable since the value changes every tick.
func show_elapsed(seconds: float) -> void:
	if not Config.data.hud_elapsed_enabled:
		return
	_elapsed_label.visible = true
	_elapsed_label.text = _format_time(seconds)


# Placeholder stage-complete panel — at minimum the final time. The menu's
# buttons/actions are a separate todo (rally-event-flow.md / menus.md); this is
# the stub the future flow attaches to.
func show_stage_complete(seconds: float) -> void:
	# Showing the panel fires its visibility_changed, which MenuNav uses to grab focus
	# onto the NEXT button (ui_accept then triggers it; the theme paints the cursor).
	_stage_complete_panel.visible = true
	_stage_complete_label.text = "FINISH\n%s" % _format_time(seconds)


# Top-centre pace popup, pulsed by the StageManager every few turns: the player's
# time delta (ms) to the leading (P1) rival at this point. Negative = ahead (green,
# shown with "−"), positive = behind (red, shown with "+"). Gated by
# hud_stage_delta_enabled; auto-hides after stage_delta_show_seconds.
func show_stage_delta(delta_ms: int) -> void:
	if not Config.data.hud_stage_delta_enabled:
		return
	var ahead := delta_ms < 0
	var secs := absf(delta_ms / 1000.0)
	_stage_delta_label.text = "P1 %s%.1fs" % ["-" if ahead else "+", secs]
	_stage_delta_label.add_theme_color_override("font_color", UITheme.GREEN if ahead else UITheme.RED)
	_stage_delta_label.visible = true
	_stage_delta_left = Config.data.stage_delta_show_seconds


# m:ss.cc, e.g. 1:07.43.
func _format_time(seconds: float) -> String:
	var minutes := int(seconds / 60.0)
	var rem := seconds - minutes * 60.0
	return "%d:%05.2f" % [minutes, rem]
