class_name LevelStreamer
extends TerrainStreamer
# Streams a saved level's ground (baked heights, 1.5 m near mesh, collision) through the free-roam streamer's scheduler, with no island under it.

const SUN := Vector3(-1.0, 1.4, 0.6)
const WALL_THICKNESS_M := 10.0
const WALL_HEIGHT_M := 400.0
const BIOME_CELL := 10.0  # metres per biome mask cell (BIOME_CELL in tools/level_editor_lab.html)
const BIOME_SNOW := 1

var data: LevelData
var bake: LevelBake
var ground_material: Material
var cover: GroundCover
var _cover := PackedByteArray()
var _cover_tints := {}
var _bush_ids := {}
var _biome := PackedByteArray()
var _biome_n := 0
var _sun_dir := SUN.normalized()


static func level_settings() -> FreeRoamSettings:
	var s := FreeRoamSettings.new()
	s.chunk_m = 48.0
	s.near_tile_m = 24.0
	s.near_stride_m = 1.5
	s.mid_stride_m = 6.0
	s.far_stride_m = 12.0
	s.mid_radius = 150.0 / 48.0
	s.far_radius = 11
	s.horizon_radius_m = 3000.0
	return s


func _skirt_uv2(uv2: Vector2) -> Vector2:
	return Vector2(-1.0, uv2.y)


func setup(p_data: LevelData, p_bake: LevelBake, p_material: Material) -> void:
	data = p_data
	bake = p_bake
	ground_material = p_material
	material = p_material
	settings = level_settings()
	_cover = GroundCover.decode_cover(data.level)
	_cover_tints = GroundCover.tints(data.level.get("coverKinds", {}))
	_bush_ids = GroundCover.bush_ids(data.level.get("coverKinds", {}))
	var biome: Variant = data.level.get("biomeRle")
	if biome is String:
		_biome_n = ceili(bake.size / BIOME_CELL)
		_biome = GroundCover.rle_decode(Marshalls.base64_to_raw(biome), _biome_n * _biome_n)
	(p_material as ShaderMaterial).set_shader_parameter("snow_depth_m", Config.data.snow_visual_depth_m)
	(p_material as ShaderMaterial).set_shader_parameter("snow_road_lighten", Config.data.level_snow_road_lighten)
	bake.apply_to(p_material as ShaderMaterial)
	cover = GroundCover.new()
	cover.name = "Cover"
	cover.setup(data.level, height_at, int(bake.size))
	add_child(cover)


# The ground repeats outwards past the square, so an invisible wall at its edge keeps the car in.
func _ready() -> void:
	var half := bake.size * 0.5
	var body := StaticBody3D.new()
	body.name = "EdgeWall"
	for side in 4:
		var dir := Vector2.RIGHT.rotated(side * PI * 0.5)
		var box := BoxShape3D.new()
		box.size = Vector3(WALL_THICKNESS_M, WALL_HEIGHT_M, bake.size + 2.0 * WALL_THICKNESS_M) if side % 2 == 0 \
			else Vector3(bake.size + 2.0 * WALL_THICKNESS_M, WALL_HEIGHT_M, WALL_THICKNESS_M)
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = Vector3(dir.x, 0.0, dir.y) * (half + WALL_THICKNESS_M * 0.5) + Vector3.UP * (WALL_HEIGHT_M * 0.5 - 50.0)
		body.add_child(cs)
	add_child(body)


# The ground first, then every cover tile in reach, so the spawn shows cover from its first frame.
func prefill_async() -> void:
	await super()
	while focus != null and not cover.missing(_focus_xz()).is_empty():
		cover.stream(_focus_xz(), Time.get_ticks_usec() + int(settings.prefill_slice_ms * 1000.0), focus)
		await get_tree().process_frame


# Cover tiles are built from whatever the frame budget has left after the ground queue.
func _process(delta: float) -> void:
	var start := Time.get_ticks_usec()
	super(delta)
	if focus != null:
		cover.stream(_focus_xz(), start + budget_us(delta), focus)


func _ground_material(_job: ChunkJob) -> Material:
	return ground_material


func _after_collide(_job: ChunkJob) -> Stage:
	return Stage.DONE


func _prep_samples(_job: ChunkJob) -> void:
	pass


func _begin_pack(_job: ChunkJob) -> void:
	pass


func _sample(_job: ChunkJob, x: float, z: float, _vi: int) -> float:
	return bake.height(x, z)


func _exact_height(x: float, z: float, _cands := PackedInt32Array(), _with_road := false) -> float:
	return bake.height(x, z)


func surface_at(x: float, z: float) -> Vector2:
	return bake.surface_at(x, z)


func road_pose(p: Vector2, facing: Vector3) -> Transform3D:
	return bake.road_pose(p, facing, height_at)


func spawn_pose() -> Transform3D:
	return bake.spawn_pose(height_at)


# How snowy the ground is at (x, z), from 0 (forest) to 1 (snow), blended between the centres of the save's biome cells.
func snow_at(x: float, z: float) -> float:
	if _biome_n < 2:
		return 0.0
	var fc := clampf((x + bake.size / 2) / BIOME_CELL - 0.5, 0.0, _biome_n - 1.0)
	var fr := clampf((z + bake.size / 2) / BIOME_CELL - 0.5, 0.0, _biome_n - 1.0)
	var c := mini(int(fc), _biome_n - 2)
	var r := mini(int(fr), _biome_n - 2)
	var i := r * _biome_n + c
	var a := float(_biome[i] == BIOME_SNOW)
	var b := float(_biome[i + 1] == BIOME_SNOW)
	var d := float(_biome[i + _biome_n] == BIOME_SNOW)
	var e := float(_biome[i + _biome_n + 1] == BIOME_SNOW)
	return lerpf(lerpf(a, b, fc - c), lerpf(d, e, fc - c), fr - r)


# Sun shading and the cover's ground tint go into COLOR.rgb, the ground's uprightness (normal.y) into COLOR.a for the rock blend, the biome's snow into UV; the road and grass boost are painted per pixel from the bake's textures.
func _pack_vertex(job: ChunkJob, i: int, px: float, pz: float, normal: Vector3) -> void:
	var light := 0.55 + 0.45 * maxf(normal.dot(_sun_dir), 0.0)
	var tint := GroundCover.ground_multiplier(_cover, int(bake.size), _cover_tints, px, pz)
	# UV is (snow, lift): how white the ground is drawn, and how much of the snow depth it is drawn raised off the road.
	var snow := snow_at(px, pz)
	light *= lerpf(GroundCover.bush_shade(_cover, int(bake.size), _bush_ids, px, pz, Config.data.level_ao_bush_ground), 1.0, snow)  # snow covers the bushes' shade
	var lift := 0.0
	if snow > 0.0:
		tint = tint.lerp(Color.WHITE, snow)
		var near := bake.road_nearest(px, pz)
		lift = snow * smoothstep(near.z + 0.5, near.z + 0.5 + Config.data.snow_bank_width_m, near.x)
	job.uvs[i] = Vector2(snow, lift)
	job.colors[i] = Color(light * tint.r, light * tint.g, light * tint.b, normal.y)
