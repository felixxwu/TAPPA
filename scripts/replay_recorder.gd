class_name ReplayRecorder
extends Node

const SAMPLE_HZ := 30.0

var recording := false
var _car: Node
var _wheels: Array = []          # VehicleWheel3D, front then rear, stable order
var _frames: Array = []          # Array[Dictionary]
var _accum := 0.0                # seconds since last captured sample
var _elapsed := 0.0              # recording clock

func setup(car: Node) -> void:
	_car = car
	_wheels.clear()
	var dt = car.get("drivetrain")
	if dt != null:
		for w in dt.front_wheels:
			_wheels.append(w)
		for w in dt.rear_wheels:
			_wheels.append(w)

func start() -> void:
	_frames.clear()
	_accum = 0.0
	_elapsed = 0.0
	recording = true

func stop() -> void:
	recording = false

func frame_count() -> int:
	return _frames.size()

func duration() -> float:
	if _frames.is_empty():
		return 0.0
	return float(_frames[-1]["t"])

func sample_at_index_t(i: int) -> float:
	return float(_frames[clampi(i, 0, _frames.size() - 1)]["t"])

func _physics_process(delta: float) -> void:
	if not recording or _car == null:
		return
	_elapsed += delta
	_accum += delta
	if _accum < 1.0 / SAMPLE_HZ and not _frames.is_empty():
		return
	_accum = 0.0
	_frames.append(_capture())

func _capture() -> Dictionary:
	var steer := PackedFloat32Array()
	var omega := PackedFloat32Array()
	var dt = _car.get("drivetrain")
	for w in _wheels:
		steer.append(w.steering)
		omega.append(dt.wheel_omega(w) if dt != null else 0.0)
	var eng = dt.engine if dt != null else null
	return {
		"t": _elapsed,
		"xform": _car.global_transform,
		"velocity": _car.linear_velocity,
		"rpm": (eng.rpm() if eng != null else 0.0),
		"throttle": (eng.throttle if eng != null else 0.0),
		"misfire": (eng.misfire_level if eng != null else 0.0),
		"handbrake": bool(_car.get("ai_handbrake")),
		"wheel_steer": steer,
		"wheel_omega": omega,
	}

# --- test seam: inject frames without physics ---
func _push_test_frame(t: float, origin: Vector3) -> void:
	var z := PackedFloat32Array([0, 0, 0, 0])
	_frames.append({
		"t": t, "xform": Transform3D(Basis.IDENTITY, origin), "velocity": Vector3.ZERO,
		"rpm": 0.0, "throttle": 0.0, "misfire": 0.0, "handbrake": false,
		"wheel_steer": z.duplicate(), "wheel_omega": z.duplicate(),
	})

func sample_at(t: float) -> Dictionary:
	if _frames.is_empty():
		return {}
	if _frames.size() == 1:
		return _frames[0]
	t = clampf(t, 0.0, duration())
	# Find the bracketing pair (linear scan is fine — a few thousand frames).
	var hi := 1
	while hi < _frames.size() and float(_frames[hi]["t"]) < t:
		hi += 1
	hi = mini(hi, _frames.size() - 1)
	var a: Dictionary = _frames[hi - 1]
	var b: Dictionary = _frames[hi]
	var span := float(b["t"]) - float(a["t"])
	var f := 0.0 if span <= 0.0 else (t - float(a["t"])) / span
	return _lerp_frame(a, b, f)

func _lerp_frame(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	var steer := PackedFloat32Array()
	var omega := PackedFloat32Array()
	for i in a["wheel_steer"].size():
		steer.append(lerpf(a["wheel_steer"][i], b["wheel_steer"][i], f))
		omega.append(lerpf(a["wheel_omega"][i], b["wheel_omega"][i], f))
	return {
		"t": lerpf(a["t"], b["t"], f),
		"xform": a["xform"].interpolate_with(b["xform"], f),
		"velocity": a["velocity"].lerp(b["velocity"], f),
		"rpm": lerpf(a["rpm"], b["rpm"], f),
		"throttle": lerpf(a["throttle"], b["throttle"], f),
		"misfire": lerpf(a["misfire"], b["misfire"], f),
		"handbrake": (a["handbrake"] if f < 0.5 else b["handbrake"]),
		"wheel_steer": steer,
		"wheel_omega": omega,
	}
