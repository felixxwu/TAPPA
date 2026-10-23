class_name SiteBeacons
extends Node3D
# Docs: features/loot.md, features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_loot.gd — extend in the same change.
# The tall beams of light over every rest stop, fainter the further off they are. The ground
# markers (loot crystals, rest-stop posts and crowds) are TerrainStreamer's and only exist around
# the car; these live for the whole world, and beams stay a few pixels wide however far off they
# are (`_tick` widens them with distance) and fade out as they reach into the sky. Beams ignore
# fog, so a beacon reads through the weather. Created by LootDirector. Loot has no floating name:
# the crystal's colour marks its kind, and the pickup notice says what it was.

const TICK_S := 0.2
const BEAM_SHADER := preload("res://shaders/beacon_beam.gdshader")

var streamer: TerrainStreamer
var loot: LootDirector

var _rest_beams := {}   # site -> Node3D (a beam)
var _t := 0.0


func setup(p_streamer: TerrainStreamer, p_loot: LootDirector) -> void:
	streamer = p_streamer
	loot = p_loot
	for i in streamer.sites.count():
		if streamer.sites.kind[i] == RoadSites.Kind.REST:
			var beam := _beam(Config.data.beacon_rest_height_m, TerrainStreamer.BEACON_UNLIT)
			beam.name = "Rest%d" % i
			add_child(beam)
			beam.position = _ground(i)
			_rest_beams[i] = beam
	_tick()


func _process(delta: float) -> void:
	_t -= delta
	if _t <= 0.0:
		_t = TICK_S
		_tick()


# Colour lit rest stops, and keep every beam a few pixels wide.
func _tick() -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	update_from(cam.global_position if cam != null else Vector3.ZERO)


# Everything _tick does, seen from `eye` (public so a test can stand the viewer anywhere).
func update_from(eye: Vector3) -> void:
	var cfg: GameConfig = Config.data
	var lit: Callable = streamer.rest_lit_query if streamer != null else Callable()
	for i: int in _rest_beams:
		var beam: Node3D = _rest_beams[i]
		_fit(beam, eye, cfg)
		var col := TerrainStreamer.BEACON_LIT if lit.is_valid() and lit.call(i) else TerrainStreamer.BEACON_UNLIT
		set_beam_color(beam, Color(col.r, col.g, col.b, beam_color(beam).a))


# Hide a beam past beacon_range_m, widen it with distance so it stays visible, and fade it from
# beacon_alpha_near up close to beacon_alpha_far at the edge of its range.
func _fit(beam: Node3D, eye: Vector3, cfg: GameConfig) -> void:
	var p := beam.global_position if beam.is_inside_tree() else beam.position
	var d := Vector2(eye.x, eye.z).distance_to(Vector2(p.x, p.z))
	beam.visible = d <= cfg.beacon_range_m
	var w := maxf(1.0, d * cfg.beacon_width_per_m)
	beam.scale = Vector3(w, 1.0, w)
	var c := beam_color(beam)
	c.a = lerpf(cfg.beacon_alpha_near, cfg.beacon_alpha_far, clampf(d / maxf(cfg.beacon_range_m, 1.0), 0.0, 1.0))
	set_beam_color(beam, c)


func _ground(site: int) -> Vector3:
	var c := streamer.sites.pos[site]
	return Vector3(c.x, streamer.sites.pad_h[site], c.y)


# A thin, see-through column of light standing on the ground, fading out towards its top
# (shaders/beacon_beam.gdshader): a pivot at its foot (scaled wider with distance by _fit) holding
# the cylinder, lifted by half its height.
static func _beam(height: float, col: Color) -> Node3D:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.6
	cyl.bottom_radius = 0.6
	cyl.height = height
	cyl.radial_segments = 8
	cyl.rings = 4
	cyl.cap_top = false
	cyl.cap_bottom = false
	var mat := ShaderMaterial.new()
	mat.shader = BEAM_SHADER
	mat.set_shader_parameter("height", height)
	mat.set_shader_parameter("color", Color(col.r, col.g, col.b, Config.data.beacon_alpha_near))
	cyl.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = cyl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position.y = height * 0.5
	var pivot := Node3D.new()
	pivot.add_child(mi)
	return pivot


static func _mat(beam: Node3D) -> ShaderMaterial:
	return ((beam.get_node("Mesh") as MeshInstance3D).mesh as CylinderMesh).material as ShaderMaterial


# A beam's colour (its alpha is the opacity at its foot), and setting it.
static func beam_color(beam: Node3D) -> Color:
	return _mat(beam).get_shader_parameter("color")


static func set_beam_color(beam: Node3D, col: Color) -> void:
	_mat(beam).set_shader_parameter("color", col)

