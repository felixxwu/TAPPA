// Foliage near-camera SHRINK-OUT (shared): unshaded, double-sided leaf/frond shell
// used by the ground bushes (scripts/foliage.gd bush_mesh). The mesh is kept
// double-sided (cull_disabled) because single-sided back-face culling rendered the
// single-sided cards concave / "front faces missing" on some web/device GL targets
// (see features/trees.md), so cull_back is NOT safe here.
//
// A bush the camera pushes inside (the chase cam brushing one, or a planted replay
// cam sitting among them) must not fill the frame. Previously each fragment within
// `near_fade_end` metres dithered out via a per-fragment `discard`. That was
// replaced by a VERTEX-STAGE collapse: as the camera closes inside near_fade_end,
// the whole instance shrinks toward its origin until it degenerates and stops
// rasterising. The win over the old dither: NO per-fragment `discard`, so the
// driver keeps early-Z / hidden-surface removal ON for the draw (any discard in a
// shader forces HSR off for the whole draw on tile-based mobile GPUs). It pops
// rather than dithers, but only when the camera is right on top of the bush. The
// collapse is per-instance (origin + camera are uniform across an instance's verts)
// so it shrinks cleanly with no triangle distortion.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest_mipmap;
// Flat tint multiplied over the texture (the bushes' cfg.bush_tint); white = no tint.
uniform vec4 tint : source_color = vec4(1.0);
// Within near_fade_start the instance is fully collapsed (invisible); beyond
// near_fade_end it is at full size. Between, it scales in.
uniform float near_fade_start = 0.5;
uniform float near_fade_end = 3.0;
// World-space height of the bush (its target height). Used to clamp the near-fade
// reference point to the bush's vertical span — see the cam_dist note in vertex().
uniform float canopy_height = 1.5;

void vertex() {
	// Per-instance world origin (base, column 3 of the model matrix). Near-fade
	// distance is measured to the TRUNK AXIS, not the base point: the camera is
	// projected onto the vertical axis and clamped to the [base, base+canopy_height]
	// span, so cam_dist is the HORIZONTAL proximity while the camera sits inside the
	// bush's height. Measuring to the ground-level base let the chase cam's ~2.5 m
	// elevation swamp the distance, so the collapse never fired (see billboard_opaque).
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float ref_y = clamp(cam.y, origin.y, origin.y + canopy_height);
	float cam_dist = distance(cam, vec3(origin.x, ref_y, origin.z));
	float grow = clamp((cam_dist - near_fade_start) / max(near_fade_end - near_fade_start, 0.001), 0.0, 1.0);
	VERTEX *= grow;  // collapse toward the model origin as the camera closes in
}

void fragment() {
	ALBEDO = texture(albedo, UV).rgb * COLOR.rgb * tint.rgb;
}
