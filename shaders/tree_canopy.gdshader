// Foliage near-camera dither dissolve (shared): unshaded, double-sided leaf/frond
// shell used by BOTH the ground bushes (scripts/foliage.gd bush_mesh) and the legacy
// 3D tree canopy. The mesh is kept double-sided (cull_disabled) because single-sided
// back-face culling rendered it concave / "front faces missing" on some web/device
// GL targets (see features/trees.md). Double-sided is robust everywhere, but it
// means the inward-facing leaves still draw when the chase camera pushes inside a
// tree — blocking the view. To recover the "see through the tree from inside"
// behaviour that single-sided culling used to give for free, fragments within
// `near_fade_end` metres of the camera dissolve out via the same screen-door
// (Bayer) dither used for the distance cull (shaders/billboard.gdshader) — so a
// clear pocket opens around the camera with no transparency sorting and no per-
// frame CPU work, independent of the platform's culling behaviour.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest_mipmap;
// Flat tint multiplied over the texture (the bushes' cfg.bush_tint); white = no tint,
// so the tree canopy leaves it at the default.
uniform vec4 tint : source_color = vec4(1.0);
// Fragments closer than this to the camera are fully dissolved; beyond
// `near_fade_end` the foliage is fully solid. Between, it dithers in.
uniform float near_fade_start = 0.5;
uniform float near_fade_end = 3.0;

varying vec3 v_world;

// 4x4 ordered (Bayer) dither threshold in [0,1), indexed by screen pixel — the
// same matrix the billboard shader uses, so the dissolve matches the house style.
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
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// World-space distance from the camera (INV_VIEW_MATRIX column 3) to this
	// fragment. 0 at near_fade_start, 1 at near_fade_end — dither out as it drops.
	float cam_dist = distance(INV_VIEW_MATRIX[3].xyz, v_world);
	float fade = clamp((cam_dist - near_fade_start) / max(near_fade_end - near_fade_start, 0.001), 0.0, 1.0);
	if (fade <= bayer4x4(FRAGCOORD.xy)) {
		discard;
	}
	vec4 tex = texture(albedo, UV);
	ALBEDO = tex.rgb * COLOR.rgb * tint.rgb;
}
