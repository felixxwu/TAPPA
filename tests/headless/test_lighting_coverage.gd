extends GutTest
# Everything drawn in the world must react to the fake headlight cone (features/weather.md).
# The cone is not a real light: each shader adds it itself through
# shaders/headlight_cone.gdshaderinc, so a new shader or material that forgets it simply stays
# dark in the beams at night. This guard makes forgetting it a failing test. Anything that
# genuinely should not be lit, or is re-shaded by code at runtime, goes in EXEMPT with its reason; KNOWN_GAPS lists what is unlit
# today and should be fixed (empty it as they are), never grown.

const HEADLIGHT_INCLUDE := "res://shaders/headlight_cone.gdshaderinc"

const EXEMPT := {
	"res://shaders/car_lamp.gdshader": "the lamp flare is a light source itself",
	"res://shaders/spike_id_pass.gdshader": "debug id pass, never seen by the player",
	"res://shaders/spike_id_pass_2sided.gdshader": "debug id pass, never seen by the player",
	"res://scripts/exhaust_flames.gd": "flames glow on their own",
	"res://scripts/exhaust_lab.gd": "standalone dev scene",
	"res://scripts/chunk_border_debug.gd": "debug overlay",
	"res://scripts/wheel_force_debug.gd": "debug overlay",
	"res://models/rocks/rock_largeA.glb": "foliage.gd draws rocks with ps1_models_lit",
	"res://models/rocks/rock_largeD.glb": "foliage.gd draws rocks with ps1_models_lit",
	"res://models/rocks/rock_smallA.glb": "foliage.gd draws rocks with ps1_models_lit",
	"res://models/vegetation/groundcover_opaque.glb": "foliage.gd draws it with tree_canopy",
	"res://blender/911/911.glb": "car.gd puts car bodies on ps1_models_lit",
	"res://blender/acty/acty.glb": "car.gd puts car bodies on ps1_models_lit",
	"res://blender/charger/charger.glb": "car.gd puts car bodies on ps1_models_lit",
	"res://blender/focus/focus.glb": "car.gd puts car bodies on ps1_models_lit",
	"res://blender/mx5/mx5.glb": "car.gd puts car bodies on ps1_models_lit",
	"res://blender/thebeast/mrbeast.glb": "car.gd puts car bodies on ps1_models_lit",
	"res://blender/viper/viper.glb": "car.gd puts car bodies on ps1_models_lit",
	"res://blender/xjs/xjs.glb": "car.gd puts car bodies on ps1_models_lit",
}

const KNOWN_GAPS := [
	"res://shaders/billboard_particle.gdshader",
	"res://scripts/rain_field.gd",
	"res://scripts/engine_smoke.gd",
	"res://scripts/tire_marks.gd",
	"res://scripts/road_markings.gd",
	"res://scripts/free_roam/terrain_streamer.gd",
	"res://blender/twingo/twingo.glb",  # car.gd re-shades the body, but its *_aero parts keep the imported material
	"res://free_roam.tscn",  # the Water mesh's StandardMaterial3D
	"res://models/cabin/log_cabin.glb",
	"res://blender/spectator/spectator.glb",
]

# Folders whose scenes and models never reach the game's world.
const SKIP_DIRS := ["res://addons", "res://tests", "res://build", "res://tools", "res://.godot", "res://blender_src"]

# Ways a script builds a material outside the shared lit shaders.
const PLAIN_MATERIAL_CALLS := ["StandardMaterial3D.new()", "ORMMaterial3D.new()", "PS1Material.unshaded("]


func _files(dir: String, ext: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(ext):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		var sub := dir.path_join(d)
		if not SKIP_DIRS.has(sub) and not d.begins_with("."):
			out.append_array(_files(sub, ext))
	return out


# True when `path` reaches the headlight include, directly or through another include.
func _reaches_headlights(path: String, seen := {}) -> bool:
	if path == HEADLIGHT_INCLUDE:
		return true
	if seen.has(path):
		return false
	seen[path] = true
	var rx := RegEx.create_from_string("#include\\s+\"([^\"]+)\"")
	for m in rx.search_all(FileAccess.get_file_as_string(path)):
		if _reaches_headlights(m.get_string(1), seen):
			return true
	return false


func _is_world_shader(path: String) -> bool:
	return FileAccess.get_file_as_string(path).contains("shader_type spatial")


# A drawn material is fine when its shader takes the cone, or is a shader the lists already cover.
func _material_ok(mat: Material) -> bool:
	if not (mat is ShaderMaterial) or (mat as ShaderMaterial).shader == null:
		return false
	var path := (mat as ShaderMaterial).shader.resource_path
	if path.ends_with(".gdshader"):
		return _reaches_headlights(path) or EXEMPT.has(path) or KNOWN_GAPS.has(path)
	return false


func _node_unlit(n: Node) -> bool:
	if n is GeometryInstance3D and (n as GeometryInstance3D).material_override != null:
		return not _material_ok((n as GeometryInstance3D).material_override)
	var mesh: Mesh = null
	if n is MeshInstance3D:
		mesh = (n as MeshInstance3D).mesh
	elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
		mesh = (n as MultiMeshInstance3D).multimesh.mesh
	if mesh == null:
		return false
	for i in mesh.get_surface_count():
		var mat: Material = mesh.surface_get_material(i)
		if n is MeshInstance3D and (n as MeshInstance3D).get_surface_override_material(i) != null:
			mat = (n as MeshInstance3D).get_surface_override_material(i)
		if not _material_ok(mat):
			return true
	return false


# Scene and model files (.tscn, .glb) with a mesh drawn by a material that ignores the cone.
# Instanced but never added to the tree, so no _ready runs and no world is generated.
func _unlit_scenes() -> PackedStringArray:
	var out := PackedStringArray()
	var paths := _files("res://", ".tscn")
	paths.append_array(_files("res://", ".glb"))
	for path in paths:
		var packed := load(path) as PackedScene
		if packed == null:
			continue
		var root := packed.instantiate()
		for n in [root] + root.find_children("*", "GeometryInstance3D", true, false):
			# A node from a scene instanced inside this one is that scene's own entry.
			if n != root and n.owner != root:
				continue
			if _node_unlit(n):
				out.append(path)
				break
		root.free()
	return out


func _unlit_shaders() -> PackedStringArray:
	var out := PackedStringArray()
	for path in _files("res://shaders", ".gdshader"):
		if _is_world_shader(path) and not _reaches_headlights(path):
			out.append(path)
	return out


func _scripts_with_plain_materials() -> PackedStringArray:
	var out := PackedStringArray()
	for path in _files("res://scripts", ".gd"):
		if path.ends_with("ps1_material.gd"):
			continue
		var text := FileAccess.get_file_as_string(path)
		for call in PLAIN_MATERIAL_CALLS:
			if text.contains(call):
				out.append(path)
				break
	return out


func test_every_world_shader_takes_the_headlights_or_is_listed() -> void:
	for path in _unlit_shaders():
		assert_true(EXEMPT.has(path) or KNOWN_GAPS.has(path),
			"%s draws in the world without the headlight cone: include %s, or list it in EXEMPT with a reason" % [path, HEADLIGHT_INCLUDE])


func test_every_material_built_in_code_takes_the_headlights_or_is_listed() -> void:
	for path in _scripts_with_plain_materials():
		assert_true(EXEMPT.has(path) or KNOWN_GAPS.has(path),
			"%s builds a plain material that ignores the headlight cone: use a lit shared shader, or list it in EXEMPT with a reason" % path)


func test_every_scene_and_model_draws_with_the_headlights_or_is_listed() -> void:
	for path in _unlit_scenes():
		assert_true(EXEMPT.has(path) or KNOWN_GAPS.has(path),
			"%s has a mesh whose material ignores the headlight cone: give it a lit shared shader, or list it in EXEMPT with a reason" % path)


# A fixed gap or a deleted file must leave the lists too, so they only ever shrink to what's real.
func test_the_lists_name_only_things_that_are_still_unlit() -> void:
	var unlit := _unlit_shaders()
	unlit.append_array(_scripts_with_plain_materials())
	unlit.append_array(_unlit_scenes())
	for path in EXEMPT.keys() + KNOWN_GAPS:
		assert_true(unlit.has(path), "%s is listed but is lit (or gone): drop it from the list" % path)


