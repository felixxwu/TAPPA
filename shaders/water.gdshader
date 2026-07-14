shader_type spatial;
render_mode unshaded, cull_disabled;
// PS1-style lake surface. Opaque (no screen-door dither — it read as noise against
// the low-res pixelation) with a SEAMLESS tiling water texture scrolled in two
// directions for visible movement, tinted between deep and shore colours. No
// reflections, no transparency, no screen-texture read (keeps the Compatibility
// no-backbuffer choice, see features/rendering.md). See features/lakes.md.

uniform vec4 water_color : source_color = vec4(0.16, 0.32, 0.5, 1.0);
uniform vec4 shore_color : source_color = vec4(0.32, 0.52, 0.62, 1.0);
uniform sampler2D water_tex : source_color, filter_nearest, repeat_enable;
uniform float scroll_speed = 0.04;   // world-units/sec the texture drifts
uniform float tex_scale = 0.06;      // world metres -> UV (texture tiling density)
uniform float sparkle_strength = 0.25;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Two layers scrolling in different directions/speeds = a convincing shimmer.
	vec2 uv = world_pos.xz * tex_scale;
	vec2 uv_a = uv + vec2(TIME * scroll_speed, TIME * scroll_speed * 0.5);
	vec2 uv_b = uv * 1.7 + vec2(-TIME * scroll_speed * 0.6, TIME * scroll_speed * 0.9);
	float t = 0.5 * (texture(water_tex, uv_a).r + texture(water_tex, uv_b).r);
	vec3 col = mix(water_color.rgb, shore_color.rgb, t);
	col += sparkle_strength * pow(t, 6.0);  // occasional bright glint on the crests
	ALBEDO = col;
}
