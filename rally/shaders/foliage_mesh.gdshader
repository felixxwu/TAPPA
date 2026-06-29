// Flat (PS1-style) shader for instanced foliage MESHES (e.g. the ground-cover
// bushes), as opposed to billboard.gdshader which is for camera-facing quads.
// Geometry is real, so vertices use the normal model transform — no billboarding.
// Per-instance baked terrain light arrives in COLOR (MultiMesh instance colour),
// multiplied into ALBEDO exactly like the terrain shader, so foliage matches the
// ground tint/lighting everywhere. Past render_distance each instance is fully
// culled; over the fade_band before it, fragments dissolve out via a screen-door
// dither (keeps the opaque pipeline — no transparency sorting, mobile-friendly).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest_mipmap;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float render_distance = 80.0;
uniform float fade_band = 15.0;
// Bias distant sampling toward cheaper (lower) mip levels — saves texture
// bandwidth on tile-based mobile GPUs. Needs mipmaps enabled on the texture.
uniform float lod_bias = 0.0;

varying float v_cam_dist;

// 4x4 ordered (Bayer) dither threshold in [0,1), indexed by screen pixel.
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
	// Per-instance world origin (column 3 of the model matrix) → camera distance.
	v_cam_dist = distance(INV_VIEW_MATRIX[3].xyz, MODEL_MATRIX[3].xyz);
}

void fragment() {
	// 1 up close, 0 at the cutoff; dither out fragments as it drops.
	float fade = clamp((render_distance - v_cam_dist) / max(fade_band, 0.001), 0.0, 1.0);
	if (fade <= bayer4x4(FRAGCOORD.xy)) {
		discard;
	}
	ALBEDO = texture(albedo, UV, lod_bias).rgb * albedo_color.rgb * COLOR.rgb;
}
