// Screen-aligned billboard with a PER-INSTANCE roll, size and colour — the
// material behind the wheel-particle pool (scripts/wheel_particles.gd,
// features/wheel-dust.md).
//
// WHY THIS EXISTS instead of BaseMaterial3D's BILLBOARD_ENABLED: the stock
// billboard rebuilds the model-view basis from the camera columns every frame and
// DISCARDS whatever basis the MultiMesh supplied, keeping only the origin. That is
// free when every particle is an identical square (the pool used to pre-seed an
// identity basis and rewrite only the origin), but it leaves nowhere for a
// per-particle rotation to live. `billboard_keep_scale` re-applies the instance
// SCALE after the fact, but never a roll. So the billboard is done here by hand,
// and the instance basis is read as 2D scale + rotation rather than thrown away.
//
// The instance basis is written by wheel_particles.gd._write_slot as:
//     column 0 = (cos * half_w,  sin * half_w, 0)
//     column 1 = (-sin * half_h, cos * half_h, 0)
// so column LENGTHS carry the half-extents and column 0's DIRECTION carries the
// roll. That keeps the MultiMesh stride at the standard 12 transform floats (+4
// colour) — no INSTANCE_CUSTOM, no extra per-instance data, one buffer upload.
//
// Opaque and unshaded, matching the pool's previous StandardMaterial3D: no alpha
// blending means no transparency sorting for a pool that can be at its cap.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

varying vec3 v_color;

void vertex() {
	// Per-instance world origin (column 3 of the model matrix).
	vec3 origin = MODEL_MATRIX[3].xyz;
	// Half-extents live as the instance basis column lengths (see header).
	float half_w = length(MODEL_MATRIX[0].xyz);
	float half_h = length(MODEL_MATRIX[1].xyz);
	// Roll: column 0's direction is (cos, sin). A zero-length column means a slot
	// that was never written (a fresh pool) — fall back to no rotation rather than
	// dividing by zero; such a slot is degenerate and parked off-screen anyway.
	float c = 1.0;
	float s = 0.0;
	if (half_w > 0.0) {
		c = MODEL_MATRIX[0].x / half_w;
		s = MODEL_MATRIX[0].y / half_w;
	}
	// Scale the unit quad to the instance's half-extents, then roll it in the
	// billboard plane before projecting onto the camera's right/up axes.
	vec2 local = vec2(VERTEX.x * half_w * 2.0, VERTEX.y * half_h * 2.0);
	vec2 rolled = vec2(c * local.x - s * local.y, s * local.x + c * local.y);
	// Fully screen-aligned (spherical) billboard: the camera's right/up axes, not
	// the world-Y-up cylindrical form the tree billboards use — a flung clod has no
	// meaningful "upright", and staying screen-aligned keeps the roll readable.
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 world_pos = origin + right * rolled.x + up * rolled.y;
	// Rewrite to clip space directly; the default MODELVIEW path is bypassed
	// (same approach as shaders/billboard_opaque.gdshader).
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	// Per-instance colour: MultiMesh instance colours (mm.use_colors) arrive here
	// in COLOR. Unshaded, so it goes straight to albedo.
	v_color = COLOR.rgb;
}

void fragment() {
	ALBEDO = v_color;
}
