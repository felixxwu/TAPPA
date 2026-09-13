class_name LoadingScreen
extends CanvasLayer
# Full-screen "loading stage" overlay shown while world.gd builds the world.
#
# Godot's own boot bar only covers engine + .pck load + script compile. The
# world generation that runs in world.gd._ready() (track, terrain ring, tree
# and bush scatter) is heavy and synchronous, so without this the screen sits
# frozen with no feedback between the boot bar finishing and the first playable
# frame. world.gd shows this overlay first, yielding a frame at each generation
# stage boundary so the screen actually paints, and calls `finish()` when the
# world is ready.
#
# The step line shows a gameplay TIP (LoadingTips), not the generation stage —
# the player doesn't need to know the game is "Placing signs…", and world.gd
# ::_stage still print()s the stage name for perf debugging regardless. The tip
# CYCLES to a fresh draw every _TIP_CYCLE_SEC so a long load doesn't sit on one
# line for its whole duration. Other callers (menu_showcase.gd's build,
# hub_shell.gd's car-preview warming — both covering hub startup rather than a
# stage) build their OWN LoadingScreen instance and set_title() it; the step
# line keeps cycling its tips under them, and only a set_step() call locks it
# (see `_step_locked`).
#
# The headline's trailing ellipsis is ANIMATED (0 → 1 → 2 → 3 dots, looping)
# rather than a static "…". Because the headline is center-aligned the dots
# live in a SIBLING label whose width is pinned to 3 monospace glyph slots, so
# adding/removing visible dots never shifts the centered base text.

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
var _preview: TrackPreview

var _tip_timer := 0.0
var _dot_timer := 0.0
var _dot_count := 0
# True once set_step() is called — a caller that supplied its own status text
# ("Uploading…", "Preparing the garage…") owns the step line, and the tip
# cycle must not overwrite it. world.gd's own generation never calls set_step,
# so its tip keeps cycling for the whole load.
var _step_locked := false


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

	_preview = TrackPreview.new()
	box.add_child(_preview)

	# Headline = base label + animated-dots label, side by side in a centered
	# HBox. The dots label always holds _MAX_DOTS character slots (visible "."
	# plus padding spaces), so cycling the dot count changes which slots are
	# lit without changing the pair's total width — the center-aligned base
	# text stays put.
	var headline := HBoxContainer.new()
	headline.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(headline)

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


# Rewrite the dots label so the first _dot_count slots are "." and the rest are
# spaces. The Syne Mono UI font is monospace, so "." and " " occupy the same
# glyph advance — the label's width (and thus the headline pair's centered
# position) is invariant under this change.
func _refresh_dots() -> void:
	if _dots == null:
		return
	_dots.text = ".".repeat(_dot_count) + " ".repeat(_MAX_DOTS - _dot_count)


# Set the headline (defaults to "Loading stage…"; the HQ uses its own wording).
# A trailing "…" is stripped — the animated dots label replaces it, and leaving
# both would stack ("……").
func set_title(text: String) -> void:
	if _title != null:
		var capped := UITheme.caps(text)
		if capped.ends_with("…"):
			capped = capped.substr(0, capped.length() - 1)
		_title.text = capped


# Announce WHICH stage is loading — "Loading stage 2 of 3…" — so a multi-stage rally tells
# the player how far through it they are while they wait, and a one-stage rally does not
# imply there is more to come.
#
# `index` is 0-based (RallySession.event_index); `total` is that rally's own stage count,
# which is NOT always 3 — the opening rallies run a single stage (todo/opening-rally.md).
# A total of 1 or less says nothing extra and leaves the plain headline, since "stage 1 of
# 1" is noise.
#
# This REPLACED a weather tell ("Loading stage… it's raining"). The headline is now about
# progress, and mixing the two meant the stage number could only ever be shown on dry
# stages. Weather still announces itself in the world (features/weather.md); it just no
# longer competes for this line.
func set_stage(index: int, total: int) -> void:
	if total <= 1:
		return
	set_title("Loading stage %d of %d…" % [clampi(index + 1, 1, total), total])


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


# Update the live track drawing (the on_progress callback from TrackGenerator,
# and the one-shot finished-shape lock from world.gd). Points are in the
# generator's 2D world-XZ frame; fit_points handles the mapping.
func update_track_preview(points: PackedVector2Array) -> void:
	if _preview != null:
		_preview.set_points(points)


# World-XZ bounding box of `points` (position = min corner, size = span).
# Returns an empty Rect2 for no points; callers guard on size for the < 2 case.
static func bounds_of(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var min_x := points[0].x; var max_x := points[0].x
	var min_y := points[0].y; var max_y := points[0].y
	for p in points:
		min_x = minf(min_x, p.x); max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y); max_y = maxf(max_y, p.y)
	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


# Grow `bounds` (world XZ) so its aspect ratio matches `aspect` (= panel w / h),
# keeping it centred and never shrinking. When the fit then maps this into a panel
# of that aspect, it fills the panel edge-to-edge with no letterbox bands — so water
# sampled over the returned rect reaches the container edges. Pure. Returns `bounds`
# unchanged for a non-positive aspect or empty bounds.
static func expand_to_aspect(bounds: Rect2, aspect: float) -> Rect2:
	if aspect <= 0.0 or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return bounds
	var w := bounds.size.x
	var h := bounds.size.y
	if w / h < aspect:
		w = h * aspect  # too tall -> widen
	else:
		h = w / aspect  # too wide -> heighten
	var center := bounds.position + bounds.size * 0.5
	return Rect2(center - Vector2(w, h) * 0.5, Vector2(w, h))


# Aspect ratio (w / h) of a laid-out panel `size`, for feeding `expand_to_aspect`
# so water fills the panel edge-to-edge. Falls back to 16:9 before the panel has
# been laid out (zero size). Pure.
static func aspect_of(size: Vector2) -> float:
	return size.x / size.y if size.x > 0.0 and size.y > 0.0 else 16.0 / 9.0


# World-XZ -> screen map that fits `bounds` into `rect` (inset by `pad` on all
# sides), preserving aspect ratio and centering. `screen = xform * world`. Pure.
static func fit_transform(bounds: Rect2, rect: Rect2, pad: float) -> Transform2D:
	var span_x := maxf(bounds.size.x, 1e-3)
	var span_y := maxf(bounds.size.y, 1e-3)
	var inner := Vector2(maxf(rect.size.x - 2.0 * pad, 1.0), maxf(rect.size.y - 2.0 * pad, 1.0))
	var fit := minf(inner.x / span_x, inner.y / span_y)
	var draw_size := Vector2(span_x * fit, span_y * fit)
	var origin := rect.position + Vector2(pad, pad) + (inner - draw_size) * 0.5
	# screen = origin + (world - bounds.position) * fit
	#        = (world * fit) + (origin - bounds.position * fit)
	return Transform2D(Vector2(fit, 0), Vector2(0, fit), origin - bounds.position * fit)


# Map world-XZ points into `rect` (inset by `pad`), preserving aspect ratio and
# centering. Returns empty for fewer than 2 points.
static func fit_points(points: PackedVector2Array, rect: Rect2, pad: float) -> PackedVector2Array:
	if points.size() < 2:
		return PackedVector2Array()
	var xf := fit_transform(bounds_of(points), rect, pad)
	var out := PackedVector2Array()
	for p in points:
		out.append(xf * p)
	return out


# The world-space edge length of one chunk square (TerrainManager.CHUNK_M),
# supplied once by world.gd so LoadingScreen stays decoupled from TerrainManager.
func set_chunk_size(world_m: float) -> void:
	if _preview != null:
		_preview.set_chunk_size(world_m)


# The preview panel's pixel size, so water sampling can match its aspect ratio and
# fill it edge-to-edge. Zero until the panel is laid out.
func preview_size() -> Vector2:
	return _preview.size if _preview != null else Vector2.ZERO


# The growing list of loaded-chunk world-XZ min-corners, drawn as dark squares
# behind the track line during the "Precomputing chunks…" stage.
func update_loaded_chunks(corners: PackedVector2Array) -> void:
	if _preview != null:
		_preview.set_chunks(corners)


# Carve progress in [0, 1]: the fraction of the track line drawn WHITE (carved)
# from the start; the rest stays grey. 0 = all grey (during generation), 1 = all
# white (carving done). Driven by the bake walking the centerline.
func set_carve_progress(fraction: float) -> void:
	if _preview != null:
		_preview.set_carve_progress(fraction)


# The prefix of `mapped` (already screen-space) covering the first `progress`
# fraction of the polyline's length by point index, with an interpolated boundary
# point at the exact fractional split so the white/grey edge advances smoothly.
# Empty for progress <= 0 or < 2 points; the whole line for progress >= 1. Pure.
static func carve_prefix(mapped: PackedVector2Array, progress: float) -> PackedVector2Array:
	if mapped.size() < 2 or progress <= 0.0:
		return PackedVector2Array()
	if progress >= 1.0:
		return mapped
	var n := mapped.size()
	var split_f := progress * float(n - 1)
	var ki := int(floor(split_f))
	var frac := split_f - float(ki)
	var out := PackedVector2Array()
	for i in ki + 1:
		out.append(mapped[i])
	if frac > 0.0 and ki + 1 < n:
		out.append(mapped[ki].lerp(mapped[ki + 1], frac))
	return out


# Below-water cell centres (world XZ) + edge length, drawn behind the track line.
# Fed by world.gd during generation so the author watches the road route around
# the water live (features/lakes.md).
func update_water(cells: PackedVector2Array, cell_size: float, frame := Rect2()) -> void:
	if _preview != null:
		_preview.set_water(cells, cell_size, frame)


# Tear the overlay down once the world is ready.
func finish() -> void:
	queue_free()
