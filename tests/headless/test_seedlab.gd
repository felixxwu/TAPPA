extends GutTest
# The dev seed-lab page is reachable, renders a preview for a (seed, water level)
# combination, and is keyboard/gamepad navigable (a control takes focus).

var _menu

func before_each() -> void:
	Config.reset()
	_menu = load("res://scripts/settings_menu.gd").new()
	add_child_autofree(_menu)
	await get_tree().process_frame

func after_each() -> void:
	Config.reset()

func test_seedlab_reachable_and_renders() -> void:
	assert_true(_menu.has_method("show_seedlab"), "seed lab page reachable")
	_menu.show_seedlab()
	# show_seedlab kicks off an async regenerate; let it complete.
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(_menu._seedlab_preview != null, "seed lab has a preview widget")

func test_seedlab_is_navigable() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	_menu.focus_current_page()
	await get_tree().process_frame
	var focused: Control = _menu.get_viewport().gui_get_focus_owner()
	assert_not_null(focused, "a control is focused on the seed-lab page")

# The event picker opens as a popup, lists real rally events, and takes focus so a
# controller can walk it.
# Left/right on a field is contained to the field grid — it may swap columns but
# must never leak onto the bottom button row.
func test_seedlab_leftright_contained_on_fields() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	var fields: Array = [_menu._seed_spin, _menu._level_spin, _menu._turns_spin,
		_menu._straight_spin]
	for spin in fields:
		var left: Control = spin.find_valid_focus_neighbor(SIDE_LEFT)
		var right: Control = spin.find_valid_focus_neighbor(SIDE_RIGHT)
		assert_true(left == null or left == spin or fields.has(left),
			"left on a field stays within the grid, never a button")
		assert_true(right == null or right == spin or fields.has(right),
			"right on a field stays within the grid, never a button")

# Left/right on the bottom row walks between its buttons and never escapes up into
# the fields.
func test_seedlab_leftright_walks_button_row() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	var buttons: Array = []
	for text in ["Load event…", "Terrain…", "Randomize seed", "Back"]:
		var b := _find_button(_menu._seedlab_page, text)
		assert_not_null(b, "found button '%s'" % text)
		buttons.append(b)
	# Middle button steps to a sibling on both sides; ends stay contained (self).
	assert_eq(buttons[1].find_valid_focus_neighbor(SIDE_LEFT), buttons[0],
		"middle button steps left to a sibling")
	assert_eq(buttons[1].find_valid_focus_neighbor(SIDE_RIGHT), buttons[2],
		"middle button steps right to a sibling")
	for b in buttons:
		var l: Control = b.find_valid_focus_neighbor(SIDE_LEFT)
		var r: Control = b.find_valid_focus_neighbor(SIDE_RIGHT)
		assert_true(l == null or buttons.has(l) or l == b,
			"left stays within the button row")
		assert_true(r == null or buttons.has(r) or r == b,
			"right stays within the button row")

# Loading an event copies its terrain-noise fields into the terrain spinboxes and
# into the config the preview generates against — so the lab's water matches career.
# Whole library as opaque input; no dependency on a specific authored entry.
func test_load_event_copies_terrain() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	# Find an event that overrides layer-1 amplitude (opaque scan; no hard-coded id).
	var picked: Dictionary = {}
	for rally in RallyLibrary.all():
		for event in rally.get("events", []):
			if event.has("terrain_layer1_amplitude"):
				picked = event
				break
		if not picked.is_empty():
			break
	assert_false(picked.is_empty(), "found an event overriding terrain amplitude")
	_menu._load_event(picked)
	await get_tree().process_frame
	assert_eq(_menu._t1a.value, float(picked["terrain_layer1_amplitude"]),
		"terrain amplitude spinbox mirrors the event")
	# The synthetic event the preview generates from carries the terrain amplitude,
	# and its canonical config resolves it the same way the career stage does.
	var ev: Dictionary = _menu._seedlab_event()
	assert_eq(float(ev["terrain_layer1_amplitude"]), float(picked["terrain_layer1_amplitude"]),
		"lab event carries the terrain amplitude")
	var cfg = RallySession.canonical_event_config(ev)
	assert_eq(cfg.terrain_layer1_amplitude, float(picked["terrain_layer1_amplitude"]),
		"canonical config carries the event's terrain amplitude")

# Reopening the event picker restores the cursor to the row it last sat on.
func test_event_picker_remembers_focus() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	_menu._open_event_picker()
	await get_tree().process_frame
	# Move the cursor down a couple of rows, remember where it landed.
	var focused: Control = _menu.get_viewport().gui_get_focus_owner()
	var next: Control = focused.find_valid_focus_neighbor(SIDE_BOTTOM)
	assert_not_null(next, "there is a row below the first")
	next.grab_focus()
	await get_tree().process_frame
	var remembered: Control = _menu.get_viewport().gui_get_focus_owner()
	_menu._close_event_picker()
	await get_tree().process_frame
	_menu._open_event_picker()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(_menu.get_viewport().gui_get_focus_owner(), remembered,
		"reopening lands on the last-focused row")

# The whole point: after loading a real event, the lab generates a track with the
# SAME cache key the career pipeline produces — i.e. the identical track, not a
# look-alike. Compares two derivations of one event; pins no tunable value.
func test_loaded_event_matches_career_cache_key() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	var event: Dictionary = RallyLibrary.all()[0]["events"][0]
	_menu._load_event(event)
	await get_tree().process_frame
	# Career derivation.
	var career_cfg: GameConfig = RallySession.canonical_event_config(event)
	var career_key: String = TrackCache.key_for(
		TrackGenParams.for_event(event, career_cfg), career_cfg)
	# Lab derivation (from the spinboxes it copied the event into).
	var lab_ev: Dictionary = _menu._seedlab_event()
	var lab_cfg: GameConfig = RallySession.canonical_event_config(lab_ev)
	var lab_key: String = TrackCache.key_for(
		TrackGenParams.for_event(lab_ev, lab_cfg), lab_cfg)
	assert_eq(lab_key, career_key,
		"the lab generates the identical track the career pipeline caches")

func test_terrain_editor_opens_and_is_navigable() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	_menu._open_terrain_editor()
	await get_tree().process_frame
	assert_true(_menu._seedlab_terrain_popup.visible, "terrain editor is shown")
	var focused: Control = _menu.get_viewport().gui_get_focus_owner()
	assert_not_null(focused, "a control is focused in the terrain editor")

func _find_button(root: Node, text: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		if (node as Button).text.to_lower() == text.to_lower():
			return node
	return null

func test_event_picker_opens_and_is_navigable() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	_menu._open_event_picker()
	await get_tree().process_frame
	assert_true(_menu._seedlab_popup.visible, "event picker popup is shown")
	var focused: Control = _menu.get_viewport().gui_get_focus_owner()
	assert_not_null(focused, "a control is focused in the event picker")

# Loading a real library event copies its drivable fields into the spinboxes (the
# single source of truth) and closes the picker. Uses the whole library as opaque
# input — no dependency on any one authored entry.
func test_load_event_copies_into_inputs() -> void:
	_menu.show_seedlab()
	await get_tree().process_frame
	var rally: Dictionary = RallyLibrary.all()[0]
	var event: Dictionary = rally["events"][0]
	_menu._load_event(event)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(_menu._seedlab_popup.visible, "picker closes after loading")
	assert_eq(int(_menu._seed_spin.value), int(event["seed"]),
		"seed spinbox mirrors the event")
	assert_eq(int(_menu._turns_spin.value), int(event["turn_count"]),
		"turns spinbox mirrors the event")
	assert_true(_menu._seedlab_preview != null, "preview rendered for the event")
