extends CanvasLayer
# On-screen readout of the car's airspeed — the chassis velocity magnitude,
# not wheel rotation, so wheelspin and lockup don't affect the number.

@export var car: VehicleBody3D

@onready var _speed_label: Label = $SpeedLabel
@onready var _gear_label: Label = $GearLabel
@onready var _rpm_label: Label = $RPMLabel
@onready var _mode_button: Button = $ModeButton
@onready var _drive_button: Button = $DriveButton
@onready var _car_button: Button = $CarButton
@onready var _version_label: Label = $VersionLabel

const _DRIVE_NAMES := ["RWD", "AWD", "FWD"]


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
	_speed_label.text = "%d km/h" % roundi(car.linear_velocity.length() * 3.6)
	var engine: EngineSim = car.drivetrain.engine
	_gear_label.text = _gear_text(engine.gear)
	_rpm_label.text = "%d rpm" % roundi(engine.rpm())
	_mode_button.text = "AUTO" if engine.auto else "MANUAL"
	_drive_button.text = _DRIVE_NAMES[car.drivetrain.drive_mode]
	_car_button.text = car.current_car_name()


func _gear_text(gear: int) -> String:
	if gear < 0:
		return "R"
	if gear == 0:
		return "N"
	return str(gear)
