class_name LevelMinimap
extends Control
# Docs: features/level-editor.md — update in the same change as this file.
# The level view's round heading-up minimap, bottom-left: LevelMap's own drawing, tilted ahead of the car and cropped to a circle.
# The drawing is a north-up picture round where the car was, redrawn now and then; the shader scrolls and turns it every frame.

const SHADER := preload("res://shaders/level_minimap.gdshader")
const REACH := 1.1  # the picture spans this many view widths either side of where it was drawn, so the tilted, turned circle stays covered

var view: LevelView
var map: LevelMap
var _vp: SubViewport
var _painter: Painter
var _rect: TextureRect
var _route := PackedVector2Array()
var _route_at := Vector2.INF
var _route_to := ""
var _drawn_at := Vector2.INF
var _xf := Transform2D()
var _mat: ShaderMaterial
var _pic_m := 1.0


func _ready() -> void:
	var cfg: GameConfig = Config.data
	mouse_filter = MOUSE_FILTER_IGNORE
	visible = false
	_vp = SubViewport.new()
	_vp.size = Vector2i(cfg.level_minimap_texture_px, cfg.level_minimap_texture_px)
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	_painter = Painter.new()
	_painter.mini = self
	_vp.add_child(_painter)
	var mat := ShaderMaterial.new()
	_mat = mat
	mat.shader = SHADER
	mat.set_shader_parameter("map_tex", _vp.get_texture())
	mat.set_shader_parameter("near_frac", cfg.level_minimap_tilt)
	mat.set_shader_parameter("fog_color", LevelMap.FOG)
	_rect = TextureRect.new()
	_rect.texture = _vp.get_texture()
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.set_anchors_preset(PRESET_FULL_RECT)
	_rect.mouse_filter = MOUSE_FILTER_IGNORE
	_rect.material = mat
	add_child(_rect)
	var arrow := Arrow.new()
	arrow.mini = self
	arrow.set_anchors_preset(PRESET_FULL_RECT)
	arrow.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(arrow)
	get_tree().process_frame.connect(_tick)  # fires while paused too, so menus hide it


func _tick() -> void:
	if not is_inside_tree():
		return
	visible = view.hud_visible() and map._texture != null
	if not visible:
		return
	place(view.get_parent().get_node_or_null("MobileControls") as MobileControls)
	refresh()


# Bottom-left, lifted with the gauge dial above any touch control either would sit on.
func place(controls: MobileControls) -> void:
	var screen := get_viewport().get_visible_rect().size
	var home := home_rect(screen)
	size = home.size
	position = home.position + Vector2(0.0, MobileControls.bottom_band_lift(controls, screen))


# Where the minimap sits with no touch controls in the way.
static func home_rect(screen: Vector2) -> Rect2:
	var d := roundf(minf(screen.x, screen.y) * Config.data.level_minimap_size_frac)
	var gap := float(UITheme.FONT_SIZE)
	return Rect2(Vector2(gap, screen.y - gap - d), Vector2(d, d))


func refresh() -> void:
	var car := view._car as Node3D
	var cfg: GameConfig = Config.data
	var pos := Vector2(car.global_position.x, car.global_position.z)
	var fwd := Vector2(-car.global_basis.z.x, -car.global_basis.z.z)
	var angle := fwd.angle()
	var m := cfg.level_minimap_tilt
	_mat.set_shader_parameter("car_depth", cfg.level_minimap_car_y / (m + (1.0 - m) * cfg.level_minimap_car_y))  # the picture row that lands on the car's circle row
	_mat.set_shader_parameter("turn", PI / 2.0 + angle)
	_mat.set_shader_parameter("view_m", cfg.level_minimap_view_m)
	var route_changed := _refresh_route(pos)
	if not route_changed and pos.distance_to(_drawn_at) < cfg.level_minimap_redraw_move_m:
		_mat.set_shader_parameter("car_uv", Vector2(0.5, 0.5) + (pos - _drawn_at) / _pic_m)
		return
	_drawn_at = pos
	_pic_m = 2.0 * (REACH * cfg.level_minimap_view_m + cfg.level_minimap_redraw_move_m)
	_mat.set_shader_parameter("pic_m", _pic_m)
	_mat.set_shader_parameter("car_uv", Vector2(0.5, 0.5))
	var px := float(_vp.size.x)
	var zm := px / _pic_m
	_xf = Transform2D(0.0, Vector2(zm, zm), 0.0, Vector2(px, px) * 0.5) * Transform2D().translated(-pos)
	map.reveal_at_car()  # the map's own reveal tick may not have run yet, which left the first picture all fog
	map.update_fog()
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_painter.queue_redraw()


# The delivery's sat-nav line, recomputed only once the car has moved a way or the target changed.
func _refresh_route(pos: Vector2) -> bool:
	var to := LevelView.nav_target()
	if to.is_empty():
		var had := not _route.is_empty()
		_route = PackedVector2Array()
		_route_at = Vector2.INF
		_route_to = ""
		return had
	if to == _route_to and pos.distance_to(_route_at) < Config.data.level_minimap_route_move_m:
		return false
	_route = map._delivery_route(pos)
	_route_at = pos
	_route_to = to
	return true


func _paint(ci: CanvasItem) -> void:
	var px := float(_vp.size.x)
	var ui := px / maxf(size.x, 1.0) * 0.7 * Config.data.level_minimap_view_m / _pic_m  # marks the same size on screen as before the picture grew
	ci.draw_rect(Rect2(Vector2.ZERO, Vector2(px, px)), LevelMap.FOG)
	map.paint(ci, _xf, px / _pic_m, ui, _route)
	map.paint_teleports(ci, _xf, ui)


# The car, fixed where the shader puts it: heading-up, so always pointing straight up.
class Arrow:
	extends Control
	var mini: LevelMinimap

	func _process(_dt: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var p := (size * Vector2(0.5, Config.data.level_minimap_car_y)).round()
		var f := Vector2(0.0, -roundf(size.x * 0.04))
		draw_colored_polygon(PackedVector2Array([p + f, p - f * 0.6 + f.orthogonal() * 0.6, p - f * 0.6 - f.orthogonal() * 0.6]), Color.WHITE)


class Painter:
	extends Node2D
	var mini: LevelMinimap

	func _draw() -> void:
		mini._paint(self)
