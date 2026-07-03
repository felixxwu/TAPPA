class_name HQEnvironment
extends RefCounted
# The STATIC 3D world of the HQ hub — the geometry the camera flies through but which
# never changes once built: the sky/sun/grass/concrete apron + collision floor, the
# placeholder skyline, the framing tree ring, the garage shell, the painted car-park
# surface, the map table (top + pins root) and the tuning lift. Split out of hq.gd so
# the god object keeps only the state machine / input router / dynamic props (the
# parked-car lineup, the lift car, the map pins), not the one-shot world build.
#
# Everything is parented to the HOST hq node (build(host, ...)), so the scene tree is
# byte-for-byte what hq.gd built inline before — this is a code move, not a re-parenting.
# hq reads the handles below (camera / map_table / map_plane / pins_root) after build().
# The two pickable station areas (table / lift) route their input_event to the callbacks
# hq passes in (its own _on_table_input / _on_lift_input), so picking still lands in hq.

const TREE_MODEL_PATH := "res://models/low_poly_tree.glb"

# Handles hq reads back after build().
var camera: Camera3D
var map_table: MapTable          # the wooden table model the map plane sits on
var map_plane: MeshInstance3D    # the flat map laid on the table top
var pins_root: Node3D            # parent of the rally pins (hq fills it in _refresh_map_pins)


# Build the whole static HQ world as children of `host`, wiring the map-table and lift
# pickable areas to the given click callbacks. Populates the handles above.
func build(host: Node3D, on_table_input: Callable, on_lift_input: Callable) -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	# Same skybox as the run scene (main.tscn) so HQ shares the look. The garage
	# stays lit (directional + ambient below); the sky is just the backdrop.
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = load("res://textures/sky_field.png")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.68)
	e.ambient_light_energy = 1.0
	env.environment = e
	host.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(40.0), 0.0)
	sun.light_energy = 1.1
	host.add_child(sun)

	var cfg: GameConfig = Config.data
	# Grass field covering the whole lot, with the concrete apron (below) laid on top
	# around the garage + car park. The grass uses the same texture as the run scene's
	# terrain, tiled to match (terrain_tile_per_meter), sitting a hair below the apron.
	var grass_size := 240.0
	var grass := MeshInstance3D.new()
	var grass_plane := PlaneMesh.new()
	grass_plane.size = Vector2(grass_size, grass_size)
	grass.mesh = grass_plane
	grass.position.y = -0.02  # just under the concrete so the apron wins where they overlap
	var grass_mat := StandardMaterial3D.new()
	grass_mat.albedo_texture = load("res://textures/grass.jpg")
	grass_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	var tiles := grass_size * cfg.terrain_tile_per_meter
	grass_mat.uv1_scale = Vector3(tiles, tiles, 1.0)
	grass.material_override = grass_mat
	host.add_child(grass)

	# Grey concrete apron around the garage + car park (the player parks / tunes here).
	var concrete := MeshInstance3D.new()
	var concrete_plane := PlaneMesh.new()
	concrete_plane.size = cfg.hq_concrete_size
	concrete.mesh = concrete_plane
	concrete.position = Vector3(cfg.hq_concrete_center.x, 0.0, cfg.hq_concrete_center.z)
	var concrete_mat := StandardMaterial3D.new()
	concrete_mat.albedo_color = Color(0.18, 0.19, 0.22)
	concrete.material_override = concrete_mat
	host.add_child(concrete)

	# Collision floor under the lot so the parked cars settle onto their suspension
	# (the visual ground plane has no collision). A thick box with its top at y = 0.
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(240.0, 2.0, 240.0)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0.0, -1.0, 0.0)  # top face at y = 0
	floor_body.add_child(floor_shape)
	host.add_child(floor_body)

	_build_buildings(host)
	_build_trees(host)
	_build_garage(host)
	_build_carpark(host)
	_build_map_table(host, on_table_input)
	_build_lift(host, on_lift_input)

	camera = Camera3D.new()
	camera.current = true
	host.add_child(camera)


# A solid colour block (BoxMesh, centred at pos). The building/garage/table/lift art
# is deliberately placeholder (todo/diegetic-hq.md defers HQ art); the camera framing
# and the table/lift/car-park positions that the flow depends on live in GameConfig.
func _block(host: Node3D, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	mi.material_override = m
	mi.position = pos
	host.add_child(mi)
	return mi


# Placeholder skyline BEHIND the garage (−Z) — simple blocks of varying height.
# The title camera (hq_exterior_cam_*) sits out at +Z looking back over the car
# park toward the garage, so buildings belong behind the garage (its back wall is
# at z ≈ −6); placing them in front of it would block the shot.
func _build_buildings(host: Node3D) -> void:
	var blocks := [
		[Vector3(-15.0, 6.0, -16.0), Vector3(9.0, 12.0, 9.0), Color(0.26, 0.28, 0.34)],
		[Vector3(-3.0, 8.0, -24.0), Vector3(11.0, 16.0, 10.0), Color(0.24, 0.26, 0.31)],
		[Vector3(12.0, 7.0, -18.0), Vector3(9.0, 14.0, 9.0), Color(0.30, 0.31, 0.36)],
		[Vector3(24.0, 5.0, -13.0), Vector3(8.0, 10.0, 8.0), Color(0.28, 0.29, 0.33)],
		[Vector3(-25.0, 5.0, -14.0), Vector3(8.0, 10.0, 9.0), Color(0.27, 0.28, 0.34)],
		[Vector3(5.0, 5.0, -12.0), Vector3(7.0, 10.0, 7.0), Color(0.29, 0.30, 0.35)],
	]
	for b in blocks:
		_block(host, b[0], b[1], b[2])


# Trees framing the lot so HQ reads as an outdoor clearing under the open-field
# skybox, instead of floating on a bare plane. Reuses the stage's low-poly tree
# mesh field (TreeMeshField); scenery only (no collision). A close-in annulus,
# but with the front-centre corridor kept clear so trees never block the title
# camera's view of the car park, and the garage footprint kept clear so none
# spawn inside it. Trees hug the garage's sides and back.
func _build_trees(host: Node3D) -> void:
	var cfg: GameConfig = Config.data
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240
	var positions := PackedVector2Array()
	var inner := 18.0
	var outer := 66.0
	for _i in 320:
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * (outer - inner) + inner
		var p := Vector2(cos(ang) * rad, sin(ang) * rad)
		# Keep the front-centre clear: the car park sits at +Z (hq_carpark_origin)
		# and the title camera looks down that corridor, so no trees with |x| small
		# and z ahead of the garage. Also skip the garage footprint itself.
		if absf(p.x) < 22.0 and p.y > 8.0:
			continue
		if absf(p.x) < 9.0 and absf(p.y) < 9.0:
			continue
		positions.append(p)
	# HQ ground is a flat plane at y = 0; a layerless TerrainManager returns height
	# 0 everywhere, which is all the field needs to seat the trees. Used only
	# during build(), then freed.
	var flat := TerrainManager.new()
	flat.layers = [] as Array[TerrainLayer]
	var field := TreeMeshField.new()
	host.add_child(field)
	# render_distance 1000 (no cull — HQ is small), no collision (scenery).
	field.build(positions, flat, MeshUtil.first_mesh(load(TREE_MODEL_PATH)), cfg.tree_size_m.y,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m,
		1000.0, 0.0, cfg.tree_bin_size_m, false)
	flat.free()


# The garage shell — the two-bay service-park model (scripts/garage.gd). Open
# toward +Z (the car park) so the camera looks in through the front from the
# garage station; the LEFT bay frames the map table (hq_table_pos, −X) and the
# RIGHT bay frames the tuning lift (hq_lift_pos, +X). The model is sized to the
# hq_garage_size footprint and centred at the origin (front edge at +gz/2, back
# wall at −gz/2), matching the old placeholder so the camera stations and the
# table/lift placement are unchanged. Its own environment + ground are off (the
# HQ provides the sky, sun, grass and concrete apron); it keeps its per-bay
# ceiling lights. The table-map camera (eye y ~2.6) and garage camera both sit
# below the roof (~5.6), so neither looks down through it.
func _build_garage(host: Node3D) -> void:
	var cfg: GameConfig = Config.data
	var gx: float = cfg.hq_garage_size.x
	var gz: float = cfg.hq_garage_size.y
	var garage: Node3D = load("res://scripts/garage.gd").new()
	garage.build_environment = false
	garage.build_ground = false
	garage.num_bays = 2
	garage.bay_depth = gz
	# Two bays + three pillars span the full footprint width.
	garage.bay_width = (gx - 3.0 * garage.pillar_w) / 2.0
	# Model origin is the centre of the FRONT edge; shift it forward by half the
	# depth so the shell straddles the origin like the old placeholder did.
	garage.position = Vector3(0.0, 0.0, gz * 0.5)
	host.add_child(garage)


# --- Car park surface (painted parking bays) ---------------------------------

# Lay a tarmac parking-bay surface in front of the garage: a textured plane over the
# concrete apron with painted white bay dividers, one bay per max_owned_cars slot, so
# each parked car sits in its own marked bay. Centred on the lot (hq_carpark_origin +
# menu_car_park_offset) and sized from the bay width (menu_car_spacing) and depth
# (menu_carpark_bay_depth) so the bay grid lines up exactly with where _build_lineup
# parks the cars. Built once with the HQ; the cars are parked/cleared on top of it.
func _build_carpark(host: Node3D) -> void:
	var cfg: GameConfig = Config.data
	var bays: int = max(1, cfg.max_owned_cars)
	var bw: float = cfg.menu_car_spacing
	var depth: float = cfg.menu_carpark_bay_depth
	var center := carpark_center()
	var surface := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(bays * bw, depth)
	surface.mesh = pm
	# A hair above the concrete apron (y = 0) so the markings win over it without
	# z-fighting; the cars settle onto y = 0, so this sits just under their tyres.
	surface.position = Vector3(center.x, 0.012, center.z)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _carpark_bay_texture(bays)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.roughness = 0.95
	surface.material_override = mat
	host.add_child(surface)


# World centre (XZ) of the car-park lot — the bay row + its painted surface share it.
static func carpark_center() -> Vector3:
	var cfg: GameConfig = Config.data
	return cfg.hq_carpark_origin + Vector3(cfg.menu_car_park_offset, 0.0, 0.0)


# World X of the centre of bay `i` (0 = left / −X), derived from the lot centre, bay
# count and bay width so the cars (_build_lineup) and the painted dividers agree.
static func bay_center_x(i: int, bays: int) -> float:
	var bw: float = Config.data.menu_car_spacing
	return carpark_center().x + (i + 0.5 - bays * 0.5) * bw


# Procedural tarmac-with-bay-markings texture: a dark asphalt field with white bay
# dividers every bay (bays + 1 lines) plus a solid "kerb" line across the back of the
# bays (the edge the nose-out cars back up to). The divider period matches one bay so,
# tiled 1:1 across the surface plane, the lines fall on the bay boundaries.
func _carpark_bay_texture(bays: int) -> ImageTexture:
	var px_per_bay := 96
	var w := bays * px_per_bay
	var h := 200
	var img := Image.create(w, h, true, Image.FORMAT_RGBA8)
	var asphalt := Color(0.15, 0.16, 0.18)
	var paint := Color(0.86, 0.87, 0.84)
	img.fill(asphalt)
	var half := 3  # half line width, px
	# Vertical bay dividers (run front-to-back along the plane's V / world Z).
	for b in range(bays + 1):
		var cx := clampi(b * px_per_bay, half, w - half - 1)
		for x in range(cx - half, cx + half + 1):
			for y in range(h):
				img.set_pixel(x, y, paint)
	# A solid kerb line across the back edge of every bay.
	for y in range(0, half * 2 + 1):
		for x in range(w):
			img.set_pixel(x, y, paint)
	img.generate_mipmaps()  # the lines minify cleanly when the lot is far / oblique
	return ImageTexture.create_from_image(img)


# The map table: a block with the flat 3D map plane on top + a pickable area so a tap
# (in the garage view) drops the camera to the table view.
func _build_map_table(host: Node3D, on_table_input: Callable) -> void:
	var cfg: GameConfig = Config.data
	var p: Vector3 = cfg.hq_table_pos
	var s: Vector3 = cfg.hq_table_size
	# A proper wooden table (top + apron + legs + stretchers) instead of a plain
	# block; its top surface sits at y = s.y so the map plane / pins still align.
	map_table = MapTable.new()
	map_table.table_size = s
	map_table.position = p
	host.add_child(map_table)
	var top_y := p.y + s.y

	map_plane = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = cfg.hq_map_plane_size
	map_plane.mesh = pm
	# Satellite map photo laid over the (now square) table top. Unshaded so the
	# aerial colours read true under the garage lighting from the near-top-down
	# table camera, rather than being darkened by the directional sun's angle.
	map_plane.material_override = PS1Material.unshaded(load("res://textures/map_table.jpg"))
	map_plane.position = Vector3(p.x, top_y + 0.01, p.z)
	host.add_child(map_plane)

	pins_root = Node3D.new()
	host.add_child(pins_root)

	var area := Area3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(s.x, 0.6, s.z)
	cs.shape = box
	area.add_child(cs)
	area.position = Vector3(p.x, top_y, p.z)
	area.input_ray_pickable = true
	area.input_event.connect(on_table_input)
	host.add_child(area)


# The tuning lift: a platform + two posts, with a pickable area. Tapping it (in the
# garage) enters the bay.
func _build_lift(host: Node3D, on_lift_input: Callable) -> void:
	var cfg: GameConfig = Config.data
	var p: Vector3 = cfg.hq_lift_pos
	var s: Vector3 = cfg.hq_lift_size
	var metal := Color(0.40, 0.42, 0.46)
	_block(host, p + Vector3(0.0, s.y * 0.5, 0.0), s, metal)  # platform
	_block(host, p + Vector3(-s.x * 0.5 + 0.2, 1.1, 0.0), Vector3(0.2, 2.2, 0.2), metal)
	_block(host, p + Vector3(s.x * 0.5 - 0.2, 1.1, 0.0), Vector3(0.2, 2.2, 0.2), metal)

	var area := Area3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(s.x, 2.4, s.z)
	cs.shape = box
	area.add_child(cs)
	area.position = p + Vector3(0.0, 1.2, 0.0)
	area.input_ray_pickable = true
	area.input_event.connect(on_lift_input)
	host.add_child(area)
