class_name CarFixtures
extends RefCounted
# A synthetic car + engine catalogue for tests. Install it (install()) to run
# against a stable, test-owned roster that never tracks the shipped catalogue, so
# renames/retunes/adds/removes of real cars can't break a test. Always restore()
# in teardown. Fixture engines reuse real EngineLibrary FIRING layout keys so
# EngineLibrary.apply() and the audio path keep working.
#
# The four cars span the axes tests exercise: drivetrain (RWD/FWD/AWD), weight
# bias (nose-heavy / tail-heavy / ~50-50), body size, and power-to-weight band.

const RWD := 0
const AWD := 1
const FWD := 2


static func engines() -> Array[Dictionary]:
	var list: Array[Dictionary] = [
		{
			"id": "fx_i4", "name": "Fixture i4", "layout": "i4", "mass": 120.0,
			"redline_rpm": 7000.0, "peak_torque": 200.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.15,
			"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
			"gear_ratios": [3.5, 2.0, 1.4, 1.0, 0.8], "final_drive": 4.0, "shift_time": 0.30,
		},
		{
			"id": "fx_v8", "name": "Fixture V8", "layout": "v8", "mass": 220.0,
			"redline_rpm": 6500.0, "peak_torque": 500.0, "peak_torque_rpm": 4000.0, "engine_inertia": 0.35,
			"low_octave_mix": 0.6, "volume_db": 6.0, "noise_db": -54.0, "soft_clip_post_gain": 0.1,
			"gear_ratios": [3.0, 1.8, 1.3, 1.0, 0.75], "final_drive": 3.5, "shift_time": 0.25,
		},
	]
	return _deep_copy(list)


static func cars() -> Array[Dictionary]:
	var list: Array[Dictionary] = [
		{
			"name": "Fixture Roadster", "id": "fx_light_rwd", "country": "JP", "car_type": "roadster",
			"max_hp": 800.0, "reward_tier": 1, "mass": 1050.0, "engine": "fx_i4",
			"weight_front": 0.50, "engine_pos": 0.85, "tire_compound": 1.0,
			"drive_mode": RWD, "drag": 0, "downforce_rear": 0, "bonnet_cam_offset": Vector3.ZERO,
			"body": Vector3(1.5, 0.50, 3.8), "cabin": Vector3(1.35, 0.45, 1.40),
			"cabin_z": 0.25, "track": 1.4, "wheelbase": 2.45,
			"wheel_radius": 0.30, "wheel_width_front": 0.195, "wheel_width_rear": 0.195,
			"suspension_travel": 0.42, "suspension_stiffness": 10.0,
		},
		{
			"name": "Fixture Hatch", "id": "fx_fwd_hatch", "country": "US", "car_type": "hatch",
			"max_hp": 950.0, "reward_tier": 1, "mass": 900.0, "engine": "fx_i4",
			"weight_front": 0.62, "engine_pos": 0.85, "tire_compound": 1.05,
			"drive_mode": FWD, "drag": 0, "downforce_rear": 0, "bonnet_cam_offset": Vector3.ZERO,
			"body": Vector3(1.80, 0.55, 4.30), "cabin": Vector3(1.45, 0.50, 1.60),
			"cabin_z": 0.10, "track": 1.55, "wheelbase": 2.60,
			"wheel_radius": 0.32, "wheel_width_front": 0.235, "wheel_width_rear": 0.235,
			"suspension_travel": 0.40, "suspension_stiffness": 11.0,
		},
		{
			"name": "Fixture Coupe", "id": "fx_rwd_coupe", "country": "GB", "car_type": "coupe",
			"max_hp": 1100.0, "reward_tier": 3, "mass": 1600.0, "engine": "fx_v8",
			"weight_front": 0.45, "engine_pos": 0.40, "tire_compound": 1.20,
			"drive_mode": RWD, "drag": 0, "downforce_rear": 0, "bonnet_cam_offset": Vector3.ZERO,
			"body": Vector3(1.90, 0.46, 4.50), "cabin": Vector3(1.45, 0.44, 1.50),
			"cabin_z": 0.10, "track": 1.60, "wheelbase": 2.60,
			"wheel_radius": 0.34, "wheel_width_front": 0.245, "wheel_width_rear": 0.285,
			"suspension_travel": 0.38, "suspension_stiffness": 16.0,
		},
		{
			"name": "Fixture AWD", "id": "fx_awd", "country": "IT", "car_type": "coupe",
			"max_hp": 1000.0, "reward_tier": 2, "mass": 1500.0, "engine": "fx_v8",
			"weight_front": 0.55, "engine_pos": 0.60, "tire_compound": 1.15,
			"drive_mode": AWD, "drag": 0, "downforce_rear": 0, "bonnet_cam_offset": Vector3.ZERO,
			"body": Vector3(1.85, 0.50, 4.40), "cabin": Vector3(1.45, 0.46, 1.55),
			"cabin_z": 0.10, "track": 1.60, "wheelbase": 2.60,
			"wheel_radius": 0.33, "wheel_width_front": 0.240, "wheel_width_rear": 0.240,
			"suspension_travel": 0.40, "suspension_stiffness": 13.0,
		},
	]
	return _deep_copy(list)


static func install() -> void:
	EngineLibrary.override_for_test(engines())
	CarLibrary.override_for_test(cars())


static func restore() -> void:
	CarLibrary.reset()
	EngineLibrary.reset()


static func _deep_copy(list: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in list:
		out.append(d.duplicate(true))
	return out
