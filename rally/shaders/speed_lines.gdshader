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
uniform float density = 90.0;
// Radial fade band, in normalised screen radius (~0 at the centre, ~1 near the
// short-edge midpoints): streaks are invisible inside inner_radius and ramp to
// full strength by outer_radius, so the centre of the screen stays readable.
uniform float inner_radius : hint_range(0.0, 2.0) = 0.35;
uniform float outer_radius : hint_range(0.0, 2.0) = 1.0;
// Per-streak shimmer speed, so the lines flicker rather than sit as a static fan.
uniform float flicker_speed = 8.0;

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

	// Per-streak random thickness + flicker so the fan varies and shimmers.
	float rnd = hash(idx);
	float half_width = mix(0.10, 0.42, rnd);
	float line = smoothstep(half_width, half_width * 0.4, abs(across));
	float flicker = mix(0.45, 1.0, 0.5 + 0.5 * sin(TIME * flicker_speed + rnd * 6.2831853));

	// Radial mask: clear centre, dense edges.
	float radial = smoothstep(inner_radius, outer_radius, dist);

	float alpha = line * radial * flicker * intensity;
	COLOR = vec4(line_color.rgb, line_color.a * alpha);
}
