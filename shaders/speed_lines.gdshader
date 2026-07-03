shader_type canvas_item;

// Anime "edge speed lines": black streaks radiating inward from the screen
// edges toward the centre, leaving the middle clear — the classic manga
// sense-of-speed effect. Drawn on its own CanvasLayer ABOVE the PS1 dither
// post-process, so the streaks stay crisp rather than getting broken up by the
// 5-bit + Bayer quantisation. `intensity` (0..1) is driven per frame from the
// car's airspeed by speed_lines.gd; at 0 the whole effect is invisible.

// Overall strength, 0 = off. Ramped from the car's speed by speed_lines.gd.
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
// Streak colour (black by default — the standard look).
uniform vec4 line_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
// Number of angular slots around the circle; higher = more, finer streaks.
uniform float density = 28.0;
// Per-streak start radius band, in normalised screen radius (~0 at the centre,
// ~1 near the short-edge midpoints). Each streak begins at a random radius
// between inner_radius and outer_radius and runs SOLID out to the screen edge —
// so a higher inner_radius keeps more of the centre clear (shorter streaks) and
// the spread between the two gives the streaks varied lengths.
uniform float inner_radius : hint_range(0.0, 2.0) = 0.55;
uniform float outer_radius : hint_range(0.0, 2.0) = 0.9;
// Per-streak flicker rate in discrete steps/sec: each streak jumps to a new
// random brightness this often, for a choppy hand-drawn flicker (not a smooth pulse).
uniform float flicker_speed = 14.0;

// Cheap per-slot pseudo-random value, used for per-streak width + flicker phase.
float hash(float n) {
	return fract(sin(n) * 43758.5453123);
}

void fragment() {
	// Aspect-correct, centre-origin coords so the burst reads as roughly circular
	// rather than stretched on a wide viewport. SCREEN_PIXEL_SIZE = 1/viewport, so
	// .y/.x = width/height.
	vec2 uv = SCREEN_UV - 0.5;
	uv.x *= SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	float dist = length(uv) * 2.0;       // ~0 at centre .. ~1 at short-edge midpoints
	float angle = atan(uv.y, uv.x);      // -PI..PI

	// Bucket the angle into `density` slots; each slot carries one streak.
	float slot = (angle / 6.2831853 + 0.5) * density;
	float idx = floor(slot);
	float across = fract(slot) - 0.5;    // -0.5..0.5 position across the slot

	// Per-streak random thickness. Thin streaks; hard `step` edge (no feathering)
	// so each line is crisp, like an inked stroke rather than an airbrushed smear.
	float rnd = hash(idx);
	float half_width = mix(0.04, 0.16, rnd);
	float line = 1.0 - step(half_width, abs(across));
	// Hard on/off flicker: quantise time and threshold a per-streak random so each
	// streak is either fully drawn or gone for the current step — a hard cut, like
	// hand-inked lines blinking in and out, rather than a smooth opacity fade.
	float flicker = step(0.3, hash(idx * 1.7 + floor(TIME * flicker_speed)));

	// Hard radial start, varied per streak so lengths differ (no uniform ring):
	// each streak is solid from its random start radius out to the screen edge.
	float line_start = mix(inner_radius, outer_radius, hash(idx * 1.7 + 3.1));
	float radial = step(line_start, dist);

	float alpha = line * radial * flicker * intensity;
	COLOR = vec4(line_color.rgb, line_color.a * alpha);
}
