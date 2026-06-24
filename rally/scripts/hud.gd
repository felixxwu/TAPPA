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

const _DRIVE_NAMES := ["RWD", "AWD", "FWD"]

# Last displayed values, so _process only re-formats + re-assigns a label when
# its value actually changes (avoids per-frame string allocation / GC churn).
var _last_speed := -1
var _last_gear := -999
var _last_rpm := -1
var _last_auto := false
var _last_drive := -1
var _last_car := ""
var _last_progress := -1


func _ready() -> void:
	visible = Config.data.hud_enabled
	_mode_button.pressed.connect(_on_mode_pressed)
	_drive_button.pressed.connect(_on_drive_pressed)
	_car_button.pressed.connect(_on_car_pressed)


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


func _gear_text(gear: int) -> String:
	if gear < 0:
		return "R"
	if gear == 0:
		return "N"
	return str(gear)
