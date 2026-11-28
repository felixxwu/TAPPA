class_name TickInput
# One physics tick of the driver's gameplay input, recorded by the level replay and played back by
# pressing the same actions through Input, so a replayed car drives itself exactly as it was driven.
#
# A row is a PackedFloat32Array: one strength per ACTIONS entry, then a bitmask of the actions that
# went down this tick (so a tap shorter than a tick still shows up once).

const ACTIONS: Array[StringName] = [&"accelerate", &"brake_reverse", &"steer_left", &"steer_right",
	&"handbrake", &"shift_up", &"shift_down", &"nitrous", &"reset_to_road", &"pause"]
# Read by _unhandled_input handlers (LevelView, PauseMenu), not polled, so these need a real input event.
const EVENT_ACTIONS: Array[StringName] = [&"reset_to_road", &"pause"]
const SIZE := 11  # ACTIONS.size() + 1


static func pack(strengths: Dictionary, just_pressed: Array) -> PackedFloat32Array:
	var row := PackedFloat32Array()
	row.resize(SIZE)
	var bits := 0
	for i in ACTIONS.size():
		row[i] = float(strengths.get(ACTIONS[i], 0.0))
		if just_pressed.has(ACTIONS[i]):
			bits |= 1 << i
	row[ACTIONS.size()] = bits  # under 2^24, so exact in a float32
	return row


static func unpack(row: PackedFloat32Array) -> Dictionary:
	var strengths := {}
	var just_pressed: Array[StringName] = []
	var bits := int(row[ACTIONS.size()])
	for i in ACTIONS.size():
		strengths[ACTIONS[i]] = row[i]
		if bits & (1 << i):
			just_pressed.append(ACTIONS[i])
	return {"strengths": strengths, "just_pressed": just_pressed}


# What the car sees this tick: the deadzone-applied strength, not the raw one, since that is what it reads.
static func sample() -> PackedFloat32Array:
	var strengths := {}
	var just_pressed: Array[StringName] = []
	for a in ACTIONS:
		strengths[a] = Input.get_action_strength(a) if Input.is_action_pressed(a) else 0.0
		if Input.is_action_just_pressed(a):
			just_pressed.append(a)
	return pack(strengths, just_pressed)


# Call from a _physics_process that runs before the car's (the replay is at priority -100).
static func apply(row: PackedFloat32Array) -> void:
	var bits := int(row[ACTIONS.size()])
	for i in ACTIONS.size():
		var a := ACTIONS[i]
		var s := row[i]
		var down := (bits & (1 << i)) != 0
		var held := Input.is_action_pressed(a)
		if a in EVENT_ACTIONS:
			if down:
				_send(a, true)
			elif held and s <= 0.0:
				_send(a, false)
			continue
		if down and held:
			Input.action_release(a)  # released and pressed again within one tick
			held = false
		if s > 0.0 or down:
			var strength := s if s > 0.0 else 1.0
			if not held or not is_equal_approx(Input.get_action_strength(a), strength):
				Input.action_press(a, strength)
		elif held:
			Input.action_release(a)


static func release_all() -> void:
	for a in ACTIONS:
		if Input.is_action_pressed(a):
			if a in EVENT_ACTIONS:
				_send(a, false)
			else:
				Input.action_release(a)


# Dispatched now rather than at the next frame, so it lands on the tick it was recorded on.
static func _send(action: StringName, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
