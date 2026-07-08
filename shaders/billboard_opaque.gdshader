// Opaque tight-cutout billboard: each instanced silhouette mesh is a fixed "+"
// cross of two planes (see TreeSilhouette), planted at its own per-instance yaw
// -- it does NOT rotate to face the camera, so a stand of trees reads as varied
// solid foliage from any angle. The cutout is baked into the MESH, so this shader
// has NO discard/alpha-test -> early-Z stays on and overdraw collapses on
// tile-based mobile GPUs. Distance fade is a geometry shrink-out (opaque), NOT
// the screen-door dither of billboard.gdshader.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest;
uniform float render_distance = 80.0;
uniform float fade_band = 15.0;
// Bias distant sampling toward cheaper mips (mobile texture-bandwidth win).
uniform float lod_bias = 0.0;

void vertex() {
	// Per-instance world origin (column 3 of the model matrix).
	vec3 origin = MODEL_MATRIX[3].xyz;
	float cam_dist = distance(INV_VIEW_MATRIX[3].xyz, origin);
	// Shrink-out fade: 1 up close, 0 at the cutoff. Scales the normalized mesh
	// toward its bottom-centre pivot (x/z -> 0 horizontally, y -> 0 at ground)
	// so the cross shrinks away (opaque, no discard). The MODEL matrix (carrying
	// the per-instance yaw + authored tree_size_m scale) does the rest.
	float fade = clamp((render_distance - cam_dist) / max(fade_band, 0.001), 0.0, 1.0);
	VERTEX *= fade;
}

void fragment() {
	ALBEDO = texture(albedo, UV, lod_bias).rgb;
}
