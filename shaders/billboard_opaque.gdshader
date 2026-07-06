// Opaque tight-cutout billboard: each instanced silhouette mesh yaws to face the
// camera but stays upright (world Y up). The cutout is baked into the MESH (see
// TreeSilhouette), so this shader has NO discard/alpha-test -> early-Z stays on
// and overdraw collapses on tile-based mobile GPUs. Distance fade is a geometry
// shrink-out (opaque), NOT the screen-door dither of billboard.gdshader.
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
	// Direction from the instance to the camera, flattened to the XZ plane.
	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - origin;
	to_cam.y = 0.0;
	to_cam = normalize(to_cam);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 right = normalize(cross(up, to_cam));
	// Per-instance authored scale (mesh is normalized; MODEL carries tree_size_m).
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	// Shrink-out fade: 1 up close, 0 at the cutoff. Scales toward the bottom-
	// centre pivot so the card shrinks away (opaque, no discard).
	float fade = clamp((render_distance - cam_dist) / max(fade_band, 0.001), 0.0, 1.0);
	vec3 world_pos = origin
		+ right * (VERTEX.x * sx * fade)
		+ up * (VERTEX.y * sy * fade);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
}

void fragment() {
	ALBEDO = texture(albedo, UV, lod_bias).rgb;
}
