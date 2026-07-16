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
// BOTH the distance fade AND the near-camera dissolve are geometry SHRINK-OUTs in
// vertex() — no per-fragment `discard` anywhere. The cutout is baked into the mesh,
// so the fragment is fully opaque: the driver keeps early-Z / hidden-surface removal
// ON for the draw (any `discard` forces HSR off for the whole draw on tile-based
// mobile GPUs), and overlapping trees occlude each other cheaply. A tree the camera
// pushes inside (the chase cam, or a planted replay cam) shrinks toward its base and
// stops rasterising — a clear pocket opens with no transparency sorting, no per-frame
// CPU work, and no discard tax. NOTE: still cull_disabled — the billboarded card
// presents a consistent face to the camera, so flipping to cull_back would halve its
// fill, but the traced-silhouette mesh winding can't be verified headless (a wrong
// flip makes every tree vanish); flip + eyeball in-app as a separate change.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest;
uniform float render_distance = 80.0;
uniform float fade_band = 15.0;
// Within near_fade_start the tree is fully collapsed (invisible); beyond
// near_fade_end it is at full size. Between, it scales in.
uniform float near_fade_start = 0.5;
uniform float near_fade_end = 3.0;
// Bias distant sampling toward cheaper mips (mobile texture-bandwidth win).
uniform float lod_bias = 0.0;
// Fake hemisphere-ambient + one directional sun, matching the terrain
// (terrain_manager._bake_light / ps1_models_lit.gdshader). The billboard card
// normal is the horizontal to-camera direction, so hemi is fixed at 0.5 (a
// vertical surface sees half sky, half ground). NO source_color hint: terrain
// bakes raw Color floats, so trees match the ground by using them raw too.
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform vec3 sun_color = vec3(0.0);
uniform vec3 sky_color = vec3(1.0);
uniform vec3 ground_color = vec3(1.0);
// 0 = flat (unlit, no-op multiply), 1 = full shading. Default 0 keeps a material
// that never sets these rendering exactly as before.
uniform float light_amount = 0.0;

varying vec3 v_tint;

void vertex() {
	// Per-instance world origin (column 3 of the model matrix).
	vec3 origin = MODEL_MATRIX[3].xyz;
	float cam_dist = distance(INV_VIEW_MATRIX[3].xyz, origin);
	// Distance shrink-out: 1 up close, 0 at the far cutoff.
	float fade = clamp((render_distance - cam_dist) / max(fade_band, 0.001), 0.0, 1.0);
	// Near-camera shrink-in: 0 right on the camera, 1 beyond near_fade_end. Combined
	// with the far fade so the card collapses at BOTH ends of the range.
	float near_grow = clamp((cam_dist - near_fade_start) / max(near_fade_end - near_fade_start, 0.001), 0.0, 1.0);
	float scale = fade * near_grow;

	// Fixed hemisphere ambient for a vertical card (hemi = 0.5).
	vec3 ambient = mix(ground_color, sky_color, 0.5);

	bool felled = INSTANCE_CUSTOM.x > 0.5;
	vec3 world_pos;
	if (felled) {
		// Locked cross: the MODEL transform already carries the topple tilt + the
		// authored size scale. Shrink toward the base pivot for both fades.
		world_pos = (MODEL_MATRIX * vec4(VERTEX * scale, 1.0)).xyz;
		// Ambient-only: felled trees lie flat and are a rare, transient minority,
		// so skip the directional term rather than derive a per-plane normal.
		v_tint = mix(vec3(1.0), ambient, light_amount);
	} else if (COLOR.r > 0.5) {
		// Standing: collapse plane 1 (the ZY plane) to the origin so only the
		// billboarded front card is visible — a standing tree is one camera-facing
		// card, not a "+", and pays no doubled overdraw.
		world_pos = origin;
		v_tint = vec3(1.0); // zero-area, never rasterised; assign for completeness.
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
		vec3 local = (right * (VERTEX.x * sx) + up * (VERTEX.y * sy)) * scale;
		world_pos = origin + local;
		// Card normal == to_cam (horizontal). Same math as the terrain bake; the
		// dot naturally ignores sun_dir's vertical component against a flat normal.
		float ndl = max(dot(to_cam, sun_dir), 0.0);
		vec3 lit = ambient + sun_color * ndl;
		v_tint = mix(vec3(1.0), lit, light_amount);
	}
	// Rewrite to clip space directly; the default MODELVIEW path is bypassed.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
}

void fragment() {
	ALBEDO = texture(albedo, UV, lod_bias).rgb * v_tint;
}
