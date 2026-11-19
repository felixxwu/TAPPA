// The level view's ground: grass, with a gravel forestry track painted per pixel from each vertex's place on the road.
// The stones are a baked tile (tools/bake_gravel.js); only the road-shaped parts (ruts, moss, damp, edge) are worked out
// here. tools/level_editor_lab.html carries the same gravel() for its own road, so keep the two in step.
shader_type spatial;
render_mode unshaded, specular_disabled;

uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;
uniform sampler2D gravel_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform float ground_uv_per_m = 0.125;
uniform float gravel_tile_m = 6.4;

#include "res://shaders/headlight_cone.gdshaderinc"

float gh(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float gn(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(gh(i), gh(i + vec2(1.0, 0.0)), f.x), mix(gh(i + vec2(0.0, 1.0)), gh(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Where the road's edge is at this point: a little inside the half-width, by a ragged amount.
float gravel_edge(vec2 w, float half_w) { return half_w - 0.45 * gn(w * 0.9); }

// w: world xz; lat: metres across the road from its centre (signed); along: metres along it.
vec3 gravel(vec2 w, float lat, float half_w, float along) {
	float a = abs(lat + (gn(vec2(along * 0.06, 3.0)) - 0.5) * 0.35);  // the ruts wander a little
	float rut = exp(-pow((a - min(0.8, half_w * 0.42)) / 0.3, 2.0));
	float crown = 1.0 - smoothstep(0.1, 0.4, a);
	float verge = smoothstep(half_w - 1.0, half_w - 0.15, a);
	float loose = clamp(1.0 - rut * 0.9 + verge * 0.4, 0.0, 1.0);
	vec4 t = texture(gravel_texture, w / gravel_tile_m);
	float n = gn(w * 0.07);
	vec3 col = vec3(0.53, 0.5, 0.45) * (0.88 + 0.24 * n);
	col = mix(col, t.rgb, smoothstep(t.a - 0.05, t.a + 0.05, 0.15 + loose * 0.75));  // a stone shows where the ground is looser than its rank
	col *= mix(1.0, 0.86 + 0.16 * gn(vec2(along * 0.5, lat * 16.0)), rut);  // tyre-polished streaks
	col *= 1.0 - 0.3 * rut * smoothstep(0.6, 0.8, n);  // damp where water sits in the ruts
	float moss = smoothstep(0.5, 0.78, gn(w * 1.3) * (crown * 0.85 + verge * 1.15) + t.r * 0.15);
	return mix(col, vec3(0.3, 0.38, 0.2) * (0.8 + 0.4 * t.g), moss * 0.85);
}

void fragment() {
	// UV.x signed metres across the road, UV.y unsigned metres less a slack (true distance is max(|UV.x|, UV.y): the
	// sign flips between vertices far from the road, inside a bend, and UV.y keeps that seam off the road).
	// UV2 = (half-width, metres along). COLOR.rgb is the baked light and grass tint.
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float lat_abs = max(abs(UV.x), UV.y);
	float edge = gravel_edge(world.xz, UV2.x);
	float road_t = 1.0 - smoothstep(edge - 0.12, edge + 0.12, lat_abs);
	vec3 surface = texture(albedo_texture, world.xz * ground_uv_per_m).rgb;
	if (road_t > 0.0) {
		surface = mix(surface, gravel(world.xz, UV.x, UV2.x, UV2.y), road_t);
	}
	ALBEDO = surface * (COLOR.rgb + hl_color * headlight_lit(world));
}
