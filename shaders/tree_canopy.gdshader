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

void vertex() {
	// Per-instance world origin (column 3 of the model matrix) and its camera
	// distance — uniform across the instance, so the shrink is distortion-free.
	vec3 origin = MODEL_MATRIX[3].xyz;
	float cam_dist = distance(INV_VIEW_MATRIX[3].xyz, origin);
	float grow = clamp((cam_dist - near_fade_start) / max(near_fade_end - near_fade_start, 0.001), 0.0, 1.0);
	VERTEX *= grow;  // collapse toward the model origin as the camera closes in
}

void fragment() {
	ALBEDO = texture(albedo, UV).rgb * COLOR.rgb * tint.rgb;
}
