class_name LevelMap
extends Control
# Docs: features/level-editor.md — update in the same change as this file.
# The level view's full-screen map (M): the road network over trees and buildings, pan / zoom, and teleport to a road.

const IMAGE_PX := 4096
const GROUND := Color(0.80, 0.78, 0.66)
const TREE := Color(0.33, 0.47, 0.28)
const BUILDING := Color(0.45, 0.38, 0.34)
const ROAD := Color(0.93, 0.55, 0.16)
const ROAD_EDGE := Color(0.25, 0.15, 0.08)
const WASD := {KEY_W: Vector2.UP, KEY_A: Vector2.LEFT, KEY_S: Vector2.DOWN, KEY_D: Vector2.RIGHT}
const PAN_SPEED_PX := 600.0

var view: LevelView
var center := Vector2.ZERO  # world x, z at the middle of the screen
var zoom := 1.0             # screen pixels per metre
var _texture: ImageTexture
var _chains: Array[PackedVector2Array] = []
var _hint: Label
var _busy := false
var _pad_used := false  # a gamepad aims with the centre crosshair instead of the mouse
var _drag_from := Vector2.ZERO
var _painter: Thread  # paints the map image in the background from load, so the first M opens instantly


func _init() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	process_mode = PROCESS_MODE_ALWAYS
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	_hint = UITheme.label("Drag / WASD / arrows: pan   Wheel / LB RB: zoom   Click / Enter: teleport   M: close", "ink")
	_hint.position = Vector2(UITheme.FONT_SIZE, UITheme.FONT_SIZE)
	add_child(_hint)


func _ready() -> void:
	_painter = Thread.new()
	_painter.start(_paint)


func _exit_tree() -> void:
	if _painter != null:
		_painter.wait_to_finish()
		_painter = null


func size_m() -> float:
	return view.data.size


func toggle() -> void:
	if _busy or (not visible and get_tree().paused):
		return
	visible = not visible
	get_tree().paused = visible
	if visible:
		_build()
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


# The road point nearest a world spot.
func snap_to_road(w: Vector2) -> Vector2:
	var b := view._bake
	var i := b.nearest_sample(w.x, w.y)
	return Vector2(b.sx[i], b.sz[i]) if i >= 0 else w


func _build() -> void:
	if _texture != null:
		return
	_texture = ImageTexture.create_from_image(_painter.wait_to_finish())  # waits only if the painting isn't done yet
	_painter = null
	var b := view._bake
	var line := PackedVector2Array()
	for i in b.sx.size():
		if i > 0 and b.sc[i] != b.sc[i - 1]:
			_chains.append(line)
			line = PackedVector2Array()
		line.append(Vector2(b.sx[i], b.sz[i]))
	_chains.append(line)


func _paint() -> Image:
	var b := view._bake
	var half := size_m() / 2.0
	var k := IMAGE_PX / size_m()
	var img := Image.create(IMAGE_PX, IMAGE_PX, false, Image.FORMAT_RGB8)
	img.fill(GROUND)
	_paint_trees(img, b, half, k)
	for bd: Dictionary in view.level.get("buildings", []):
		var rot := float(bd.get("rot", 0.0))
		var ax := Vector2(cos(rot), -sin(rot)) * float(bd.get("L", 8.0)) / 2.0
		var az := Vector2(sin(rot), cos(rot)) * float(bd.get("W", 6.0)) / 2.0
		var c := Vector2(float(bd["x"]), float(bd["z"]))
		var r := ceili((ax.length() + az.length()) * k)
		var cp := (c + Vector2(half, half)) * k
		for y in range(-r, r + 1):
			for x in range(-r, r + 1):
				var w := c + Vector2(x, y) / k
				var d := w - c
				if absf(d.dot(ax.normalized())) <= ax.length() and absf(d.dot(az.normalized())) <= az.length():
					var p := Vector2i(cp) + Vector2i(x, y)
					if p.x >= 0 and p.y >= 0 and p.x < IMAGE_PX and p.y < IMAGE_PX:
						img.set_pixelv(p, BUILDING)
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
	draw_rect(Rect2(Vector2.ZERO, size), GROUND.darkened(0.5))
	var half := size_m() / 2.0
	draw_texture_rect(_texture, Rect2(to_screen(Vector2(-half, -half)), Vector2.ONE * size_m() * zoom), false)
	draw_set_transform(size / 2.0 - center * zoom, 0.0, Vector2(zoom, zoom))
	var w := maxf(5.0, 3.0 * zoom) / zoom  # roads stay readable when zoomed out, true width when zoomed in
	for line in _chains:
		if line.size() > 1:
			draw_polyline(line, ROAD_EDGE, w + 2.0 / zoom)
	for line in _chains:
		if line.size() > 1:
			draw_polyline(line, ROAD, w)
	draw_set_transform(Vector2.ZERO)
	var car := view.get_parent().get_node_or_null("Car") as Node3D
	if car != null:
		var p := to_screen(Vector2(car.global_position.x, car.global_position.z))
		var f := Vector2(-car.global_basis.z.x, -car.global_basis.z.z).normalized() * 12.0
		draw_colored_polygon(PackedVector2Array([p + f, p - f * 0.6 + f.orthogonal() * 0.6, p - f * 0.6 - f.orthogonal() * 0.6]), UITheme.RED)
	var aim := get_local_mouse_position() if _mouse_inside() else size / 2.0
	draw_arc(to_screen(snap_to_road(to_world(aim))), 8.0, 0.0, TAU, 24, UITheme.INK, 2.0)
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
	get_viewport().set_input_as_handled()
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_pad_used = true
	elif event is InputEventMouseMotion:
		_pad_used = false
	if event.is_action_pressed("ui_cancel"):
		toggle()
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: zoom_by(1.2, event.position)
			MOUSE_BUTTON_WHEEL_DOWN: zoom_by(1.0 / 1.2, event.position)
			MOUSE_BUTTON_LEFT: _drag_from = event.position
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if event.position.distance_to(_drag_from) < 6.0:
			teleport(snap_to_road(to_world(event.position)))
	elif event is InputEventPanGesture:  # a Mac trackpad's two-finger scroll
		zoom_by(pow(1.1, -event.delta.y), event.position)
	elif event is InputEventMagnifyGesture:
		zoom_by(event.factor, event.position)
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		center -= event.relative / zoom
		queue_redraw()
	elif event is InputEventMouseMotion:
		queue_redraw()
	elif event.is_action_pressed("ui_accept"):
		teleport(snap_to_road(center))
	elif (event is InputEventKey and event.pressed and event.keycode in [KEY_EQUAL, KEY_KP_ADD]) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_RIGHT_SHOULDER):
		zoom_by(1.5, size / 2.0)
	elif (event is InputEventKey and event.pressed and event.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_LEFT_SHOULDER):
		zoom_by(1.0 / 1.5, size / 2.0)



func _process(delta: float) -> void:
	if _painter != null and not _painter.is_alive():
		_build()
	if not visible:
		return
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	for key: Key in WASD:
		if Input.is_physical_key_pressed(key):
			dir += WASD[key]
	dir = dir.limit_length()
	if dir != Vector2.ZERO:
		center += dir * PAN_SPEED_PX * delta / zoom
		queue_redraw()


# Puts the car on the road at `p`, loading the ground there before the game resumes so the car doesn't fall through.
func teleport(p: Vector2) -> void:
	var car := view.get_parent().get_node_or_null("Car") as VehicleBody3D
	if car == null or _busy:
		return
	_busy = true
	visible = false
	var pose := view.road_pose(p, -car.global_basis.z)
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
		pose = view.road_pose(p, -car.global_basis.z)  # the streamed ground's height
	car.reset_to(pose)
	get_tree().paused = false
	_busy = false
