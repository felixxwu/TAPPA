class_name MenuFlow
extends Node
# Menu-flow replay (features/menu-navigation.md → "Menu-flow replays"): boots the world under the golden
# settings, plays a scripted list of menu presses through the real keyboard and gamepad bindings, and writes
# one JSON line per press saying which page is up, what has focus, what the press changed and where every
# visible widget sits. Not part of the test suite. Run it with
#
#     $GODOT --headless --fixed-fps 60 res://benchmark/menu_flow.tscn -- --golden --seed=90210 [--flow=…] [--out=<file> | --bless | --check]
#
# --bless rewrites goldens/menus.jsonl.gz (through ./bless.sh menus); --check compares a fresh run with it and exits 1 on
# the first line that differs; otherwise the log goes to --out (default user://menu_flow.jsonl).

const DEFAULT_FLOW := "res://benchmark/flows/menus.json"
const DEFAULT_OUT := "user://menu_flow.jsonl"
const GOLDEN_PATH := "res://goldens/menus.jsonl.gz"
const FIXTURE_PROFILE_PATH := "user://menu_flow_profile.json"  # never written: save_disabled is on
const FRAME := Vector2i(1280, 720)  # logical pixels, so every machine lays the pages out the same

var _flow_path := DEFAULT_FLOW
var _out_path := DEFAULT_OUT
var _mode := "out"  # out, bless or check
var _seed := Benchmark.RNG_SEED
var _rows := PackedStringArray()
var _level: Node
var _view: LevelView
var _state := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # most pages pause the tree
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--flow="):
			_flow_path = arg.get_slice("=", 1)
		elif arg.begins_with("--out="):
			_out_path = arg.get_slice("=", 1)
		elif arg.begins_with("--seed="):
			_seed = int(arg.get_slice("=", 1))
		elif arg == "--bless" or arg == "--check":
			_mode = arg.trim_prefix("--")
	var flow: Variant = JSON.parse_string(FileAccess.get_file_as_string(_flow_path))
	if not flow is Dictionary:
		push_error("menu flow: can't read %s" % _flow_path)
		get_tree().quit(1)
		return
	Benchmark.active = true
	Benchmark.golden = true
	Save.profile_path = FIXTURE_PROFILE_PATH
	Save.save_disabled = true
	Config.data.threaded_chunk_build = false
	Config.data.threaded_tree_build = false
	var car := Config.data.level_car_id
	var n := 0
	# Each device starts from a fresh world, so a page left stuck open by one pass can't derail the next.
	for device: String in flow.get("devices", ["key"]):
		Config.data.level_car_id = car
		await _boot()
		if n == 0:
			_write({"format": "menu-flow-1", "level_path": Config.data.level_path, "car": car, "seed": _seed,
				"recording": _flow_path, "godot_version": Engine.get_version_info()["string"], "platform": OS.get_name(),
				"frame": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y]})
		_state = _snapshot()
		for step: Dictionary in flow.get("steps", []):
			if step.get("only", device) != device:
				continue
			var what := await _play(step, device)
			var now := _snapshot()
			var focus := get_viewport().gui_get_focus_owner()
			var row := line(_page_root(focus), focus, diff(_state, now))
			row["step"] = n
			row["device"] = device
			row["press"] = what
			_write(row)
			_state = now
			n += 1
		_level.free()
		get_tree().paused = false
	get_tree().quit(_finish())


# The same footing as a golden level replay: no cloud, a blank profile, fixed seeds, the world built on the main thread.
func _boot() -> void:
	Save.profile = Save._default_profile()
	RngStreams.reseed(_seed)
	LevelView.owned = {}
	LevelView.delivery = {}
	LevelView.last_point = -1
	_fix_frame()
	_level = load(Scenes.WORLD).instantiate()
	add_child(_level)
	_view = _level.get_node("Level") as LevelView
	var pause: PauseMenu = _level.get_node("PauseMenu")
	while not pause.is_armed():
		await get_tree().process_frame
	_fix_frame()
	await _frames(2)


# Writes or checks the log; returns the exit code.
func _finish() -> int:
	var text := "\n".join(_rows) + "\n"
	if _mode == "check":
		var blessed := FileAccess.get_file_as_bytes(GOLDEN_PATH)
		if blessed.is_empty():
			push_error("menu flow: no golden at %s (./bless.sh menus)" % GOLDEN_PATH)
			return 1
		var want := blessed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8().split("\n")
		for i in maxi(want.size(), _rows.size() + 1):
			var got := _rows[i] if i < _rows.size() else ""
			if i >= want.size() or want[i] != got:
				push_error("menu flow: differs from %s at line %d\n  want: %s\n  got:  %s" % [GOLDEN_PATH, i + 1,
					want[i] if i < want.size() else "(end)", got])
				return 1
		print("menu flow: matches %s (%d lines)" % [GOLDEN_PATH, _rows.size()])
		return 0
	var path := GOLDEN_PATH if _mode == "bless" else _out_path
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("menu flow: can't write %s" % path)
		return 1
	var bytes := text.to_utf8_buffer()
	f.store_buffer(bytes.compress(FileAccess.COMPRESSION_GZIP) if _mode == "bless" else bytes)
	f.close()
	print("menu flow: %d lines written to %s" % [_rows.size(), ProjectSettings.globalize_path(path)])
	return 0


# One flow step; returns what was sent, for the log. Steps: {"press": action}, {"key": name}, {"type": text}, {"paste": text},
# {"call": LevelView method, "args": [...]} for pages no press can reach headless, {"wait": frames}.
# "only": "key" or "pad" plays a step on that device alone, where the two genuinely need different presses.
func _play(step: Dictionary, device: String) -> String:
	var what := ""
	if step.has("press"):
		var ev := binding(String(step["press"]), device)
		if ev == null:
			push_error("menu flow: %s has no binding" % step["press"])
			return "%s: unbound" % step["press"]
		what = "%s: %s" % [step["press"], ev.as_text()]
		_send(ev)
	elif step.has("type"):
		what = "type: " + String(step["type"])
		for ch in String(step["type"]):
			var k := InputEventKey.new()
			k.unicode = ch.unicode_at(0)
			_send(k)
	elif step.has("key"):  # a key with no action of its own (Tab opens the map's delivery list)
		var k := InputEventKey.new()
		k.keycode = OS.find_keycode_from_string(String(step["key"]))
		k.physical_keycode = k.keycode
		what = "key: " + k.as_text()
		_send(k)
	elif step.has("paste"):
		what = "paste: " + _paste(String(step["paste"]))
	elif step.has("call"):
		what = "call: " + String(step["call"])
		var args: Array = step.get("args", []).map(_arg)
		_view.callv(String(step["call"]), args)
	await _frames(1)  # input reaches the GUI on the next frame
	# A picked card flashes for half a second before it acts; skip the flash so each press is one step.
	for c in get_tree().root.find_children("*", "CardCarousel", true, false):
		c.skip_confirm_flash()
	await _frames(int(step.get("wait", 2)))
	return what


# JSON has no ints or vectors: whole numbers become ints and {"teleport": i} becomes that point's position.
func _arg(a: Variant) -> Variant:
	if a is float and a == roundf(a):
		return int(a)
	if a is Dictionary and a.has("teleport"):
		return _view.teleport_points()[int(a["teleport"])]
	return a


# The first event bound to `action` for the device (an InputEventKey, or a joypad button or stick); the
# keyboard binding when the gamepad has none.
static func binding(action: String, device: String) -> InputEvent:
	var key: InputEvent = null
	for ev in InputMap.action_get_events(action) if InputMap.has_action(action) else []:
		if ev is InputEventKey and key == null:
			key = ev
		elif device == "pad" and (ev is InputEventJoypadButton or ev is InputEventJoypadMotion):
			return ev
	return key


func _send(ev: InputEvent) -> void:
	var down := ev.duplicate() as InputEvent
	down.device = 0  # the map's copy says "any device" (-1), which no real event does and built-in actions won't match
	if down is InputEventKey:
		# A real key carries both codes; built-in actions like ui_text_submit match only the one they were bound by.
		var k := down as InputEventKey
		if k.keycode == KEY_NONE:
			k.keycode = k.physical_keycode
		if k.physical_keycode == KEY_NONE:
			k.physical_keycode = k.keycode
	if down is InputEventJoypadMotion:
		(down as InputEventJoypadMotion).axis_value = signf((ev as InputEventJoypadMotion).axis_value)
	else:
		down.set("pressed", true)
	Input.parse_input_event(down)
	var up := down.duplicate() as InputEvent
	if up is InputEventJoypadMotion:
		(up as InputEventJoypadMotion).axis_value = 0.0
	else:
		up.set("pressed", false)
	Input.parse_input_event(up)


# Pastes through the clipboard and the platform's paste key; a headless clipboard that keeps nothing falls back
# to writing the focused field directly. Returns which path ran.
func _paste(text: String) -> String:
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(text)
		for ev in InputMap.action_get_events("ui_paste"):
			if ev is InputEventKey:
				_send(ev)
				return "%s (clipboard, %s)" % [text, ev.as_text()]
	var field := get_viewport().gui_get_focus_owner() as LineEdit
	if field == null:
		return "%s (nothing focused to paste into)" % text
	field.insert_text_at_caret(text)
	field.text_changed.emit(field.text)
	return "%s (no clipboard: set the field)" % text


# DisplayStretch would re-fit the logical frame to whatever window this machine opened.
func _fix_frame() -> void:
	DisplayStretch.process_mode = Node.PROCESS_MODE_DISABLED
	var window := get_window()
	if window.size_changed.is_connected(DisplayStretch._apply):
		window.size_changed.disconnect(DisplayStretch._apply)
	window.size = FRAME
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	window.content_scale_size = FRAME


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _write(row: Dictionary) -> void:
	_rows.append(JSON.stringify(row, "", true, true))


# The state a menu press can change: the profile's settings and the level's session state.
# Where the car is and what the map has uncovered: saved by driving, not by any menu.
const NOT_MENU_SETTINGS := ["level_pose", "level_map_seen"]


func _snapshot() -> Dictionary:
	var s := {}
	for k: String in Save.profile.get("settings", {}):
		if k in NOT_MENU_SETTINGS:
			continue
		s["settings." + k] = Save.profile["settings"][k]
	s["level.owned"] = LevelView.owned
	s["level.delivery"] = LevelView.delivery
	s["level.last_point"] = LevelView.last_point
	s["level.car_id"] = Config.data.level_car_id
	s["paused"] = get_tree().paused
	s["map_open"] = _view.map != null and _view.map.visible
	return JSON.parse_string(JSON.stringify(s))  # a deep copy, as plain JSON values


# Every key whose value differs, as key -> [before, after] (null where absent).
static func diff(before: Dictionary, after: Dictionary) -> Dictionary:
	var out := {}
	for k in before.keys() + after.keys():
		if not out.has(k) and before.get(k) != after.get(k):
			out[k] = [before.get(k), after.get(k)]
	return out


# The page a press lands on: the menu holding the focus, else the top on-screen menu, else the open map (none while driving).
func _page_root(focus: Control) -> Control:
	var n: Node = focus
	while n != null:
		if n is Control and MenuNav.of(n) != null:
			return n
		n = n.get_parent()
	var best: Control = null
	var best_layer := -(1 << 30)
	for nav in get_tree().root.find_children("*", "Node", true, false):
		if nav is MenuNav and MenuNav.is_on_screen(nav.get_parent()):
			var layer := _layer_of(nav)
			if layer >= best_layer:
				best = nav.get_parent()
				best_layer = layer
	if best == null and _view.map != null and _view.map.visible:
		return _view.map
	return best


static func _layer_of(n: Node) -> int:
	while n != null:
		if n is CanvasLayer:
			return (n as CanvasLayer).layer
		n = n.get_parent()
	return 0


# One log line: the page's id, the focused item's label, what changed and every visible widget's box.
static func line(root: Control, focus: Control, changed: Dictionary) -> Dictionary:
	return {"page": page_id(root), "focus": focus_label(focus), "changed": changed, "boxes": boxes(root)}


# The page's title text and the nearest script class above it, e.g. "Settings (MenuPage)"; no node paths,
# so renaming a node doesn't change the log.
static func page_id(root: Control) -> String:
	if root == null:
		return ""
	var title := ""
	var cls := ""
	var n: Node = root
	while n != null and (title == "" or cls == ""):
		if title == "" and n is MenuPage and (n as MenuPage).title_label() != null:
			title = (n as MenuPage).title_label().text
		var script := n.get_script() as Script
		if cls == "" and script != null and script.get_global_name() != "":
			cls = script.get_global_name()
		n = n.get_parent()
	if title == "":
		for l in root.find_children("*", "Label", true, false):
			if (l as Label).is_visible_in_tree() and (l as Label).text != "":
				title = (l as Label).text
				break
	return "%s (%s)" % [title, cls if cls != "" else root.get_class()]


static func focus_label(focus: Control) -> String:
	if focus == null:
		return ""
	if focus is CardCarousel:
		var titles := CardUI.titles(focus)
		var i := (focus as CardCarousel).selected_index()
		return titles[i] if i < titles.size() else ""
	var text: Variant = focus.get("text")
	if text is String and text != "":
		return text
	# An icon button or a slider: name it by the label beside it, as a player would.
	for n: Node in [focus, focus.get_parent()]:
		var named := _first_text(n)
		if named != "":
			return "%s (%s)" % [named, focus.get_class()]
	return focus.get_class()


static func _first_text(n: Node) -> String:
	if n == null:
		return ""
	for c in n.find_children("*", "Label", true, false):
		if (c as Label).is_visible_in_tree() and (c as Label).text != "":
			return (c as Label).text
	return ""


# [label or class, [x, y, w, h]] for the root and every visible Control under it, in whole logical pixels.
static func boxes(root: Control) -> Array:
	var out := []
	if root == null:
		return out
	for c in [root] + root.find_children("*", "Control", true, false):
		if not (c as Control).is_visible_in_tree():
			continue
		var r := (c as Control).get_global_rect()
		var text: Variant = c.get("text")
		out.append([String(text) if text is String and text != "" else c.get_class(),
			[roundi(r.position.x), roundi(r.position.y), roundi(r.size.x), roundi(r.size.y)]])
	return out
