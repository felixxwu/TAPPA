extends CanvasLayer
# On-screen readout of the car's airspeed — the chassis velocity magnitude,
# not wheel rotation, so wheelspin and lockup don't affect the number.

@export var car: VehicleBody3D

# Temporary on-screen track-progress readout. Set by world.gd once the
# TrackProgress manager exists; null in scenes that don't generate a track.
var track_progress: Node

@onready var _speed_label: Label = $SpeedLabel
@onready var _gear_label: Label = $GearLabel
@onready var _rpm_label: Label = $RPMLabel
@onready var _progress_label: Label = $ProgressLabel
@onready var _mode_button: Button = $ModeButton
@onready var _drive_button: Button = $DriveButton
@onready var _car_button: Button = $CarButton
@onready var _version_label: Label = $VersionLabel
# Stage flow widgets, driven by StageManager (todo/stage-start-and-end.md):
# the big centered 3·2·1·GO, the small top-right run timer, and the placeholder
# stage-complete panel. Hidden until the stage flow calls the methods below.
@onready var _countdown_label: Label = $CountdownLabel
@onready var _elapsed_label: Label = $ElapsedLabel
@onready var _stage_complete_panel: Control = $StageCompletePanel
@onready var _stage_complete_label: Label = $StageCompletePanel/StageCompleteLabel
# In-run damage readout (todo/damage-model.md §5): a colour-graded HP bar that
# flashes a warning when low, plus a red screen flash on each HP-losing impact.
@onready var _hp_label: Label = $HPLabel
@onready var _hp_bar: ProgressBar = $HPBar
@onready var _impact_flash: ColorRect = $ImpactFlash

const _DRIVE_NAMES := ["RWD", "AWD", "FWD"]

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
var _last_auto := false
var _last_drive := -1
var _last_car := ""
var _last_progress := -1
# Working HP last frame, to detect HP-losing impacts (fire the flash); -1 = no
# reading yet / gauge hidden. _hp_pulse_t advances the low-HP warning oscillation.
var _last_hp := -1.0
var _hp_pulse_t := 0.0


func _ready() -> void:
	visible = Config.data.hud_enabled
	_mode_button.pressed.connect(_on_mode_pressed)
	_drive_button.pressed.connect(_on_drive_pressed)
	_car_button.pressed.connect(_on_car_pressed)
	# Build version is stamped into application/config/version by build_web.sh
	# (0.<git commit count> + short SHA); falls back to the project default on
	# editor/dev runs. Set once here — it never changes at runtime.
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	_version_label.text = "v" + ver if ver != "" else "dev"
	# Stage widgets start hidden; StageManager reveals them at the right moments.
	_countdown_label.visible = false
	_elapsed_label.visible = false
	_stage_complete_panel.visible = false


func _on_mode_pressed() -> void:
	var engine: EngineSim = car.drivetrain.engine
	engine.auto = not engine.auto


func _on_drive_pressed() -> void:
	car.drivetrain.cycle_drive_mode()


func _on_car_pressed() -> void:
	# World owns the swap: it re-instantiates the car and re-points us (and the
	# camera) at the new node. _process keeps the button label in sync.
	(get_parent() as Node).cycle_car()


func _process(_delta: float) -> void:
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
	if engine.auto != _last_auto:
		_last_auto = engine.auto
		_mode_button.text = "AUTO" if engine.auto else "MANUAL"
	var drive: int = car.drivetrain.drive_mode
	if drive != _last_drive:
		_last_drive = drive
		_drive_button.text = _DRIVE_NAMES[drive]
	var car_name: String = car.current_car_name()
	if car_name != _last_car:
		_last_car = car_name
		_car_button.text = car_name
	if track_progress != null:
		var pct := roundi(track_progress.progress_percent() * 100.0)
		if pct != _last_progress:
			_last_progress = pct
			_progress_label.text = "%d%%" % pct
	_update_damage(_delta)


# Drive the HP gauge + impact flash off the car's damage model. Hidden when
# hud_hp_enabled is off or for the immortal starter (which never takes damage).
func _update_damage(delta: float) -> void:
	var dmg: DamageModel = car.damage
	var show_gauge := dmg != null and Config.data.hud_hp_enabled and not dmg.immortal
	_hp_bar.visible = show_gauge
	_hp_label.visible = show_gauge
	if show_gauge:
		var frac := clampf(dmg.hp / dmg.max_hp, 0.0, 1.0) if dmg.max_hp > 0.0 else 0.0
		_hp_bar.value = frac
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
	_stage_complete_panel.visible = true
	_stage_complete_label.text = "STAGE COMPLETE\n%s" % _format_time(seconds)


# m:ss.cc, e.g. 1:07.43.
func _format_time(seconds: float) -> String:
	var minutes := int(seconds / 60.0)
	var rem := seconds - minutes * 60.0
	return "%d:%05.2f" % [minutes, rem]
