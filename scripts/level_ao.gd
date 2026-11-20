class_name LevelAO
extends RefCounted
# Fake ambient occlusion for the level view: a coarse map of ground darkening round trees, buildings and log piles, read by level_ground.gdshader.

var size := 600.0
var n := 2
var tree_bytes := PackedByteArray()  # RG8 per texel, empty until trees are stamped
var bytes := PackedByteArray()  # 255 clear, lower darker; same texel grid as the bake's road frame


func _init(p_size: float, p_n: int) -> void:
	size = p_size
	n = p_n
	bytes.resize(n * n)
	bytes.fill(255)


func cell() -> float:
	return size / (n - 1)


# 0..1 at the texel nearest (x, z); 1 off the map.
func at(x: float, z: float) -> float:
	var c := roundi((x + size * 0.5) / cell())
	var r := roundi((z + size * 0.5) / cell())
	if c < 0 or r < 0 or c >= n or r >= n:
		return 1.0
	return bytes[r * n + c] / 255.0


# One tree per texel, kept at its exact spot: R packs its offset from the texel centre (4 bits x, 4 bits z), G its patch radius as a fraction of one texel (0 = no tree). The wider tree wins a shared texel.
func stamp_trees(xf: PackedFloat32Array, radius_per_width: float) -> void:
	if tree_bytes.is_empty():
		tree_bytes.resize(n * n * 2)
		tree_bytes.fill(0)
	var inv := 1.0 / cell()
	var off := size * 0.5
	for i in xf.size() / 12:
		var fx := (xf[i * 12 + 3] + off) * inv
		var fz := (xf[i * 12 + 11] + off) * inv
		var c := roundi(fx)
		var r := roundi(fz)
		if c < 0 or r < 0 or c >= n or r >= n:
			continue
		var rad := clampi(roundi(Vector2(xf[i * 12], xf[i * 12 + 8]).length() * radius_per_width * inv * 255.0), 1, 255)
		var k := (r * n + c) * 2
		if rad <= tree_bytes[k + 1]:
			continue
		var qx := clampi(int((fx - c + 0.5) * 16.0), 0, 15)
		var qz := clampi(int((fz - r + 0.5) * 16.0), 0, 15)
		tree_bytes[k] = qx << 4 | qz
		tree_bytes[k + 1] = rad


# The tree stamped in texel (c, r) as {pos: Vector2 (world xz), radius: m}, or an empty dictionary when there is none.
func tree_at(c: int, r: int) -> Dictionary:
	if tree_bytes.is_empty():
		return {}
	var k := (r * n + c) * 2
	if tree_bytes[k + 1] == 0:
		return {}
	var q: int = tree_bytes[k]
	var pos := (Vector2(c, r) + (Vector2(q >> 4, q & 15) + Vector2(0.5, 0.5)) / 16.0 - Vector2(0.5, 0.5)) * cell() - Vector2(size, size) * 0.5
	return {"pos": pos, "radius": tree_bytes[k + 1] / 255.0 * cell()}


# A box on the ground (centre, unit `axis` of its length, half extents x/z) darkening fully inside and fading out over `reach` metres.
func stamp_box(centre: Vector2, axis: Vector2, half: Vector2, reach: float, strength: float) -> void:
	var side := Vector2(-axis.y, axis.x)
	var span := half.length() + reach
	var inv := 1.0 / cell()
	var off := size * 0.5
	var c0 := maxi(0, floori((centre.x - span + off) * inv))
	var c1 := mini(n - 1, ceili((centre.x + span + off) * inv))
	var r0 := maxi(0, floori((centre.y - span + off) * inv))
	var r1 := mini(n - 1, ceili((centre.y + span + off) * inv))
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			var d := Vector2(c / inv - off, r / inv - off) - centre
			var out := Vector2(maxf(absf(d.dot(axis)) - half.x, 0.0), maxf(absf(d.dot(side)) - half.y, 0.0)).length()
			var t := 1.0 - out / maxf(reach, 0.001)
			if t <= 0.0:
				continue
			var v := 255 - int(255.0 * strength * t * t)
			if v < bytes[r * n + c]:
				bytes[r * n + c] = v


func apply_to(mat: ShaderMaterial) -> void:
	if not tree_bytes.is_empty():
		mat.set_shader_parameter("tree_ao_map", ImageTexture.create_from_image(Image.create_from_data(n, n, false, Image.FORMAT_RG8, tree_bytes)))
	mat.set_shader_parameter("tree_ao_strength", Config.data.level_ao_tree_ground)
	mat.set_shader_parameter("ao_map", ImageTexture.create_from_image(Image.create_from_data(n, n, false, Image.FORMAT_L8, bytes)))
