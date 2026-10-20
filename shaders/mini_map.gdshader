// Free roam's minimap ground (scripts/free_roam/mini_map.gd, features/minimap.md).
// Shows the flat, heading-up map texture as a ground plane tilted away from the viewer, the way
// navigation software draws roads: a projective (perspective) map from the screen to the ground,
// so the far edge (top) is narrower and compressed and the near edge (bottom) is full size.
// MiniMap.ground_of / screen_of are the GDScript twins of `ground` below: keep them in step.
shader_type canvas_item;

uniform sampler2D map_tex : filter_nearest, repeat_disable;
// The ground's frame inside this rect, in UV: (x0, y0, x1, y1). The rest is room for the shadow.
uniform vec4 inner = vec4(0.0, 0.0, 1.0, 1.0);
// 1 / (1 + tilt): how wide the near edge looks next to the far edge's ground.
uniform float near_frac = 0.4;
uniform vec4 bg_color : source_color = vec4(0.0, 0.0, 0.0, 0.55);
uniform vec4 rim_color : source_color = vec4(1.0, 0.99, 0.83, 0.5);
uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.3);
// The hard drop shadow's offset, in UV of this rect.
uniform vec2 shadow_uv = vec2(0.01, 0.04);
uniform float corner = 0.06;
uniform float rim_w = 0.01;
uniform float far_fade = 0.35;
uniform float side_fade = 0.08;
// The near (bottom) edge fades out too, so the map has no hard line along its bottom.
uniform float near_fade = 0.12;

// Screen (the ground frame's UV, y down) to ground (the map texture's UV).
vec2 ground(vec2 uv) {
	vec2 f = (uv - inner.xy) / (inner.zw - inner.xy);
	float den = near_frac + (1.0 - near_frac) * f.y;
	return vec2(0.5 + (f.x - 0.5) / den, f.y / den);
}

float box_sd(vec2 g) {
	vec2 q = abs(g - 0.5) - vec2(0.5 - corner);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;
}

float edge_fade(vec2 g) {
	return smoothstep(0.0, far_fade, g.y) * smoothstep(0.0, near_fade, 1.0 - g.y)
		* smoothstep(0.0, side_fade, g.x) * smoothstep(0.0, side_fade, 1.0 - g.x);
}

void fragment() {
	vec2 g = ground(UV);
	float d = box_sd(g);
	float aa = max(fwidth(d), 1e-4);
	float inside = 1.0 - smoothstep(-aa, aa, d);
	float rim = inside * smoothstep(-rim_w - aa, -rim_w + aa, d);
	// The viewport renders over a transparent clear, so its colour is premultiplied.
	vec4 m = texture(map_tex, clamp(g, 0.0, 1.0));
	vec3 col = bg_color.rgb * (1.0 - m.a) + m.rgb;
	float a = max(bg_color.a, m.a);
	col = mix(col, rim_color.rgb, rim * rim_color.a);
	a = max(a, rim * rim_color.a);
	a *= inside * edge_fade(g);
	vec2 gs = ground(UV - shadow_uv);
	float sh = (1.0 - smoothstep(-aa, aa, box_sd(gs))) * edge_fade(gs) * shadow_color.a;
	float out_a = a + sh * (1.0 - a);
	vec3 out_c = (col * a + shadow_color.rgb * sh * (1.0 - a)) / max(out_a, 1e-4);
	COLOR = vec4(out_c, out_a);
}
