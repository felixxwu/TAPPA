class_name LevelMap
extends Control
# Docs: features/level-editor.md — update in the same change as this file.
# The level view's full-screen map (M, or the pause menu's Map row): the road network over trees and buildings, pan / zoom, and teleport to one of the save's teleport points.

# The map closed: `teleported` when it closed by teleporting (the game is running again), `over_pause` when the pause menu opened it (open_over_pause) and should take back over.
signal closed(teleported: bool, over_pause: bool)

const IMAGE_PX := 4096
const GROUND := Color(0.80, 0.78, 0.66)
const TREE := Color(0.33, 0.47, 0.28)
const BUILDING := Color(0.45, 0.38, 0.34)
const ROAD := Color(0.93, 0.55, 0.16)
const TARMAC := Color(0.36, 0.37, 0.4)
const PATCH := Color(0.72, 0.66, 0.55)
const LOG_PILE := Color(0.55, 0.36, 0.2)
const TELEPORT := UITheme.GOLD
const COVER_PX := 1024    # the ground cover is sampled this coarsely; it is only a faint wash under the trees
const COVER_TINT := 0.3   # how far the ground leans toward each cover type's colour
const MIN_MARK_PX := 7.0  # log piles never draw smaller than this, so they show when zoomed out
const ROAD_EDGE := Color(0.25, 0.15, 0.08)
const WASD := {KEY_W: Vector2.UP, KEY_A: Vector2.LEFT, KEY_S: Vector2.DOWN, KEY_D: Vector2.RIGHT}
const PAN_SPEED_PX := 600.0
const NAME_GAP_PX := 12.0  # from a teleport's centre to its name
const NAME_PAD_PX := 3.0   # the dark box round a teleport's name
const NAME_BACK := Color(0.0, 0.0, 0.0, 0.6)
const FOG := Color(0.06, 0.058, 0.05)  # the undiscovered ground, near black: GROUND.darkened(0.925), the same as off the level's edge
const BORDER := Color(0.80, 0.78, 0.66, 0.35)  # the faint line round the level's edge, so the world's end shows through the fog
const BORDER_PX := 2.0
const REVEAL_TICK_S := 0.25         # how often the car's position is stamped into the discovery grid
const SEEN_KEY := "level_map_seen"  # the Save setting holding the discovery grid (LevelDiscovery.to_save)

var view: LevelView
var center := Vector2.ZERO  # world x, z at the middle of the screen
var zoom := 1.0             # screen pixels per metre
var _texture: ImageTexture
var _chains: Array[PackedVector2Array] = []  # road lines, split wherever the surface changes
var _tarmac: Array[bool] = []                 # per line in _chains
var _buildings: Array[PackedVector2Array] = []  # each building's footprint corners in world metres
var _hint: Label
var back_button: Button  # top-right "< Back": the way a touch screen (no M, no Esc) closes the map
var _over_pause := false  # opened from the pause menu: closing leaves the game paused for it
var _busy := false
var _pad_used := false  # a gamepad aims with the centre crosshair instead of the mouse
var _drag_from := Vector2.ZERO
var _touches := {}       # finger index -> screen position, for two-finger pinch zoom on a touch screen
var _pinched := false    # this touch gesture pinched, so lifting the fingers doesn't teleport
var _painter: Thread  # paints the map image in the background from load, so the first M opens instantly
var discovery: LevelDiscovery  # where the car has driven: only ground near it is drawn, the rest is under fog
var _fog: CanvasTexture        # discovery's fog, linear filtered so its edge is soft at any zoom
var _fog_dirty := true
var _reveal_clock := 0.0
var _revealed_at := Vector2.INF  # where the car was last stamped; it is only stamped again once it has moved a grid cell


func _init() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	process_mode = PROCESS_MODE_ALWAYS
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	_hint = UITheme.label("Drag: pan   Pinch: zoom   Tap: teleport" if Platform.is_touch() \
		else "Drag / WASD / arrows: pan   Wheel / LB RB: zoom   Click / Enter: teleport   M / Esc: close", "ink")
	_hint.position = Vector2(UITheme.FONT_SIZE, UITheme.FONT_SIZE)
	add_child(_hint)
	back_button = UITheme.row_button(UITheme.caps("< Back"), close)
	back_button.set_anchors_preset(PRESET_TOP_RIGHT)
	back_button.grow_horizontal = GROW_DIRECTION_BEGIN
	back_button.position = Vector2(-UITheme.FONT_SIZE, UITheme.FONT_SIZE)
	add_child(back_button)


func _ready() -> void:
	var cfg: GameConfig = Config.data
	discovery = LevelDiscovery.new(size_m(), cfg.level_map_reveal_cell_m)
	discovery.load_save(Save.get_setting(SEEN_KEY), view._save_path)
	_painter = Thread.new()
	_painter.start(_paint)


func _exit_tree() -> void:
	if _painter != null:
		_painter.wait_to_finish()
		_painter = null


func size_m() -> float:
	return view.data.size


# M / the pad's Back: open from driving, or close. Does nothing over another paused page.
func toggle() -> void:
	if visible:
		close()
	elif not get_tree().paused:
		_open()


# The pause menu's Map row: the game is already paused, and closing hands back to the menu (`closed`).
func open_over_pause() -> void:
	if visible or _busy:
		return
	_over_pause = true
	_open()


func close() -> void:
	if _busy or not visible:
		return
	visible = false
	var over := _over_pause
	_over_pause = false
	get_tree().paused = over  # stays frozen under the pause menu it came from
	closed.emit(false, over)


func _open() -> void:
	if _busy:
		return
	visible = true
	get_tree().paused = true
	_touches.clear()
	if visible:
		build()
		reveal_at_car()
		_update_fog()
		var car := view.get_parent().get_node_or_null("Car") as Node3D
		if car != null:
			center = Vector2(car.global_position.x, car.global_position.z)
		zoom = maxf(zoom, fit_zoom())
		queue_redraw()


func fit_zoom() -> float:
	return minf(size.x, size.y) / size_m()


func to_screen(w: Vector2) -> Vector2:
	return size / 2.0 + (w - center) * zoom


func to_world(s: Vector2) -> Vector2:
	return center + (s - size / 2.0) / zoom


# The save's teleport point (`teleports`: [{x, z}]) nearest a world spot; INF when the save has none.
func nearest_teleport(w: Vector2) -> Vector2:
	var best := Vector2.INF
	for t: Dictionary in view.level.get("teleports", []):
		var p := Vector2(float(t["x"]), float(t["z"]))
		if p.distance_squared_to(w) < best.distance_squared_to(w):
			best = p
	return best


# Screen boxes for the teleports' names (`teleports[i].name`), one per anchor (its diamond's screen spot): right of
# the diamond, else left. A name that would cover one already placed, another diamond or the screen's edge gets an
# empty Rect2 and isn't drawn, so zoomed out the map thins its names rather than piling them up; `first` (the
# aimed-at teleport, or -1) is placed before the rest so its name always shows. A zero width (no name) is skipped.
static func place_names(anchors: PackedVector2Array, widths: PackedFloat32Array, line_h: float, bounds: Rect2, first: int) -> Array[Rect2]:
	var out: Array[Rect2] = []
	out.resize(anchors.size())
	var taken: Array[Rect2] = []
	for a in anchors:
		taken.append(Rect2(a - Vector2(8, 8), Vector2(16, 16)))
	var order := range(anchors.size())
	if first >= 0 and first < anchors.size():
		order.erase(first)
		order.push_front(first)
	for i: int in order:
		if widths[i] <= 0.0:
			continue
		var y := roundf(anchors[i].y - line_h / 2.0)
		for x in [roundf(anchors[i].x + NAME_GAP_PX), roundf(anchors[i].x - NAME_GAP_PX - widths[i])]:
			var r := Rect2(x, y, ceilf(widths[i]), line_h)
			var padded := r.grow(NAME_PAD_PX)
			if not bounds.encloses(padded) or taken.any(func(o: Rect2) -> bool: return o.intersects(padded)):
				continue
			out[i] = r
			taken.append(padded)
			break
	return out


# Uploads the painted image and traces the road lines; the level view calls it behind the loading screen, since the upload alone stalls a frame for tens of ms.
func build() -> void:
	if _texture != null or _painter == null:
		return
	_texture = ImageTexture.create_from_image(_painter.wait_to_finish())  # waits only if the painting isn't done yet
	_painter = null
	var b := view._bake
	var line := PackedVector2Array()
	for i in b.sx.size():
		var paved := b.st[i] >= 0.5
		if i > 0 and b.sc[i] != b.sc[i - 1]:
			_add_line(line, b.st[i - 1] >= 0.5)
			line = PackedVector2Array()
		elif i > 0 and paved != (b.st[i - 1] >= 0.5):
			_add_line(line, not paved)
			line = PackedVector2Array([line[-1]])  # the next line starts where this one ended, so the road has no gap
		line.append(Vector2(b.sx[i], b.sz[i]))
	_add_line(line, b.st.size() > 0 and b.st[-1] >= 0.5)
	for bd: Dictionary in view.level.get("buildings", []):
		_buildings.append(footprint(bd))


func _add_line(line: PackedVector2Array, paved: bool) -> void:
	_chains.append(line)
	_tarmac.append(paved)


# A save's building ({x, z, rot, L, W}) as its four corners in world x, z.
static func footprint(bd: Dictionary) -> PackedVector2Array:
	var rot := float(bd.get("rot", 0.0))
	var ax := Vector2(cos(rot), -sin(rot)) * float(bd.get("L", 8.0)) / 2.0
	var az := Vector2(sin(rot), cos(rot)) * float(bd.get("W", 6.0)) / 2.0
	var c := Vector2(float(bd["x"]), float(bd["z"]))
	return PackedVector2Array([c + ax + az, c + ax - az, c - ax - az, c - ax + az])


func _paint() -> Image:
	var b := view._bake
	var half := size_m() / 2.0
	var k := IMAGE_PX / size_m()
	var img := _cover_image()
	_paint_trees(img, b, half, k)
	return img


# The ground, faintly tinted by the save's ground cover (heather, rush, ...) in each type's own colour.
func _cover_image() -> Image:
	var cov := GroundCover.decode_cover(view.level)
	var grid := roundi(sqrt(cov.size()))
	var img := Image.create(COVER_PX, COVER_PX, false, Image.FORMAT_RGB8)
	img.fill(GROUND)
	if grid > 0:
		var palette := PackedByteArray()
		var tints := GroundCover.tints(view.level.get("coverKinds", {}))
		for id in 256:
			var c := GROUND.lerp(tints.get(id, GROUND), COVER_TINT)
			palette.append_array([c.r8, c.g8, c.b8])
		var px := img.get_data()
		for y in COVER_PX:
			var row := floori((y + 0.5) * grid / COVER_PX) * grid
			for x in COVER_PX:
				var id := cov[row + floori((x + 0.5) * grid / COVER_PX)] * 3
				var i := (y * COVER_PX + x) * 3
				px[i] = palette[id]
				px[i + 1] = palette[id + 1]
				px[i + 2] = palette[id + 2]
		img.set_data(COVER_PX, COVER_PX, false, Image.FORMAT_RGB8, px)
	img.resize(IMAGE_PX, IMAGE_PX, Image.INTERPOLATE_BILINEAR)
	return img


# Each tree as a disc as wide as its canopy, darker in the middle so neighbouring crowns stay apart.
func _paint_trees(img: Image, b: LevelBake, half: float, k: float) -> void:
	var px := img.get_data()
	var edge := PackedByteArray([int(TREE.r8), int(TREE.g8), int(TREE.b8)])
	var dark := TREE.darkened(0.3)
	var core := PackedByteArray([int(dark.r8), int(dark.g8), int(dark.b8)])
	for t in b.tree_count():
		var o := t * 12
		var cx := (b.tree_xf[o + 3] + half) * k
		var cz := (b.tree_xf[o + 11] + half) * k
		var r := maxf(Vector2(b.tree_xf[o], b.tree_xf[o + 8]).length() * 0.5 * k, 0.7)
		var ri := ceili(r)
		for y in range(maxi(int(cz) - ri, 0), mini(int(cz) + ri + 1, IMAGE_PX)):
			for x in range(maxi(int(cx) - ri, 0), mini(int(cx) + ri + 1, IMAGE_PX)):
				var d2 := (x + 0.5 - cx) ** 2 + (y + 0.5 - cz) ** 2
				if d2 <= r * r:
					var c := core if d2 < r * r * 0.25 else edge
					var i := (y * IMAGE_PX + x) * 3
					px[i] = c[0]
					px[i + 1] = c[1]
					px[i + 2] = c[2]
	img.set_data(IMAGE_PX, IMAGE_PX, false, Image.FORMAT_RGB8, px)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), FOG)
	var half := size_m() / 2.0
	draw_texture_rect(_texture, Rect2(to_screen(Vector2(-half, -half)), Vector2.ONE * size_m() * zoom), false)
	draw_set_transform(size / 2.0 - center * zoom, 0.0, Vector2(zoom, zoom))
	for poly in view._bake.patches:
		draw_colored_polygon(poly, PATCH)
	var w := 3.0
	for line in _chains:
		if line.size() > 1:
			draw_polyline(line, ROAD_EDGE, w + 2.0 / zoom)
	for i in _chains.size():
		if _chains[i].size() > 1:
			draw_polyline(_chains[i], TARMAC if _tarmac[i] else ROAD, w)
	draw_set_transform(Vector2.ZERO)
	for fp in _buildings:
		var pts := PackedVector2Array()
		for corner in fp:
			pts.append(to_screen(corner))
		draw_colored_polygon(pts, BUILDING)
		pts.append(pts[0])
		draw_polyline(pts, ROAD_EDGE, 1.0)
	for pile: Dictionary in view.level.get("logPiles", []):
		draw_circle(to_screen(Vector2(float(pile["x"]), float(pile["z"]))), maxf(MIN_MARK_PX, 4.0 * zoom) / 2.0, LOG_PILE)
	if _fog != null:
		draw_texture_rect(_fog, Rect2(to_screen(Vector2(-half, -half)), Vector2.ONE * discovery.cells * discovery.cell_m * zoom), false)
	draw_rect(Rect2(to_screen(Vector2(-half, -half)), Vector2.ONE * size_m() * zoom), BORDER, false, BORDER_PX)
	var aim := get_local_mouse_position() if _mouse_inside() else size / 2.0
	var target := nearest_teleport(to_world(aim))
	var teleports: Array = view.level.get("teleports", [])
	var anchors := PackedVector2Array()
	var widths := PackedFloat32Array()
	var first := -1
	var font := UITheme.font()
	for i in teleports.size():  # drawn over the fog: every teleport works, driven near or not
		var t: Dictionary = teleports[i]
		var wp := Vector2(float(t["x"]), float(t["z"]))
		var tp := to_screen(wp)
		draw_colored_polygon(PackedVector2Array([tp + Vector2(0, -8), tp + Vector2(8, 0), tp + Vector2(0, 8), tp + Vector2(-8, 0)]), TELEPORT)
		anchors.append(tp)
		widths.append(font.get_string_size(String(t.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SIZE).x)
		if wp == target:
			first = i
	var line_h := float(UITheme.FONT_SIZE)
	var rects := place_names(anchors, widths, line_h, Rect2(Vector2.ZERO, size), first)
	for i in rects.size():
		if rects[i].size == Vector2.ZERO:
			continue
		draw_rect(rects[i].grow(NAME_PAD_PX), NAME_BACK)
		var base := (rects[i].position + Vector2(0, roundf((line_h + font.get_ascent(UITheme.FONT_SIZE) - font.get_descent(UITheme.FONT_SIZE)) / 2.0))).round()
		draw_string(font, base, String(teleports[i]["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SIZE, TELEPORT if i == first else UITheme.INK)
	var car := view.get_parent().get_node_or_null("Car") as Node3D
	if car != null:
		var p := to_screen(Vector2(car.global_position.x, car.global_position.z))
		var f := Vector2(-car.global_basis.z.x, -car.global_basis.z.z).normalized() * 12.0
		draw_colored_polygon(PackedVector2Array([p + f, p - f * 0.6 + f.orthogonal() * 0.6, p - f * 0.6 - f.orthogonal() * 0.6]), Color.WHITE)
	if target != Vector2.INF:
		draw_arc(to_screen(target), 12.0, 0.0, TAU, 24, UITheme.INK, 2.0)
	if not _mouse_inside():
		draw_line(size / 2.0 - Vector2(10, 0), size / 2.0 + Vector2(10, 0), UITheme.INK, 2.0)
		draw_line(size / 2.0 - Vector2(0, 10), size / 2.0 + Vector2(0, 10), UITheme.INK, 2.0)


func _mouse_inside() -> bool:
	return Rect2(Vector2.ZERO, size).has_point(get_local_mouse_position()) and Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE and not _pad_used



func zoom_by(f: float, at: Vector2) -> void:
	var w := to_world(at)
	zoom = clampf(zoom * f, fit_zoom() * 0.5, 20.0)
	center = w - (at - size / 2.0) / zoom
	queue_redraw()


func _input(event: InputEvent) -> void:
	var toggle_key: bool = (event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_M) \
		or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_BACK)
	if toggle_key:
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not visible:
		return
	if event is InputEventMouseButton and back_button.get_global_rect().has_point(event.position):
		return  # left for the Back button's own GUI input
	get_viewport().set_input_as_handled()
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_pad_used = true
	elif event is InputEventMouseMotion:
		_pad_used = false
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		touch(event)
	elif event.is_action_pressed("ui_cancel"):
		close()
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: zoom_by(1.2, event.position)
			MOUSE_BUTTON_WHEEL_DOWN: zoom_by(1.0 / 1.2, event.position)
			MOUSE_BUTTON_LEFT:
				_drag_from = event.position
				_pinched = _touches.size() >= 2
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if event.position.distance_to(_drag_from) < 6.0 and not _pinched:
			teleport(nearest_teleport(to_world(event.position)))
	elif event is InputEventPanGesture:  # a Mac trackpad's two-finger scroll
		if _touches.size() < 2:  # a phone's own pinch already zooms through `touch`
			zoom_by(pow(1.1, -event.delta.y), event.position)
	elif event is InputEventMagnifyGesture:
		if _touches.size() < 2:
			zoom_by(event.factor, event.position)
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		if _touches.size() >= 2:
			return  # the first finger's emulated mouse: the pinch pans the map itself

		center -= event.relative / zoom
		queue_redraw()
	elif event is InputEventMouseMotion:
		queue_redraw()
	elif event.is_action_pressed("ui_accept"):
		teleport(nearest_teleport(center))
	elif (event is InputEventKey and event.pressed and event.keycode in [KEY_EQUAL, KEY_KP_ADD]) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_RIGHT_SHOULDER):
		zoom_by(1.5, size / 2.0)
	elif (event is InputEventKey and event.pressed and event.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_LEFT_SHOULDER):
		zoom_by(1.0 / 1.5, size / 2.0)


# Touch screens: one finger pans through the emulated mouse; two fingers pinch to zoom round their midpoint and pan as it moves.
func touch(event: InputEvent) -> void:
	var before := _pinch()
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
	elif _touches.has(event.index):
		_touches[event.index] = event.position
	if _touches.size() >= 2:
		_pinched = true
	var after := _pinch()
	if event is InputEventScreenDrag and before.size() == 2 and after.size() == 2 and before[1] > 0.0:
		center -= (after[0] - before[0]) / zoom
		zoom_by(after[1] / before[1], after[0])


# The first two fingers' midpoint and spread, or [] with fewer than two down.
func _pinch() -> Array:
	if _touches.size() < 2:
		return []
	var keys := _touches.keys()
	keys.sort()
	var a: Vector2 = _touches[keys[0]]
	var b: Vector2 = _touches[keys[1]]
	return [(a + b) / 2.0, a.distance_to(b)]


func _process(delta: float) -> void:
	if _painter != null and not _painter.is_alive():
		build()
	if not visible:
		_reveal_clock += delta
		if _reveal_clock >= REVEAL_TICK_S and not get_tree().paused:
			_reveal_clock = 0.0
			reveal_at_car()
		return
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	for key: Key in WASD:
		if Input.is_physical_key_pressed(key):
			dir += WASD[key]
	dir = dir.limit_length()
	if dir != Vector2.ZERO:
		center += dir * PAN_SPEED_PX * delta / zoom
		queue_redraw()


# Shows the map within level_map_reveal_radius_m of the car.
func reveal_at_car() -> void:
	var car := view.get_parent().get_node_or_null("Car") as Node3D
	if car == null or discovery == null:
		return
	var at := Vector2(car.global_position.x, car.global_position.z)
	if at.distance_to(_revealed_at) < discovery.cell_m:
		return
	_revealed_at = at
	var cfg: GameConfig = Config.data
	if discovery.stamp(at, cfg.level_map_reveal_radius_m, cfg.level_map_reveal_feather_m):
		_fog_dirty = true


# Saves the discovery grid if it has grown since the last save; LevelView calls it with the car's pose.
func save_discovery() -> void:
	if discovery != null and discovery.changed:
		discovery.changed = false
		Save.set_setting(SEEN_KEY, discovery.to_save(view._save_path))


func _update_fog() -> void:
	if not _fog_dirty or discovery == null:
		return
	_fog_dirty = false
	if _fog == null:
		_fog = CanvasTexture.new()
		_fog.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var img := discovery.fog_image(FOG)
	var tex := _fog.diffuse_texture as ImageTexture
	if tex != null and tex.get_size() == Vector2(img.get_size()):
		tex.update(img)
	else:
		_fog.diffuse_texture = ImageTexture.create_from_image(img)


# Puts the car on the road nearest `p`, facing away from any dead end there, loading the ground there before the game resumes so the car doesn't fall through.
func teleport(p: Vector2) -> void:
	var car := view.get_parent().get_node_or_null("Car") as VehicleBody3D
	if car == null or _busy or p == Vector2.INF:
		return
	_busy = true
	visible = false
	var facing := view._bake._roads().away_from_dead_end(p, -car.global_basis.z)
	var pose := view.road_pose(p, facing)
	if view._streamer != null:
		var marker := Node3D.new()
		view.add_child(marker)
		marker.global_position = pose.origin
		view._streamer.focus = marker
		view._streamer.process_mode = PROCESS_MODE_ALWAYS
		await view._streamer.prefill_async()
		view._streamer.process_mode = PROCESS_MODE_INHERIT
		view._streamer.focus = car
		marker.queue_free()
		pose = view.road_pose(p, facing)  # the streamed ground's height
	car.reset_to(pose)
	get_tree().paused = false
	_busy = false
	var over := _over_pause
	_over_pause = false
	closed.emit(true, over)
