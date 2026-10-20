class_name SiteBeacons
extends Node3D
# Docs: features/loot.md, features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_loot.gd — extend in the same change.
# The tall beams of light over every rest stop and every piece of loot, and the floating name over
# each piece of loot ("New car", "New upgrade", …), so they can be found from far away. The ground
# markers (crates, rest-stop posts and crowds) are TerrainStreamer's and only exist around the car;
# these live for the whole world, one beam per site, and stay a few pixels wide however far off
# they are (`_tick` widens them with distance). Beams ignore fog, so a beacon reads through the
# weather. Created by LootDirector, which rebuilds the loot beams when the pool changes.

const TICK_S := 0.2

var streamer: TerrainStreamer
var loot: LootDirector

var _rest_beams := {}   # site -> Node3D (a beam)
var _loot_nodes := {}   # site -> Node3D (beam + label)
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
	refresh_loot()
	_tick()


# Rebuild the loot beams and labels from what the sites show now.
func refresh_loot() -> void:
	for n: Node in _loot_nodes.values():
		n.queue_free()
	_loot_nodes.clear()
	if loot == null:
		return
	for site: int in loot.placement:
		var item: Dictionary = loot.placement[site]
		var root := Node3D.new()
		root.name = "Loot%d" % site
		var beam := _beam(Config.data.beacon_loot_height_m, LootLibrary.colour(item))
		beam.name = "Beam"
		root.add_child(beam)
		root.add_child(_label(LootLibrary.ground_label(item), LootLibrary.colour(item)))
		add_child(root)
		root.position = _ground(site)
		_loot_nodes[site] = root
	_tick()


func _process(delta: float) -> void:
	_t -= delta
	if _t <= 0.0:
		_t = TICK_S
		_tick()


# Show what's in range, colour lit rest stops, and keep every beam a few pixels wide.
func _tick() -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var eye := cam.global_position if cam != null else Vector3.ZERO
	var cfg: GameConfig = Config.data
	var lit: Callable = streamer.rest_lit_query if streamer != null else Callable()
	for i: int in _rest_beams:
		var beam: Node3D = _rest_beams[i]
		_fit(beam, eye, cfg)
		var col := TerrainStreamer.BEACON_LIT if lit.is_valid() and lit.call(i) else TerrainStreamer.BEACON_UNLIT
		var mat := _mat(beam)
		mat.albedo_color = Color(col.r, col.g, col.b, mat.albedo_color.a)
	for site: int in _loot_nodes:
		var root: Node3D = _loot_nodes[site]
		_fit(root.get_node("Beam") as Node3D, eye, cfg)
		var label := root.get_node("Label") as Label3D
		label.visible = Vector2(eye.x, eye.z).distance_to(streamer.sites.pos[site]) <= cfg.beacon_label_range_m


# Hide a beam past beacon_range_m, and widen it with distance so it stays visible.
func _fit(beam: Node3D, eye: Vector3, cfg: GameConfig) -> void:
	var p := beam.global_position if beam.is_inside_tree() else beam.position
	var d := Vector2(eye.x, eye.z).distance_to(Vector2(p.x, p.z))
	beam.visible = d <= cfg.beacon_range_m
	var w := maxf(1.0, d * cfg.beacon_width_per_m)
	beam.scale = Vector3(w, 1.0, w)


func _ground(site: int) -> Vector3:
	var c := streamer.sites.pos[site]
	return Vector3(c.x, streamer.sites.pad_h[site], c.y)


# A thin, see-through column of light standing on the ground: a pivot at its foot (scaled wider
# with distance by _fit) holding the cylinder, lifted by half its height.
static func _beam(height: float, col: Color) -> Node3D:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.6
	cyl.bottom_radius = 0.6
	cyl.height = height
	cyl.radial_segments = 8
	cyl.rings = 1
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(col.r, col.g, col.b, 0.6)
	mat.disable_fog = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	cyl.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = cyl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position.y = height * 0.5
	var pivot := Node3D.new()
	pivot.add_child(mi)
	return pivot


static func _mat(beam: Node3D) -> StandardMaterial3D:
	return ((beam.get_node("Mesh") as MeshInstance3D).mesh as CylinderMesh).material as StandardMaterial3D


# The floating name over a piece of loot: always faces the camera, keeps its size on screen, and
# shows through hills and trees so it can be read from the road.
static func _label(text: String, col: Color) -> Label3D:
	var l := Label3D.new()
	l.name = "Label"
	l.text = text.to_upper()
	l.font = UITheme.font()
	l.font_size = 48
	l.outline_size = 12
	l.modulate = col
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0016
	l.no_depth_test = true
	l.render_priority = 10
	l.position.y = 4.0
	return l
