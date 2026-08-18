shader_type sky;
// Two-panorama sky, used by the OVERWORLD ONLY (overworld.tscn's own Sky sub-resource).
// PanoramaSkyMaterial holds exactly one texture and therefore cannot blend, so crossing a
// region boundary snapped the sky while the haze faded. This is a drop-in replacement that
// samples two equirectangular panoramas and mixes them by `sky_blend`.
//
// EXACTLY PanoramaSkyMaterial at sky_blend = 0. Godot's built-in panorama sky shader is
// `COLOR = texture(source_panorama, SKY_COORDS).rgb * energy_multiplier;` — SKY_COORDS is the
// engine's own equirectangular mapping of EYEDIR, so reusing it (rather than rolling an
// atan/asin mapping by hand) makes the two materials pixel-identical. The sampler hints match
// the engine's too: filter_nearest + source_color, matching PanoramaSkyMaterial's default
// `filter = true`, so nothing softens or shifts colour space on the swap.
//
// Stages are untouched: main.tscn keeps its own PanoramaSkyMaterial. See features/overworld.md
// -> "Region look".

// NEAREST filtering, not linear. PanoramaSkyMaterial defaults to linear and escaped the rule by
// not being a .gdshader, but this project filters every shader sampler nearest for its PS1 look and
// test_render_smoke.gd enforces it across shaders/. A linear sky against a nearest-filtered world is
// the inconsistency, not the other way round — so the sky now matches everything else.
uniform sampler2D panorama_a : filter_nearest, source_color, hint_default_black;
uniform sampler2D panorama_b : filter_nearest, source_color, hint_default_black;
// 0 = pure A, 1 = pure B. Tweened by Overworld._fade_sky_colours, then collapsed back to 0
// with B promoted into A so the next crossing starts clean.
uniform float sky_blend : hint_range(0.0, 1.0) = 0.0;
// PanoramaSkyMaterial's energy_multiplier, carried through so the swap cannot change brightness.
uniform float sky_energy = 1.0;

void sky() {
	vec3 a = texture(panorama_a, SKY_COORDS).rgb;
	vec3 b = texture(panorama_b, SKY_COORDS).rgb;
	COLOR = mix(a, b, clamp(sky_blend, 0.0, 1.0)) * sky_energy;
}
