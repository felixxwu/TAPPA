extends Node
# SPIKE (throwaway): object-ID outline pass. Renders an ID-coloured twin of every
# mesh into a second SubViewport (layer 20 only); ps1_post_process.gdshader
# edge-detects that texture. Terrain/lakes encode their normal (silhouettes + creases).
# Nothing is built until the Outlines setting is first switched on.

const ID_LAYER := 1 << 19
const ID_SHADER := preload("res://shaders/spike_id_pass.gdshader")
const ID_SHADER_2SIDED := preload("res://shaders/spike_id_pass_2sided.gdshader")

var _view: SubViewport
var _post_mat: ShaderMaterial
var _cam: Camera3D
var _id_view: SubViewport
var _next_id := 1.0
var _fog_density := -1.0
# Source ShaderMaterial -> its id_pass duplicate (foliage keeps its own vertex()).
var _id_mats := {}
# [source, twin] for every twin: sources change mesh and LOD distance band after the
# twin is made (terrain chunk LOD levels, pooled chunk reuse), so twins re-sync per frame.
var _pairs: Array = []

func setup(container: SubViewportContainer, view: SubViewport, cam: Camera3D) -> void:
	_view = view
	_post_mat = container.material
	cam.cull_mask &= ~ID_LAYER
	add_to_group(OutlineSetting.GROUP)
	set_effect_enabled(OutlineSetting.resolve())

func _build() -> void:
	_id_view = SubViewport.new()
	_id_view.own_world_3d = false
	_id_view.msaa_3d = Viewport.MSAA_DISABLED
	add_child(_id_view)
	_cam = Camera3D.new()
	_cam.cull_mask = ID_LAYER
	_cam.current = true
	_id_view.add_child(_cam)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	_cam.environment = env
	_post_mat.set_shader_parameter("id_texture", _id_view.get_texture())

# Idempotent on/off (OutlineSetting.apply). Off stops the ID viewport, the per-frame
# sync and twinning of new nodes; existing twins stay so switching back is cheap.
func set_effect_enabled(on: bool) -> void:
	if on and _id_view == null:
		_build()
	_post_mat.set_shader_parameter("use_id_outline", on)
	set_process(on)
	if _id_view == null:
		return
	_id_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	var tree := get_tree()
	if on and not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
		_scan(tree.root)  # catch anything added while off
	elif not on and tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)

func _on_node_added(n: Node) -> void:
	_twin.call_deferred(n)

func _scan(n: Node) -> void:
	_twin(n)
	for c in n.get_children():
		_scan(c)

func _twin(n) -> void:
	if not is_instance_valid(n) or not n is GeometryInstance3D or n.has_meta("_id_twin"):
		return
	if n is MeshInstance3D:
		if n.skin != null or n.get_parent() is Skeleton3D:
			return
	elif not n is MultiMeshInstance3D or n.multimesh == null:
		return
	if not (n.layers & 1) or n.get_viewport() == _id_view or _under(n, [TireMarks]):
		return
	var terrain := _under(n, [TerrainChunk, DistantTerrain, LakeField, RoadMarkings])
	var twin: GeometryInstance3D = MeshInstance3D.new() if n is MeshInstance3D else MultiMeshInstance3D.new()
	twin.set_meta("_id_twin", true)
	n.set_meta("_id_twin", true)
	if n is MultiMeshInstance3D:
		twin.multimesh = n.multimesh
	twin.layers = ID_LAYER
	twin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat: ShaderMaterial = _id_material_for(n).duplicate()
	mat.set_shader_parameter("object_id", -1.0 if terrain else _next_id)
	twin.material_override = mat
	_next_id += 1.0
	_sync(n, twin)
	_pairs.append([n, twin])
	n.add_child(twin)

# Is n (or an ancestor) one of these classes?
func _under(n: Node, classes: Array) -> bool:
	var p := n
	while p != null:
		for c in classes:
			if is_instance_of(p, c):
				return true
		p = p.get_parent()
	return false

func _source_material(n: GeometryInstance3D) -> Material:
	if n.material_override != null:
		return n.material_override
	if n is MeshInstance3D:
		return n.get_active_material(0) if n.mesh != null and n.mesh.get_surface_count() > 0 else null
	var mm: MultiMesh = n.multimesh
	if mm != null and mm.mesh != null and mm.mesh.get_surface_count() > 0:
		return mm.mesh.surface_get_material(0)
	return null

# Shaders declaring spike_id.gdshaderinc's `id_pass` render their own ID (keeping
# billboard / sway / collapse vertex logic); everything else gets the flat ID shader,
# two-sided only where the source is (drawing back faces of a culled mesh — the car
# body is open round the wheels — paints over whatever sits inside it).
func _id_material_for(n: GeometryInstance3D) -> ShaderMaterial:
	var m := _source_material(n)
	var sh: Shader = m.shader if m is ShaderMaterial else null
	if sh != null and sh.get_shader_uniform_list().any(func(u): return u.name == "id_pass"):
		if not _id_mats.has(m):
			var d: ShaderMaterial = m.duplicate()
			d.set_shader_parameter("id_pass", true)
			_id_mats[m] = d
		return _id_mats[m]
	var two_sided: bool = (m is BaseMaterial3D and m.cull_mode == BaseMaterial3D.CULL_DISABLED) \
		or (sh != null and "cull_disabled" in sh.code)
	var out := ShaderMaterial.new()
	out.shader = ID_SHADER_2SIDED if two_sided else ID_SHADER
	return out

# Mirror what decides WHICH geometry the source draws: its mesh and its LOD band.
# Written only on change — each property write is a RenderingServer call.
func _sync(src: GeometryInstance3D, twin: GeometryInstance3D) -> void:
	if src is MeshInstance3D and twin.mesh != src.mesh:
		twin.mesh = src.mesh
	for prop in [&"visibility_range_begin", &"visibility_range_begin_margin",
			&"visibility_range_end", &"visibility_range_end_margin", &"visibility_range_fade_mode"]:
		var v = src.get(prop)
		if twin.get(prop) != v:
			twin.set(prop, v)

func _process(_delta: float) -> void:
	if _id_view.size != _view.size:
		_id_view.size = _view.size
	# ponytail: per-frame scan of every twin; change hooks if it ever shows in a profile.
	for i in range(_pairs.size() - 1, -1, -1):
		if not is_instance_valid(_pairs[i][0]):
			_pairs.remove_at(i)
			continue
		_sync(_pairs[i][0], _pairs[i][1])
	var env := get_viewport().find_world_3d().environment
	var fog := env.fog_density if env != null and env.fog_enabled else 0.0
	if fog != _fog_density:
		_fog_density = fog
		_post_mat.set_shader_parameter("scene_fog_density", fog)
	PostProcessView.mirror_camera(_cam, get_viewport().get_camera_3d())
