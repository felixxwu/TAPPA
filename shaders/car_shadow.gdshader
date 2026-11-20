shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// The car's body footprint in metres; the quad is that plus `soft_m` of blur on every side.
uniform vec2 footprint_m = vec2(1.8, 4.0);
uniform float soft_m = 0.3;
uniform float alpha = 0.5;

void fragment() {
	vec2 half_size = footprint_m * 0.5;
	vec2 p = (UV - 0.5) * (footprint_m + 2.0 * soft_m);
	vec2 q = abs(p) - (half_size - soft_m);
	float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - soft_m;
	ALBEDO = vec3(0.0);
	ALPHA = alpha * (1.0 - smoothstep(-soft_m, soft_m, dist));
}
