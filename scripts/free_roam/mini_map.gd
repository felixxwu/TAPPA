class_name MiniMap
extends Control
# Docs: features/minimap.md — update in the same change as this file.
# Tests: tests/headless/test_mini_map.gd — extend in the same change.
# Free roam's minimap, top-centre: heading-up, drawn as a ground plane tilted away from the viewer
# like the roads on navigation software. It shows the roads you've driven (WorldSession.has_driven),
# a little undriven road around and just ahead of the car, and the rest stops you've come
# across (WorldSession.seen_sites). Tapping or clicking it — or M / gamepad Back (`toggle_map`) —
# asks the host for the full map (`open_requested`).
#
# How it draws, cheaply:
#   1. RoadLayer, a Node2D in a small SubViewport, draws the flat map WORLD-ALIGNED around a draw
#      centre (driven roads, nearby faint roads). That command list is only rebuilt when the
#      car has moved `minimap_redraw_move_m` or entered a new driven cell, at most
#      `minimap_redraw_hz` times a second.
#   2. Every frame only the Node2D's transform changes (rotate heading-up, slide under the car),
#      so turning and driving stay smooth at no CPU cost.
#   3. The viewport texture is shown through shaders/mini_map.gdshader, a projective map from the
#      screen to the ground (the tilt), with a soft fade at the far and side edges.
#   4. The car arrow and the site icons are drawn on top, upright (untilted), at the projected
#      positions (`world_to_local`), smaller with distance.

signal open_requested

@export var streamer: TerrainStreamer
@export var car: Node3D
@export var rest_stops: RestStops

const SHADER := preload("res://shaders/mini_map.gdshader")
const BEACON_LIT := Color(1.0, 0.55, 0.1)      # TerrainStreamer.BEACON_LIT
const BEACON_UNLIT := Color(0.45, 0.45, 0.45)  # a checkpoint not yet reached
const CELL_M := 40.0  # road lookup cells match the driven cells (WorldSession.DRIVEN_CELL_M)
const MARKER_REFRESH_S := 1.0
const SHADOW_PX := 3.0

enum Marker { REST_UNLIT, REST_LIT }

var view_m := 460.0
var car_depth := 0.8
var near_frac := 1.0 / 2.7
var nearby_m := 120.0
var redraw_move_m := 12.0
var redraw_interval_s := 1.0 / 15.0
var undriven_alpha := 0.85
var undriven_width := 3.5
var undriven_outline_alpha := 0.45
var car_arrow_px := 4.0

# Heading-up view state: the car's position (world xz) and the rotation that turns its heading up.
var car_xz := Vector2.ZERO
var theta := 0.0

var _vp: SubViewport
var _roads: RoadLayer
var _ground: TextureRect
var _overlay: MarkerLayer
var prompt_label: Label
var _prompt_how := ""
var _prompt_text := ""
var _toast_text := ""
var _toast_left := 0.0
var _mat: ShaderMaterial
var _inner := Rect2(0, 0, 1, 1)
var _cells := {}  # Vector2i (CELL_M cell of the midpoint) -> PackedInt32Array of segment ids
var _draw_centre := Vector2(INF, INF)
var _draw_cell := Vector2i(1 << 30, 0)
var _since_draw := 0.0
var _since_markers := 0.0
var _markers: Array = []  # [Vector2 world xz, Marker]
var _markers_dirty := true
var redraws := 0           # road-layer rebuilds so far (readout for tests and the probe)
var last_redraw_us := 0    # cost of the last rebuild's gathering, in µs


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # so it can hide itself while the tree is paused
	mouse_filter = Control.MOUSE_FILTER_STOP
	var cfg: GameConfig = Config.data
	view_m = cfg.minimap_view_m
	car_depth = cfg.minimap_car_depth
	near_frac = 1.0 / (1.0 + cfg.minimap_tilt)
	nearby_m = cfg.minimap_nearby_road_m
	redraw_move_m = cfg.minimap_redraw_move_m
	redraw_interval_s = 1.0 / maxf(cfg.minimap_redraw_hz, 1.0)
	undriven_alpha = cfg.minimap_undriven_road_alpha
	undriven_width = cfg.minimap_undriven_road_width
	undriven_outline_alpha = cfg.minimap_undriven_road_outline_alpha
	car_arrow_px = cfg.minimap_car_arrow_px
	_vp = SubViewport.new()
	_vp.size = Vector2i(cfg.minimap_texture_px, cfg.minimap_texture_px)
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_PARENT_VISIBLE
	add_child(_vp)
	_roads = RoadLayer.new()
	_roads.map = self
	_vp.add_child(_roads)
	_ground = TextureRect.new()
	_ground.texture = _vp.get_texture()
	_ground.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_ground.stretch_mode = TextureRect.STRETCH_SCALE
	_ground.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("map_tex", _vp.get_texture())
	_mat.set_shader_parameter("near_frac", near_frac)
	# No backdrop, rim or shadow: the roads float over the world, fading out at every edge.
	_mat.set_shader_parameter("bg_color", Color(0.0, 0.0, 0.0, 0.0))
	_mat.set_shader_parameter("rim_color", Color(UITheme.INK, 0.0))
	_mat.set_shader_parameter("shadow_color", Color(0.0, 0.0, 0.0, 0.0))
	_ground.material = _mat
	add_child(_ground)
	_overlay = MarkerLayer.new()
	_overlay.map = self
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	prompt_label = UITheme.label("")
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	prompt_label.add_theme_stylebox_override("normal", UITheme.panel_box(1.0, UITheme.px(4)))
	prompt_label.mouse_filter = Control.MOUSE_FILTER_STOP
	prompt_label.gui_input.connect(_on_prompt_input)
	add_child(prompt_label)
	get_viewport().size_changed.connect(_layout)
	_layout()
	if streamer != null:
		index_roads(streamer.network)


# Size and place the frame: top-centre, clear of the HUD readouts (top-left) and the pause
# button (top-right), and above the touch controls' reach (the top fifth of the screen).
func _layout() -> void:
	if not is_inside_tree():
		return  # a new world reloads the scene; the old map leaves the tree before it is freed
	var cfg: GameConfig = Config.data
	var vs := get_viewport().get_visible_rect().size
	var h := vs.y * cfg.minimap_height_frac
	var side_clear := 140.0  # HUD speed/gear labels end at x = 128; pause button is 48 wide
	var w := minf(h * cfg.minimap_aspect, maxf(vs.x - 2.0 * side_clear, h))
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2((vs.x - w) * 0.5, cfg.minimap_top_px)
	size = Vector2(w, h)
	set_frame_size(size)


# The ground frame inside the rect (the rest is the hard shadow's room) and the shader's copy.
func set_frame_size(s: Vector2) -> void:
	_inner = Rect2(Vector2.ZERO, s - Vector2(SHADOW_PX, SHADOW_PX))
	if _mat != null:
		_mat.set_shader_parameter("inner", Vector4(0.0, 0.0, _inner.size.x / s.x, _inner.size.y / s.y))
		_mat.set_shader_parameter("shadow_uv", Vector2(SHADOW_PX / s.x, SHADOW_PX / s.y))
	if prompt_label != null:
		_place_prompt_label()


# --- the projection (the GDScript twin of mini_map.gdshader's `ground`) -------------------------

# Ground (map texture UV, the car at (0.5, car_depth), up = ahead) to a point in this control.
func screen_of(g: Vector2) -> Vector2:
	var m := near_frac
	var yf := g.y * m / maxf(1.0 - g.y * (1.0 - m), 1e-6)
	var den := m + (1.0 - m) * yf
	var xf := 0.5 + (g.x - 0.5) * den
	return _inner.position + Vector2(xf, yf) * _inner.size


# How big the ground looks at texture row `t` (1 at the near edge, near_frac at the far edge).
func depth_scale(t: float) -> float:
	var m := near_frac
	var yf := t * m / maxf(1.0 - t * (1.0 - m), 1e-6)
	return m + (1.0 - m) * yf


# A world point (xz) as map texture UV, heading-up around the car.
func ground_of(world_xz: Vector2) -> Vector2:
	var r := (world_xz - car_xz).rotated(theta) / view_m
	return Vector2(0.5, car_depth) + r


func world_to_local(world_xz: Vector2) -> Vector2:
	return screen_of(ground_of(world_xz))


# Point the view: the car at `xz`, heading `fwd` (world xz, the car's -Z) turned to screen-up.
func set_view(xz: Vector2, fwd: Vector2) -> void:
	car_xz = xz
	if fwd.length_squared() > 1e-6:
		theta = -PI * 0.5 - fwd.angle()


func _gui_input(event: InputEvent) -> void:
	var tap: bool = (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) \
		or (event is InputEventScreenTouch and event.pressed)
	if tap and is_live() and Config.data.minimap_enabled:
		accept_event()
		open_requested.emit()


func _on_prompt_input(event: InputEvent) -> void:
	var tap: bool = (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) \
		or (event is InputEventScreenTouch and event.pressed)
	if tap and is_live() and prompt_label.visible and rest_stops != null and rest_stops.open_here():
		prompt_label.accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if is_live() and event.is_action_pressed("toggle_map") and not event.is_echo():
		get_viewport().set_input_as_handled()
		open_requested.emit()


# Showing and taking input: never while the tree is paused (a menu, the rest-stop page, the
# world pages — every free-roam overlay pauses), nor with the HUD switched off.
func is_live() -> bool:
	return Config.data.hud_enabled and not get_tree().paused


# --- roads -------------------------------------------------------------------------------------

# Bucket every road segment by the driven cell its midpoint is in, once. A cell is then driven or
# not as a whole, so a redraw makes one has_driven lookup per cell, not per segment.
func index_roads(net: RoadNetwork) -> void:
	_cells.clear()
	for si in net.seg_ax.size():
		var c := Vector2i(floori((net.seg_ax[si] + net.seg_bx[si]) * 0.5 / CELL_M),
			floori((net.seg_ay[si] + net.seg_by[si]) * 0.5 / CELL_M))
		var arr: PackedInt32Array = _cells.get(c, PackedInt32Array())
		arr.append(si)
		_cells[c] = arr


# Rebuild the road layer around the car now.
func redraw() -> void:
	_draw_centre = car_xz
	_draw_cell = Vector2i(floori(car_xz.x / CELL_M), floori(car_xz.y / CELL_M))
	_since_draw = 0.0
	redraws += 1
	_roads.queue_redraw()
	refresh_markers()


func refresh_markers() -> void:
	_markers_dirty = true


# Everything a redraw needs within `radius` of the draw centre: driven segments, and undriven ones
# near a point a little ahead of the car. Returns [driven PackedVector2Array, faint ...] as
# segment end pairs relative to the draw centre, in metres.
func gather_roads(radius: float) -> Array:
	var t0 := Time.get_ticks_usec()
	var driven := PackedVector2Array()
	var faint := PackedVector2Array()
	if streamer == null:
		return [driven, faint]
	var net := streamer.network
	var c := _draw_centre
	var ahead := car_xz + Vector2(0.0, -1.0).rotated(-theta) * nearby_m * 0.4
	var near2 := nearby_m * nearby_m
	var r2 := radius * radius
	var cx0 := floori((c.x - radius) / CELL_M)
	var cx1 := floori((c.x + radius) / CELL_M)
	var cy0 := floori((c.y - radius) / CELL_M)
	var cy1 := floori((c.y + radius) / CELL_M)
	for cx in range(cx0, cx1 + 1):
		for cy in range(cy0, cy1 + 1):
			var cell: Variant = _cells.get(Vector2i(cx, cy))
			if cell == null:
				continue
			var mid := Vector2((cx + 0.5) * CELL_M, (cy + 0.5) * CELL_M)
			if mid.distance_squared_to(c) > r2 + CELL_M * CELL_M * 2.0:
				continue
			var was_driven := WorldSession.has_driven(mid.x, mid.y)
			for si in cell as PackedInt32Array:
				var a := Vector2(net.seg_ax[si], net.seg_ay[si])
				var b := Vector2(net.seg_bx[si], net.seg_by[si])
				if was_driven:
					driven.append(a - c)
					driven.append(b - c)
				elif ((a + b) * 0.5).distance_squared_to(ahead) < near2:
					faint.append(a - c)
					faint.append(b - c)
	last_redraw_us = Time.get_ticks_usec() - t0
	return [driven, faint]


# --- sites -------------------------------------------------------------------------------------

# Mark every site (rest stop, loot slot, dead end) within `radius` of `p` as seen. Returns how many were new.
static func mark_seen_near(sites: RoadSites, p: Vector2, radius: float) -> int:
	var fresh := 0
	var r2 := radius * radius
	for i in sites.in_box(p.x - radius, p.y - radius, p.x + radius, p.y + radius):
		if sites.pos[i].distance_squared_to(p) <= r2 and WorldSession.see(i):
			fresh += 1
	return fresh


# Which sites a map shows: the rest stops seen (or lit), lit or not. `lit` is RestStops.lit_sites
# (site -> true).
static func site_markers(sites: RoadSites, lit: Dictionary, centre: Vector2, radius: float) -> Array:
	var out: Array = []
	var seen := {}
	for s: int in WorldSession.seen_sites():
		seen[s] = true
	var r2 := radius * radius
	for i in sites.count():
		var k := sites.kind[i]
		if k != RoadSites.Kind.REST or sites.pos[i].distance_squared_to(centre) > r2:
			continue
		var is_lit := k == RoadSites.Kind.REST and lit.has(i)
		if not (seen.has(i) or is_lit):
			continue
		out.append([sites.pos[i], Marker.REST_LIT if is_lit else Marker.REST_UNLIT, i])
	return out


static func marker_color(m: int) -> Color:
	match m:
		Marker.REST_LIT:
			return BEACON_LIT
	return BEACON_UNLIT


# --- per frame ---------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_toast_left = maxf(_toast_left - delta, 0.0)
	visible = is_live()
	if not visible or car == null:
		return
	update_prompt_label()
	# With the minimap off only the prompt line shows; M / Back still open the full map.
	_ground.visible = Config.data.minimap_enabled
	_overlay.visible = Config.data.minimap_enabled
	mouse_filter = Control.MOUSE_FILTER_STOP if Config.data.minimap_enabled else Control.MOUSE_FILTER_IGNORE
	# Hiding the map's sprites alone leaves the viewport drawing it every frame.
	_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_PARENT_VISIBLE if Config.data.minimap_enabled \
		else SubViewport.UPDATE_DISABLED
	if not Config.data.minimap_enabled:
		return
	var f := -car.global_transform.basis.z
	set_view(Vector2(car.global_position.x, car.global_position.z), Vector2(f.x, f.z))
	_since_draw += delta
	_since_markers += delta
	var cell := Vector2i(floori(car_xz.x / CELL_M), floori(car_xz.y / CELL_M))
	if _since_draw >= redraw_interval_s and (car_xz.distance_to(_draw_centre) >= redraw_move_m or cell != _draw_cell):
		redraw()
	if _markers_dirty or _since_markers >= MARKER_REFRESH_S:
		_markers_dirty = false
		_since_markers = 0.0
		if streamer != null:
			_markers = site_markers(streamer.sites, rest_stops.lit_sites if rest_stops != null else {},
				car_xz, view_m)
	# Slide and turn the flat map under the car: screen = anchor + R(θ)·(p − car).
	var k := float(_vp.size.x) / view_m
	var anchor := Vector2(0.5, car_depth) * float(_vp.size.x)
	_roads.rotation = theta
	_roads.position = anchor + ((_draw_centre - car_xz) * k).rotated(theta)
	_overlay.queue_redraw()


# The line under the frame: the rest-stop prompt when there is one, else the latest money message
# (`toast`) while it lasts — one box, so the two never show at once.
func update_prompt_label() -> void:
	var at_stop := rest_stops != null and rest_stops.can_open()
	var how := "Tap" if Platform.is_touch() else "Enter / A"
	if how != _prompt_how:
		_prompt_how = how
		_prompt_text = UITheme.caps(how + ": open rest stop")
	var text := _prompt_text if at_stop else (_toast_text if _toast_left > 0.0 else "")
	prompt_label.visible = text != ""
	if text != prompt_label.text:
		prompt_label.text = text
		_place_prompt_label()


func toast(text: String, seconds: float) -> void:
	_toast_text = text
	_toast_left = seconds


# Hug the text and centre it under the frame, on whole pixels.
func _place_prompt_label() -> void:
	prompt_label.size = Vector2.ZERO
	prompt_label.position = Vector2(roundf((size.x - prompt_label.size.x) * 0.5), size.y)


# Which way the outer rings lie on screen: from the car, straight away from spawn (the world
# origin), as a unit vector in this control. Zero right at spawn, where every way is out.
func outward_dir() -> Vector2:
	if car_xz.length() < 1.0:
		return Vector2.ZERO
	return (world_to_local(car_xz + car_xz.normalized() * 50.0) - world_to_local(car_xz)).normalized()


func draw_radius() -> float:
	return view_m * 0.95 + redraw_move_m


# The flat map, world-aligned around the draw centre, in texture pixels.
class RoadLayer:
	extends Node2D
	var map: MiniMap

	func _draw() -> void:
		if not is_finite(map._draw_centre.x):
			return
		var k := float(map._vp.size.x) / map.view_m
		var radius := map.draw_radius()
		var roads := map.gather_roads(radius)
		var driven: PackedVector2Array = roads[0]
		var faint: PackedVector2Array = roads[1]
		for i in driven.size():
			driven[i] = driven[i] * k
		for i in faint.size():
			faint[i] = faint[i] * k
		if not faint.is_empty():
			if map.undriven_outline_alpha > 0.0:
				draw_multiline(faint, Color(0.0, 0.0, 0.0, map.undriven_outline_alpha),
					map.undriven_width + 2.5)
			draw_multiline(faint, Color(UITheme.INK, map.undriven_alpha), map.undriven_width)
		if not driven.is_empty():
			draw_multiline(driven, Color(0.0, 0.0, 0.0, 0.85), 8.0)
			draw_multiline(driven, UITheme.INK, 4.5)


# The upright layer on top of the tilted ground: site icons and the car.
class MarkerLayer:
	extends Control
	var map: MiniMap

	func _draw() -> void:
		for mk: Array in map._markers:
			var g := map.ground_of(mk[0])
			if g.x < 0.03 or g.x > 0.97 or g.y < 0.04 or g.y > 0.97:
				continue
			var s := clampf(map.depth_scale(g.y), 0.55, 1.0) * UITheme.UI_SCALE
			var fade := clampf(g.y / 0.3, 0.0, 1.0)
			var p := map.screen_of(g)
			var col := MiniMap.marker_color(mk[1])
			col.a *= fade
			var ink := Color(0.0, 0.0, 0.0, 0.9 * fade)
			var r := 3.8 * s
			draw_circle(p + Vector2(1.5, 1.5), r + 1.0, ink)
			draw_circle(p, r + 1.0, ink)
			draw_circle(p, r, col)
		# The car: a chevron pointing up (where the car points), near the bottom middle.
		var cp := map.screen_of(Vector2(0.5, map.car_depth))
		var a := map.car_arrow_px * UITheme.UI_SCALE
		var arrow := PackedVector2Array([cp + Vector2(0, -a), cp + Vector2(a * 0.75, a * 0.7),
			cp + Vector2(0, a * 0.3), cp + Vector2(-a * 0.75, a * 0.7)])
		var shadow := PackedVector2Array()
		for q in arrow:
			shadow.append(q + Vector2(2, 2))
		draw_colored_polygon(shadow, Color(0, 0, 0, 0.9))
		draw_colored_polygon(arrow, UITheme.GREEN)
		arrow.append(arrow[0])
		draw_polyline(arrow, Color.BLACK, 1.0)
		# A small arrow circling the car, pointing out toward the outer rings.
		var d := map.outward_dir()
		if d != Vector2.ZERO:
			var tip := cp + d * a * 3.2
			var side := d.orthogonal() * a * 0.55
			var out := PackedVector2Array([tip, tip - d * a + side, tip - d * a - side])
			var out_shadow := PackedVector2Array()
			for q in out:
				out_shadow.append(q + Vector2(2, 2))
			draw_colored_polygon(out_shadow, Color(0, 0, 0, 0.9))
			draw_colored_polygon(out, BEACON_LIT)
