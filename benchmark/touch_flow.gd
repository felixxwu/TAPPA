class_name TouchFlow
extends Node
# Touch and tilt golden: plays one recorded set of screen touches and phone tilts through every touch-control scheme
# and logs, per physics tick, the gameplay actions the overlay is holding (TickInput.sample), so a port or refactor of
# the touch controls can be checked to turn the same fingers into the same inputs. NOT part of the test suite. Run on
# demand (features/mobile-controls.md):
#
#   godot --headless --fixed-fps 60 res://benchmark/touch_flow.tscn -- [--golden] [--seed=90210] [--out=<file>] [--check[=<golden>]] [--bless]

const FLOW_PATH := "res://benchmark/flows/touch.json"
# Touch points in the flow are fractions of this screen; the rects are laid out for it, not for the headless window.
const SCREEN := Vector2(1280, 720)
const DEFAULT_OUT := "user://touch_flow.jsonl"
const GOLDEN_PATH := "res://goldens/touch.jsonl.gz"  # written only by ./bless.sh touch (--bless)


func _ready() -> void:
	var out_path := DEFAULT_OUT
	var check_path := ""
	var bless := false
	var rng_seed := Benchmark.RNG_SEED
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_path = arg.get_slice("=", 1)
		elif arg == "--check":
			check_path = GOLDEN_PATH
		elif arg.begins_with("--check="):
			check_path = arg.get_slice("=", 1)
		elif arg == "--bless":
			bless = true
		elif arg.begins_with("--seed="):
			rng_seed = int(arg.get_slice("=", 1))
	Save.save_disabled = true
	RngStreams.reseed(rng_seed)
	Config.data.mobile_controls_force = true
	var controls := MobileControls.new()
	add_child(controls)
	var flow: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FLOW_PATH))
	var lines := PackedStringArray([JSON.stringify({"format": "touch/1", "seed": rng_seed, "recording": FLOW_PATH,
		"screen": [SCREEN.x, SCREEN.y], "godot_version": Engine.get_version_info().string, "platform": OS.get_name()},
		"", true, true)])
	for entry: Dictionary in MobileControls.SCHEMES:
		var rows: Array[Dictionary] = await play(controls, int(entry.id), flow.events, int(flow.ticks))
		for row in rows:
			lines.append(JSON.stringify(row, "", true, true))
	var text := "\n".join(lines) + "\n"
	if not _write(out_path, text) or (bless and not _write(GOLDEN_PATH, text)):
		get_tree().quit(1)
		return
	get_tree().quit(0 if check_path == "" or _check(lines, check_path) else 1)


## Plays `events` under `scheme` for `ticks` physics ticks and returns one row per tick:
## {scheme, tick, strengths, just_pressed}. An event is a touch {tick, touch, down, at}, a drag {tick, drag, at}
## (`at` as fractions of SCREEN), or a tilt {tick, tilt: "x:y:z"} in the web bridge's gravity format.
static func play(controls: MobileControls, scheme: int, events: Array, ticks: int) -> Array[Dictionary]:
	controls.set_process(false)  # stepped from here, once per tick, so nothing re-lays it out for the real window
	controls.set_scheme(scheme)
	controls._compute_rects(SCREEN)
	controls._tilt = TiltInput.new()
	var rows: Array[Dictionary] = []
	var tilt_seq := 0
	await controls.get_tree().physics_frame
	for t in ticks:
		for e: Dictionary in events:
			if int(e.tick) != t:
				continue
			if e.has("tilt"):
				tilt_seq += 1
				controls._tilt.adopt(tilt_seq, e.tilt)
			else:
				controls._input(touch_event(e))
		controls._apply_actions()
		# Godot only reports a press as just-pressed on the physics tick after it, which is when the car reads it.
		await controls.get_tree().physics_frame
		var row := TickInput.unpack(TickInput.sample())
		row["scheme"] = scheme
		row["tick"] = t
		rows.append(row)
	controls.set_scheme(scheme)  # lets go of everything, so the next scheme starts with nothing held
	return rows


static func touch_event(e: Dictionary) -> InputEvent:
	var ev
	if e.has("drag"):
		ev = InputEventScreenDrag.new()
		ev.index = int(e.drag)
	else:
		ev = InputEventScreenTouch.new()
		ev.index = int(e.touch)
		ev.pressed = bool(e.down)
	var at: Array = e.get("at", [0.0, 0.0])
	ev.position = Vector2(at[0], at[1]) * SCREEN
	return ev


# Writes `text` to `path`, gzipped when the path ends in .gz.
func _write(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("touch flow: can't write %s" % path)
		return false
	var bytes := text.to_utf8_buffer()
	file.store_buffer(bytes.compress(FileAccess.COMPRESSION_GZIP) if path.ends_with(".gz") else bytes)
	file.close()
	print("touch flow: wrote %s" % path)
	return true


# Compares every tick's row with the golden's (the header is skipped, since it names the Godot build) and prints the
# first that differs.
func _check(lines: PackedStringArray, golden_path: String) -> bool:
	var golden := SceneCounts._read(golden_path).strip_edges().split("\n")
	if golden.size() != lines.size():
		push_error("touch flow: %s has %d rows, this run %d" % [golden_path, golden.size() - 1, lines.size() - 1])
		return false
	for i in range(1, lines.size()):
		if golden[i] != lines[i]:
			print("touch flow: differs from %s\n  golden:   %s\n  this run: %s" % [golden_path, golden[i], lines[i]])
			return false
	print("touch flow: matches %s" % golden_path)
	return true
