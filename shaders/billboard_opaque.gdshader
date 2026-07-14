// Opaque tight-cutout billboard that becomes a cross when felled. The instanced
// silhouette mesh (see TreeSilhouette) is a "+" of two planes; each vertex carries
// a plane FLAG in COLOR.r (0 = XY plane, 1 = ZY plane) and each instance a FELLED
// flag in INSTANCE_CUSTOM.x (0 = standing, 1 = knocked over).
//
//  - STANDING (INSTANCE_CUSTOM.x == 0): plane 0 is Y-billboarded to face the camera
//    (cylindrical, world-Y up) and plane 1 is collapsed to a point, so a standing
//    tree is a single camera-facing card — always presents its cutout, no doubled
//    overdraw. The cutout is baked into the MESH (no alpha-test), so early-Z stays
//    on and overdraw collapses on tile-based mobile GPUs.
//  - FELLED (INSTANCE_CUSTOM.x == 1): BOTH planes render at their authored positions
//    and the instance's MODEL transform (a topple tilt about the base) is applied
//    verbatim — the card is locked into the "+" cross and toppled, so a fallen tree
//    reads as a solid 3D shape instead of a flat sheet lying on the ground.
//
// Distance fade is a geometry shrink-out (opaque), NOT a screen-door dither. It DOES
// carry the same NEAR-CAMERA dither dissolve as tree_canopy.gdshader: fragments
// within `near_fade_end` metres of the camera dissolve out via a Bayer dither, so a
// tree the camera pushes inside (the chase cam, or a planted replay cam) stops
// blocking the view — a clear pocket opens around the camera with no transparency
// sorting and no per-frame CPU work.
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
	// Shrink-out fade: 1 up close, 0 at the cutoff (opaque, no discard).
	float fade = clamp((render_distance - cam_dist) / max(fade_band, 0.001), 0.0, 1.0);

	bool felled = INSTANCE_CUSTOM.x > 0.5;
	vec3 world_pos;
	if (felled) {
		// Locked cross: the MODEL transform already carries the topple tilt + the
		// authored size scale, so the standard model transform places both planes
		// as a fixed cross that lies down. Shrink toward the base pivot for the
		// distance fade.
		world_pos = (MODEL_MATRIX * vec4(VERTEX * fade, 1.0)).xyz;
	} else if (COLOR.r > 0.5) {
		// Standing: collapse plane 1 (the ZY plane) to the origin so only the
		// billboarded front card is visible — a standing tree is one camera-facing
		// card, not a "+", and pays no doubled overdraw.
		world_pos = origin;
	} else {
		// Standing: Y-billboard plane 0 toward the camera (flattened to XZ so it
		// stays upright). Authored size lives as the instance scale (column lengths).
		vec3 to_cam = INV_VIEW_MATRIX[3].xyz - origin;
		to_cam.y = 0.0;
		to_cam = normalize(to_cam);
		vec3 up = vec3(0.0, 1.0, 0.0);
		vec3 right = normalize(cross(up, to_cam));
		float sx = length(MODEL_MATRIX[0].xyz);
		float sy = length(MODEL_MATRIX[1].xyz);
		vec3 local = (right * (VERTEX.x * sx) + up * (VERTEX.y * sy)) * fade;
		world_pos = origin + local;
	}
	v_world = world_pos;
	// Rewrite to clip space directly; the default MODELVIEW path is bypassed.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
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
