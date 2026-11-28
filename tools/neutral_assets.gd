class_name NeutralAssets
# Docs: features/neutral-format.md — update in the same change as this file.
# Tests: tests/headless/test_neutral_assets.gd — extend in the same change.
# Writes every imported asset (textures, models, materials, the theme, the font, music, shader globals) as Godot-free files for the Rust reader, and returns Godot's parity manifest lines for them.

const FOLDERS := ["blender", "models", "textures", "icons", "fonts", "tools/levels", "music"]
const RESOURCES := ["res://materials/wheel_tire.tres", "res://theme/ui_theme.tres"]
const SCENES := ["res://car.tscn"]
const FONT_SIZES := [18, 36]
const GLYPH_FIRST := 0x20
const GLYPH_LAST := 0xFF
const ARRAYS := {"vertex": Mesh.ARRAY_VERTEX, "normal": Mesh.ARRAY_NORMAL, "tangent": Mesh.ARRAY_TANGENT,
	"color": Mesh.ARRAY_COLOR, "uv": Mesh.ARRAY_TEX_UV, "uv2": Mesh.ARRAY_TEX_UV2, "index": Mesh.ARRAY_INDEX}


static func export_all(dir: String) -> PackedStringArray:
	var lines := PackedStringArray()
	var index := []
	for folder: String in FOLDERS:
		for src in _imports("res://" + folder):
			var cfg := ConfigFile.new()
			cfg.load(src + ".import")
			match String(cfg.get_value("remap", "importer", "")):
				"texture": _emit(dir, src, texture(load(src), cfg), lines, index)
				"scene": _emit(dir, src, scene_of(load(src)), lines, index)
				"font_data_dynamic": _emit(dir, src, font(load(src)), lines, index)
				"oggvorbisstr": _copy(dir, src, lines, index)
	for src in SCENES:
		_emit(dir, src, scene_of(load(src)), lines, index)
	for src in RESOURCES:
		_write_json(dir, src.trim_prefix("res://") + ".json", {"kind": "resource", "source": src, "resource": dump(load(src))}, lines, index)
	_write_json(dir, "shader_globals.json", {"kind": "shader_globals", "globals": shader_globals()}, lines, index)
	var f := FileAccess.open(dir.path_join("index.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"files": index}, "", true, true))
	f.close()
	lines.sort()
	return lines


static func _imports(folder: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(folder):
		if f.ends_with(".import"):
			out.append(folder.path_join(f.trim_suffix(".import")))
	for d in DirAccess.get_directories_at(folder):
		out.append_array(_imports(folder.path_join(d)))
	return out


# A built file is {kind, header, sections: [[name, raw, type]], lines: [[field, value]]}; this zips, writes and manifests it.
static func _emit(dir: String, src: String, built: Dictionary, lines: PackedStringArray, index: Array) -> void:
	var rel := src.trim_prefix("res://") + ".tapn"
	var header: Dictionary = built["header"]
	header["kind"] = built["kind"]
	header["source"] = src
	var zipped := []
	for s: Array in built["sections"]:
		zipped.append([s[0], NeutralFile.zip(s[1]), {"type": s[2]}])
		lines.append(NeutralFile.line(rel, s[0], s[1]))
	for l: Array in built["lines"]:
		lines.append(NeutralFile.line(rel, l[0], l[1]))
	var path := dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := NeutralFile.write(path, header, zipped)
	if err != OK:
		printerr("neutral_assets: couldn't write %s (%s)" % [path, error_string(err)])
	index.append({"path": rel, "kind": built["kind"], "source": src})


static func _write_json(dir: String, rel: String, data: Dictionary, lines: PackedStringArray, index: Array) -> void:
	var text := JSON.stringify(data, "", true, true).to_utf8_buffer()
	var path := dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(text)
	f.close()
	lines.append(NeutralFile.line(rel, "json", text))
	index.append({"path": rel, "kind": data["kind"], "source": data.get("source", "res://project.godot")})


static func _copy(dir: String, src: String, lines: PackedStringArray, index: Array) -> void:
	var rel := src.trim_prefix("res://")
	var bytes := FileAccess.get_file_as_bytes(src)
	var path := dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	lines.append(NeutralFile.line(rel, "ogg", bytes))
	index.append({"path": rel, "kind": "ogg", "source": src})


static func format_name(f: int) -> String:
	return String(ClassDB.class_get_enum_constants("Image", "Format")[f]).trim_prefix("FORMAT_")


# Decoded pixels of every mip; a VRAM-compressed texture also keeps both imported block variants untouched for the GPU.
static func texture(tex: Texture2D, cfg: ConfigFile) -> Dictionary:
	var img := tex.get_image()
	var stored := format_name(img.get_format())
	if img.is_compressed():
		img.decompress()
	var header := {"width": img.get_width(), "height": img.get_height(), "mipmaps": img.get_mipmap_count(),
		"format": format_name(img.get_format()), "stored_format": stored, "params": {}, "blocks": {}}
	for k in ["compress/mode", "compress/lossy_quality", "mipmaps/generate"]:
		if cfg.has_section_key("params", k):
			header["params"][k] = cfg.get_value("params", k)
	var sections := [["pixels", img.get_data(), "u8"]]
	for variant in ["s3tc", "etc2"]:
		var ctex_path := String(cfg.get_value("remap", "path." + variant, ""))
		if ctex_path.is_empty():
			continue
		var ctex := CompressedTexture2D.new()
		if ctex.load(ctex_path) != OK:
			printerr("neutral_assets: couldn't load %s" % ctex_path)
			continue
		var b := ctex.get_image()
		header["blocks"][variant] = {"format": format_name(b.get_format()), "width": b.get_width(), "height": b.get_height(), "mipmaps": b.get_mipmap_count()}
		sections.append(["blocks." + variant, b.get_data(), "u8"])
	var lines := [["width", img.get_width()], ["height", img.get_height()], ["mipmaps", img.get_mipmap_count()]]
	return {"kind": "texture", "header": header, "sections": sections, "lines": lines}


static func scene_of(packed: PackedScene) -> Dictionary:
	var root := packed.instantiate()
	var built := scene(root)
	root.free()
	return built


# Every MeshInstance3D under root, each distinct mesh and material stored once and referenced by index.
static func scene(root: Node) -> Dictionary:
	var meshes := []
	var mesh_ids := {}
	var materials := []
	var mat_ids := {}
	var nodes := []
	var sections := []
	var lines := []
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var m: Mesh = mi.mesh
		if not mesh_ids.has(m.get_instance_id()):
			mesh_ids[m.get_instance_id()] = meshes.size()
			meshes.append(_mesh(m, meshes.size(), materials, mat_ids, sections, lines))
		var xf := _relative(mi, root)
		var flat := [xf.basis.x.x, xf.basis.x.y, xf.basis.x.z, xf.basis.y.x, xf.basis.y.y, xf.basis.y.z,
			xf.basis.z.x, xf.basis.z.y, xf.basis.z.z, xf.origin.x, xf.origin.y, xf.origin.z]
		var active := []
		for s in m.get_surface_count():
			active.append(_material_index(mi.get_active_material(s), materials, mat_ids))
		var k := nodes.size()
		nodes.append({"path": String(root.get_path_to(mi)), "transform": flat, "mesh": mesh_ids[m.get_instance_id()],
			"materials": active, "visible": _visible(mi, root)})
		lines.append(["node%d.transform" % k, PackedFloat64Array(flat).to_byte_array()])
		lines.append(["node%d.mesh" % k, mesh_ids[m.get_instance_id()]])
	return {"kind": "scene", "header": {"nodes": nodes, "meshes": meshes, "materials": materials}, "sections": sections, "lines": lines}


static func _mesh(m: Mesh, i: int, materials: Array, mat_ids: Dictionary, sections: Array, lines: Array) -> Dictionary:
	var surfaces := []
	for j in m.get_surface_count():
		var arrays := m.surface_get_arrays(j)
		var present := []
		for name: String in ARRAYS:
			var a: Variant = arrays[ARRAYS[name]]
			if a == null or a.is_empty():
				continue
			present.append(name)
			sections.append(["m%d.s%d.%s" % [i, j, name], a.to_byte_array(), "i32" if name == "index" else "f32"])
		var rs := RenderingServer.mesh_get_surface(m.get_rid(), j)
		var edges := []
		var lods: Array = rs.get("lods", [])
		var index_count: int = rs.get("index_count", 0)
		var elem: int = (rs["index_data"] as PackedByteArray).size() / index_count if index_count > 0 else 4
		for k in lods.size():
			edges.append(lods[k]["edge_length"])
			lines.append(["m%d.s%d.lod%d.edge_length" % [i, j, k], float(lods[k]["edge_length"])])
			sections.append(["m%d.s%d.lod%d" % [i, j, k], _widen(lods[k]["index_data"], elem).to_byte_array(), "i32"])
		var box := m.surface_get_arrays(j)[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var aabb: AABB = rs.get("aabb", AABB())
		surfaces.append({"primitive": int(rs.get("primitive", 3)), "arrays": present, "lods": edges,
			"aabb": [aabb.position.x, aabb.position.y, aabb.position.z, aabb.size.x, aabb.size.y, aabb.size.z],
			"vertex_count": box.size(), "material": _material_index(m.surface_get_material(j), materials, mat_ids)})
		lines.append(["m%d.s%d.primitive" % [i, j], int(rs.get("primitive", 3))])
	return {"surfaces": surfaces}


# Godot stores LOD indices as u16 when the surface has at most 65536 vertices, else u32.
static func _widen(data: PackedByteArray, elem: int) -> PackedInt32Array:
	if elem == 4:
		return data.to_int32_array()
	var out := PackedInt32Array()
	out.resize(data.size() / 2)
	for n in out.size():
		out[n] = data.decode_u16(n * 2)
	return out


static func _material_index(mat: Material, materials: Array, mat_ids: Dictionary) -> int:
	if mat == null:
		return -1
	if not mat_ids.has(mat.get_instance_id()):
		mat_ids[mat.get_instance_id()] = materials.size()
		materials.append(dump(mat))
	return mat_ids[mat.get_instance_id()]


# A node's transform relative to root, built up the parent chain because the scene is never added to the tree.
static func _relative(n: Node, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


static func _visible(n: Node, root: Node) -> bool:
	while n != null and n != root:
		if n is Node3D and not (n as Node3D).visible:
			return false
		n = n.get_parent()
	return true


# Godot's own rasterised glyphs, so the Rust UI draws the same pixels and never rasterises.
static func font(f: FontFile) -> Dictionary:
	var ts := TextServerManager.get_primary_interface()
	var rid := f.get_rids()[0]
	var header := {"sizes": {}}
	var sections := [["ttf", f.data, "u8"]]
	var lines := []
	for size: int in FONT_SIZES:
		var sz := Vector2i(size, 0)
		ts.font_render_range(rid, sz, GLYPH_FIRST, GLYPH_LAST)
		var glyphs := []
		var flat := PackedFloat64Array()
		for cp in range(GLYPH_FIRST, GLYPH_LAST + 1):
			var g := ts.font_get_glyph_index(rid, size, cp, 0)
			if g == 0:
				continue
			var adv := ts.font_get_glyph_advance(rid, size, g)
			var off := ts.font_get_glyph_offset(rid, sz, g)
			var gs := ts.font_get_glyph_size(rid, sz, g)
			var uv := ts.font_get_glyph_uv_rect(rid, sz, g)
			var row := [cp, adv.x, adv.y, off.x, off.y, gs.x, gs.y, uv.position.x, uv.position.y, uv.size.x, uv.size.y, ts.font_get_glyph_texture_idx(rid, sz, g)]
			glyphs.append(row)
			flat.append_array(row)
		var textures := []
		for t in ts.font_get_texture_count(rid, sz):
			var img := ts.font_get_texture_image(rid, sz, t)
			textures.append({"width": img.get_width(), "height": img.get_height(), "format": format_name(img.get_format())})
			sections.append(["atlas.%d.%d" % [size, t], img.get_data(), "u8"])
		var ascent := ts.font_get_ascent(rid, size)
		var descent := ts.font_get_descent(rid, size)
		header["sizes"][str(size)] = {"ascent": ascent, "descent": descent, "glyphs": glyphs, "textures": textures}
		lines.append(["glyphs.%d" % size, flat.to_byte_array()])
		lines.append(["ascent.%d" % size, ascent])
		lines.append(["descent.%d" % size, descent])
	return {"kind": "font", "header": header, "sections": sections, "lines": lines}


static func shader_globals() -> Array:
	var cfg := ConfigFile.new()
	cfg.load("res://project.godot")
	var out := []
	if cfg.has_section("shader_globals"):
		for k in cfg.get_section_keys("shader_globals"):
			var g: Dictionary = cfg.get_value("shader_globals", k)
			out.append({"name": k, "type": g.get("type", ""), "value": _json(g.get("value"))})
	return out


# Every stored property of a resource as JSON; textures, shaders and anything saved in its own file become its res:// path, embedded sub-resources are inlined.
static func dump(res: Resource) -> Dictionary:
	var out := {"class": res.get_class()}
	for p in res.get_property_list():
		if not (p["usage"] & PROPERTY_USAGE_STORAGE) or p["name"] == "script":
			continue
		out[p["name"]] = _json(res.get(p["name"]))
	return out


static func _json(v: Variant) -> Variant:
	if v is Texture or v is Shader:
		return (v as Resource).resource_path
	if v is Resource:
		var path := (v as Resource).resource_path
		return path if not path.is_empty() and not path.contains("::") else dump(v)
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return String(v)
		TYPE_COLOR:
			return [v.r, v.g, v.b, v.a]
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [v.x, v.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [v.x, v.y, v.z]
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION:
			return [v.x, v.y, v.z, v.w]
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[str(k)] = _json(v[k])
			return d
	if typeof(v) >= TYPE_ARRAY:
		var a := []
		for x in v:
			a.append(_json(x))
		return a
	return var_to_str(v)
