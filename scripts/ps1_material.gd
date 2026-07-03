class_name PS1Material
extends RefCounted

## Builder for the flat, unshaded "PS1 look" StandardMaterial3D used across the
## project (world ground cover, road markings, wheel particles, etc.).


# Build an unshaded StandardMaterial3D with nearest-neighbour (mip-mapped)
# texture filtering — the flat PS1 look the rest of the world uses.
#
# - `vertex_color`: when true, sets vertex_color_use_as_albedo so per-vertex
#   colours tint the material (as road_markings / _bush_mesh do).
# - `albedo`: optional albedo texture.
static func unshaded(albedo: Texture2D = null, vertex_color: bool = false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	if vertex_color:
		mat.vertex_color_use_as_albedo = true
	if albedo != null:
		mat.albedo_texture = albedo
	return mat
