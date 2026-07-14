// Opaque tight-cutout billboard: each instanced silhouette mesh is a fixed "+"
// cross of two planes (see TreeSilhouette), planted at its own per-instance yaw
// -- it does NOT rotate to face the camera, so a stand of trees reads as varied
// solid foliage from any angle. The cutout is baked into the MESH, so this shader
// has NO alpha-test for the cutout -> early-Z stays on and overdraw collapses on
// tile-based mobile GPUs. Distance fade is a geometry shrink-out (opaque), NOT
// the screen-door dither of billboard.gdshader.
//
// It DOES carry the same NEAR-CAMERA dither dissolve as tree_canopy.gdshader:
// fragments within `near_fade_end` metres of the camera dissolve out via a
// screen-door (Bayer) dither, so a tree the camera pushes inside (the chase cam,
// or a planted replay cam) stops blocking the view — a clear pocket opens around
// the camera with no transparency sorting and no per-frame CPU work.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest;
uniform float render_distance = 80.0;
uniform float fade_band = 15.0;
// Fragments closer than this to the camera are fully dissolved; beyond
// `near_fade_end` the tree is fully solid. Between, it dithers in.
uniform float near_fade_start = 0.5;
uniform float near_fade_end = 3.0;
// Bias distant sampling toward cheaper mips (mobile texture-bandwidth win).
uniform float lod_bias = 0.0;

varying vec3 v_world;

// 4x4 ordered (Bayer) dither threshold in [0,1), indexed by screen pixel — the
// same matrix billboard.gdshader / tree_canopy.gdshader use (house style).
float bayer4x4(vec2 frag) {
	int x = int(mod(frag.x, 4.0));
	int y = int(mod(frag.y, 4.0));
	int index = x + y * 4;
	float m[16] = {
		0.0,  8.0,  2.0,  10.0,
		12.0, 4.0,  14.0, 6.0,
		3.0,  11.0, 1.0,  9.0,
		15.0, 7.0,  13.0, 5.0
	};
	return m[index] / 16.0;
}

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
	// World position of the (shrunk) vertex, for the per-fragment near dissolve.
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Near-camera dither: 0 at near_fade_start, 1 at near_fade_end — dither out as
	// the fragment's distance to the camera (INV_VIEW_MATRIX column 3) drops.
	float near_dist = distance(INV_VIEW_MATRIX[3].xyz, v_world);
	float near_fade = clamp((near_dist - near_fade_start) / max(near_fade_end - near_fade_start, 0.001), 0.0, 1.0);
	if (near_fade <= bayer4x4(FRAGCOORD.xy)) {
		discard;
	}
	ALBEDO = texture(albedo, UV, lod_bias).rgb;
}
