// Vertex-shader wind sway for billboard TREES — the ONE source of truth, included
// by shaders/billboard_opaque.gdshader. See features/trees.md.
//
// WHY THIS EXISTS AT ALL: foliage materials are built in several scripts (foliage.gd,
// billboard_field.gd, and anything else that scatters a tree field) with no common
// registry, and terrain chunks stream trees in continuously — the same situation
// headlight_cone.gdshaderinc argues from. A per-material push would need
// re-registration bookkeeping on every chunk load; a `global uniform` has none.
//
// WHY PER-VERTEX, IN THE VERTEX STAGE: trees are MultiMesh instances — there is no
// per-instance CPU object to animate, and swaying the instance transforms on the CPU
// every frame would mean touching every live tree's MultiMesh buffer per frame for a
// purely cosmetic wobble. Evaluating the sway analytically in vertex() costs one
// extra offset per vertex (billboard cards are 4-8 verts each) and ZERO CPU work
// beyond the one-time uniform push below — the same trade the headlight cone makes.
//
// LEAK WARNING: global shader parameters persist across scene changes. The podium
// and menu showcase render the same tree shader as a stage, so wind_strength MUST be
// reseeded (to the BASE, non-storm amount — see WindSway.reset()) whenever a stage is
// exited, or a storm's stronger sway would keep blowing on a calm podium.

global uniform float wind_strength; // sway at the tip, as a FRACTION of the
	// instance's height. 0 = perfectly still and a bit-for-bit no-op.
global uniform float wind_speed;    // sway oscillations per second (radians/s scale).
global uniform vec3 wind_dir;       // world-space horizontal unit heading the
	// foliage leans toward (see WindSway.params for the heading convention).

// World-space horizontal offset for a foliage vertex. `origin` is the instance's
// world-space base (world_pos before any sway), `height_frac` is that vertex's
// normalized 0..1 height up the card (0 = base, 1 = tip), and `height_m` is the
// instance's authored world-space height.
vec3 wind_sway_offset(vec3 origin, float height_frac, float height_m) {
	// Branch on a GLOBAL uniform, so it is coherent across the whole draw — every
	// vertex in every wavefront takes the same side, the cheap case for a GPU
	// branch (same reasoning as headlight_lit's early-out).
	if (wind_strength <= 0.0) {
		return vec3(0.0);
	}
	// Deterministic per-instance phase hashed off the instance's horizontal world
	// origin, so neighbouring trees don't sway in lockstep (no per-instance uniform
	// or CPU-side random seed needed — the position IS the seed).
	float phase = origin.x * 0.37 + origin.z * 0.71;
	// Two summed sines at different rates/weights so the motion doesn't read as a
	// metronome: the second term runs faster (~2.3x) and lighter (~0.3 weight),
	// which beats against the first and breaks up the period.
	float t = TIME * wind_speed;
	float sway = sin(t + phase) + 0.3 * sin(t * 2.3 + phase * 1.7);
	// Bend profile: height_frac^2 keeps the base planted (a real tree's trunk barely
	// moves) and concentrates the motion at the top, where a card's crown is.
	float bend = height_frac * height_frac;
	return wind_dir * (sway * bend * wind_strength * height_m);
}
