class_name LoadingScreen
extends CanvasLayer
# Full-screen "loading" overlay shown while world.gd builds the world.
#
# Godot's own boot bar only covers engine + .pck load + script compile. The
# world generation that runs in world.gd._ready() (track, terrain ring, tree
# and bush scatter) is heavy and synchronous, so without this the screen sits
# frozen with no feedback between the boot bar finishing and the first playable
# frame. world.gd shows this overlay first, yielding a frame at each generation
# stage boundary so the screen actually paints, and calls `finish()` when the
# world is ready.
#
# The step line shows a gameplay TIP (LoadingTips), not the generation stage, and world.gd
# ::_stage still print()s the stage name for perf debugging regardless. The tip
# CYCLES to a fresh draw every _TIP_CYCLE_SEC so a long load doesn't sit on one
# line for its whole duration. Other callers build their OWN LoadingScreen
# instance and set_title() it; the step line keeps cycling its tips under them, and only a set_step() call locks it
# (see `_step_locked`).
#
# The headline's trailing ellipsis is ANIMATED (0 → 1 → 2 → 3 dots, looping)
# rather than a static "…". Because the headline is center-aligned the dots
# live in a SIBLING label whose custom_minimum_size is pinned to the pixel width
# of 3 "." glyphs (measured from the font directly), so adding/removing visible
# dots never shifts the centered base text — this does NOT rely on the font
# being monospace (Jersey10, the current UI font, is not).
#
# STORY mode (`story()`, the cold open's opening lines, free-roam.md → *Cold open*): the headline
# and tip give way to a few lines of text shown one after another for a set time each; the last one
# stays until the loading is done. `story_running()` / `story_finished` let the caller hold the
# hand-over until every line has had its time, however fast the load was.

signal story_finished

# Drawn above the HUD (layer 2) and mobile controls (layer 3).
const _LAYER := 100

# A new tip is drawn this often while the overlay is up. Long loads (the world
# build, the menu showcase) used to show one tip for their entire duration; a
# slow first load could sit on the same sentence for 15+ seconds.
const _TIP_CYCLE_SEC := 7.0

# One ellipsis step every this many seconds: 0 → 1 → 2 → 3 → 0. Fast enough to
# read as "working", slow enough not to flicker.
const _DOT_STEP_SEC := 0.4

# The dot field is always this wide (in characters). The monospace UI font
# guarantees a slot is the same width whether the slot holds a "." or a space,
# so the headline's center never moves as the visible count changes.
const _MAX_DOTS := 3

var _title: Label       # base headline, e.g. "LOADING STAGE 2 OF 8" (no ellipsis)
var _dots: Label        # animated trailing dots — always _MAX_DOTS chars wide
var _step: Label

var _tip_timer := 0.0
var _dot_timer := 0.0
var _dot_count := 0
# True once set_step() is called — a caller that supplied its own status text
# ("Uploading…", "Preparing the garage…") owns the step line, and the tip
# cycle must not overwrite it. world.gd's own generation never calls set_step,
# so its tip keeps cycling for the whole load.
var _step_locked := false

var _box: VBoxContainer
var _headline: HBoxContainer
var _story: Label
var _story_lines := PackedStringArray()
var _story_i := -1
var _story_t := 0.0
var _story_each := 0.0
# The story clock never takes more than this from one frame, so a frame frozen by the synchronous
# world build doesn't eat a line's time before it has been seen.
const _STORY_MAX_STEP_SEC := 0.1


func _init() -> void:
	layer = _LAYER
	add_to_group("loading_screen")

	var bg := ColorRect.new()
	bg.color = UITheme.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(box)
	_box = box

	# Headline = base label + animated-dots label, side by side in a centered
	# HBox. The dots label always holds _MAX_DOTS character slots (visible "."
	# plus padding spaces), so cycling the dot count changes which slots are
	# lit without changing the pair's total width — the center-aligned base
	# text stays put.
	var headline := HBoxContainer.new()
	headline.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(headline)
	_headline = headline

	# The headline (title + dots) is the one thing on this screen, so it wears
	# UITheme.TITLE_FONT_SIZE — same exception as UITheme.title()/card_title() (see
	# features/ui-design-system.md house rule 2). Both labels share it since they sit
	# side by side as one continuous line of text.
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_title.add_theme_font_size_override("font_size", UITheme.TITLE_FONT_SIZE)
	headline.add_child(_title)

	_dots = Label.new()
	_dots.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_dots.add_theme_font_size_override("font_size", UITheme.TITLE_FONT_SIZE)
	_dots.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var dot_w := UITheme.font().get_string_size(
		".".repeat(_MAX_DOTS), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.TITLE_FONT_SIZE).x
	_dots.custom_minimum_size = Vector2(dot_w, 0)
	headline.add_child(_dots)

	# Defaults — set_title() strips the trailing "…" (the animated dots
	# replace it) and _refresh_dots() seeds the initial 0-dot field.
	set_title("Loading stage…")
	_refresh_dots()

	_step = Label.new()
	# The FIRST tip draw — _process redraws it every _TIP_CYCLE_SEC unless the step
	# line is locked. A caller that wants its OWN status text instead overwrites this
	# via set_step() on its own instance immediately after construction.
	_step.text = UITheme.caps(LoadingTips.random())
	_step.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Word-wrap rather than overflow: unlike the short status lines set_step() carries
	# elsewhere, a tip is a full sentence and the VBox it sits in spans the whole screen
	# width, which is narrow on a portrait phone.
	_step.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_step.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	_step.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_step)


func _process(delta: float) -> void:
	if _story_i >= 0:
		_story_tick(delta)
	# Cycle the tip unless a caller has claimed the step line with set_step().
	if not _step_locked:
		_tip_timer += delta
		if _tip_timer >= _TIP_CYCLE_SEC:
			_tip_timer -= _TIP_CYCLE_SEC
			_step.text = UITheme.caps(LoadingTips.random())

	# Animate the trailing ellipsis: 0 → 1 → 2 → 3 → 0. The dots label is
	# always _MAX_DOTS chars wide, so this never moves the base headline.
	_dot_timer += delta
	if _dot_timer >= _DOT_STEP_SEC:
		_dot_timer -= _DOT_STEP_SEC
		_dot_count = (_dot_count + 1) % (_MAX_DOTS + 1)
		_refresh_dots()


# Rewrite the dots label to show _dot_count dots, left-aligned inside a box whose
# custom_minimum_size is pinned to the pixel width of _MAX_DOTS dots (set in
# _init) — so the headline pair's centered position is invariant under this
# change regardless of whether the UI font is monospace.
func _refresh_dots() -> void:
	if _dots == null:
		return
	_dots.text = ".".repeat(_dot_count)


# Set the headline (defaults to "Loading stage…"; the HQ uses its own wording).
# A trailing "…" is stripped — the animated dots label replaces it, and leaving
# both would stack ("……").
func set_title(text: String) -> void:
	if _title != null:
		var capped := UITheme.caps(text)
		if capped.ends_with("…"):
			capped = capped.substr(0, capped.length() - 1)
		_title.text = capped


# Overwrite the step line with `text` (e.g. "Preparing the garage…"), replacing whatever
# random tip _init() picked. world.gd's own generation stages do NOT call this any more —
# see the header comment — but a caller wanting a short, specific status line on its own
# LoadingScreen instance still can. Calling this LOCKS the step line: the tip cycle is
# stopped so a caller's own status text is never overwritten by a random tip on the next
# 7-second tick.
func set_step(text: String) -> void:
	if _step != null:
		_step.text = UITheme.caps(text)
		_step_locked = true


# Show `lines` one after another, `seconds_each` apiece, in place of the headline and tips. The
# last line stays up until finish().
func story(lines: PackedStringArray, seconds_each: float) -> void:
	if lines.is_empty():
		return
	if _story == null:
		_story = Label.new()
		_story.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_story.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_story.custom_minimum_size = Vector2(1, 0)
		_story.add_theme_font_size_override("font_size", UITheme.TITLE_FONT_SIZE)
		_box.add_child(_story)
	_headline.visible = false
	_step.visible = false
	_story_lines = lines
	_story_each = seconds_each
	_story_i = 0
	_story_t = 0.0
	_story.text = UITheme.caps(lines[0])


# True while a story line still has time to run (the last one counts until its time is up).
func story_running() -> bool:
	return _story_i >= 0 and (_story_i < _story_lines.size() - 1 or _story_t < _story_each)


func is_story() -> bool:
	return _story_i >= 0


# The line on screen, or "" outside story mode.
func story_line() -> String:
	return _story_lines[_story_i] if _story_i >= 0 else ""


func _story_tick(delta: float) -> void:
	var was := story_running()
	_story_t += minf(delta, _STORY_MAX_STEP_SEC)
	if _story_t >= _story_each and _story_i < _story_lines.size() - 1:
		_story_i += 1
		_story_t = 0.0
		_story.text = UITheme.caps(_story_lines[_story_i])
	if was and not story_running():
		story_finished.emit()


# Tear the overlay down once the world is ready.
func finish() -> void:
	queue_free()
