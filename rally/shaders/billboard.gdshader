// Cylindrical billboard: each instanced quad yaws to face the camera but stays
// upright (world Y up). Alpha-scissor cutout for crisp edges, no blend sorting.
// Past render_distance the tree is fully culled; over the fade_band before it,
// fragments dissolve out via a screen-door dither (keeps the opaque pipeline).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
uniform float render_distance = 80.0;
uniform float fade_band = 15.0;

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
	// Per-instance world origin (column 3 of the model matrix).
	vec3 origin = MODEL_MATRIX[3].xyz;
	v_cam_dist = distance(INV_VIEW_MATRIX[3].xyz, origin);
	// Direction from the instance to the camera, flattened to the XZ plane.
	vec3 to_cam = (INV_VIEW_MATRIX[3].xyz - origin);
	to_cam.y = 0.0;
	to_cam = normalize(to_cam);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 right = normalize(cross(up, to_cam));
	// Preserve the instance's authored scale (quad is built 1x1, scaled by MODEL).
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	vec3 world_pos = origin + right * (VERTEX.x * sx) + up * (VERTEX.y * sy);
	// Rewrite to clip space directly; the default MODELVIEW path is bypassed.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
}

void fragment() {
	vec4 tex = texture(albedo, UV);
	// 1 up close, 0 at the cutoff; dither out fragments as it drops.
	float fade = clamp((render_distance - v_cam_dist) / max(fade_band, 0.001), 0.0, 1.0);
	if (tex.a < alpha_scissor || fade <= bayer4x4(FRAGCOORD.xy)) {
		discard;
	}
	ALBEDO = tex.rgb;
}
