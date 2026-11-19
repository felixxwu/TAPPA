// The level view's ground: grass, with a gravel forestry track painted per pixel from the baked road frame textures (scripts/level_bake.gd).
// The stones are a baked tile (tools/bake_gravel.js); only the road-shaped parts (ruts, moss, damp, edge) are worked out
// here. tools/level_editor_lab.html carries the same gravel() for its own road, so keep the two in step.
shader_type spatial;
render_mode unshaded, specular_disabled;

uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;
uniform sampler2D gravel_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform float ground_uv_per_m = 0.125;
uniform float gravel_tile_m = 6.4;
// The road frame, one RGBA8 texture read nearest and filtered by hand: across (signed), half-width, along (modulo 64 m), junction weight.
uniform sampler2D road_frame : filter_nearest, hint_default_black;
uniform float frame_size_m = 600.0;
uniform float frame_cell_m = 1.0;
uniform int frame_n = 1;
const float FRAME_RANGE = 16.0;
const float ALONG_PERIOD = 64.0;

#include "res://shaders/headlight_cone.gdshaderinc"

float gh(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float gn(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(gh(i), gh(i + vec2(1.0, 0.0)), f.x), mix(gh(i + vec2(0.0, 1.0)), gh(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Same noise with its x lattice repeating every `per` cells, so the stored-modulo-64 along coordinate has no seam.
float gnp(vec2 p, float per) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float x0 = mod(i.x, per), x1 = mod(i.x + 1.0, per);
	return mix(mix(gh(vec2(x0, i.y)), gh(vec2(x1, i.y)), f.x), mix(gh(vec2(x0, i.y + 1.0)), gh(vec2(x1, i.y + 1.0)), f.x), f.y);
}

// Where the road's edge is at this point: a little inside the half-width, by a ragged amount.
float gravel_edge(vec2 w, float half_w) { return half_w - 0.45 * gn(w * 0.9); }

// w: world xz; lat: metres across the road from its centre (signed); along: metres along it; junc: 1 on a junction's
// pad, where the across/along masks fade to an even driven-gravel pad so the frames of different roads leave no seam.
vec3 gravel(vec2 w, float lat, float half_w, float along, float junc) {
	float a = abs(lat + (gnp(vec2(along * 0.0625, 3.0), 4.0) - 0.5) * 0.35);  // the ruts wander a little
	float rut = mix(exp(-pow((a - min(0.8, half_w * 0.42)) / 0.3, 2.0)), 0.12, junc);
	float crown = (1.0 - smoothstep(0.1, 0.4, a)) * (1.0 - junc);
	float verge = smoothstep(half_w - 1.0, half_w - 0.15, a) * (1.0 - junc);
	float loose = clamp(1.0 - rut * 0.9 + verge * 0.4, 0.0, 1.0);
	vec4 t = texture(gravel_texture, w / gravel_tile_m);
	float n = gn(w * 0.07);
	vec3 col = vec3(0.53, 0.5, 0.45) * (0.88 + 0.24 * n);
	col = mix(col, t.rgb, smoothstep(t.a - 0.05, t.a + 0.05, 0.15 + loose * 0.75));  // a stone shows where the ground is looser than its rank
	col *= mix(1.0, 0.86 + 0.16 * gnp(vec2(along * 0.5, lat * 16.0), 32.0), rut * (1.0 - junc));  // tyre-polished streaks
	col *= 1.0 - 0.3 * rut * (1.0 - junc) * smoothstep(0.6, 0.8, n);  // damp where water sits in the ruts
	float moss = smoothstep(0.5, 0.78, gn(w * 1.3) * (crown * 0.85 + verge * 1.15) + t.r * 0.15);
	return mix(col, vec3(0.3, 0.38, 0.2) * (0.8 + 0.4 * t.g), moss * 0.85);
}

void fragment() {
	// The frame texel grid starts at the square's corner; the four texels round a point are blended by hand.
	// Across is blended signed where the four values change by about one texel gradient (a plain slope, or the straight crossing of one road's centreline);
	// elsewhere (between two roads, where the sign flips far from any centreline) |across| is blended with the nearest texel's sign, so no road is faked.
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 u = (world.xz + frame_size_m * 0.5) / frame_cell_m;
	ivec2 i0 = ivec2(floor(u));
	vec2 f = fract(u);
	ivec2 hi = ivec2(frame_n - 1);
	float signed_across = 0.0, dist = 0.0, half_w = 0.0, junc = 0.0, along = 0.0, ref_along = 0.0, nearest_across = 0.0;
	float lo_a = 1e9, hi_a = -1e9;
	for (int k = 0; k < 4; k++) {
		ivec2 o = ivec2(k & 1, k >> 1);
		vec4 t = texelFetch(road_frame, clamp(i0 + o, ivec2(0), hi), 0);
		float w = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
		float across = t.r * 2.0 * FRAME_RANGE - FRAME_RANGE;
		float al = t.b * ALONG_PERIOD;
		if (k == 0) {
			ref_along = al;
		}
		lo_a = min(lo_a, across);
		hi_a = max(hi_a, across);
		signed_across += w * across;
		dist += w * abs(across);
		half_w += w * t.g * FRAME_RANGE;
		junc += w * t.a;
		along += w * (mod(al - ref_along + ALONG_PERIOD * 0.5, ALONG_PERIOD) - ALONG_PERIOD * 0.5);
		if ((o.x == 1) == (f.x > 0.5) && (o.y == 1) == (f.y > 0.5)) {
			nearest_across = across;
		}
	}
	along += ref_along;
	bool smooth_field = hi_a - lo_a <= frame_cell_m * 1.5;
	float lat = smooth_field ? signed_across : (nearest_across >= 0.0 ? dist : -dist);
	if (smooth_field) {
		dist = abs(signed_across);
	}
	float edge = gravel_edge(world.xz, half_w);
	float road_t = 1.0 - smoothstep(edge - 0.12, edge + 0.12, dist);
	vec3 surface = texture(albedo_texture, world.xz * ground_uv_per_m).rgb;
	if (road_t > 0.0) {
		surface = mix(surface, gravel(world.xz, lat, half_w, along, junc), road_t);
	}
	// grass pushed toward lime, fading out over the few metres round the road's edge; COLOR.rgb is only the baked sun light and cover tint
	vec3 grass = mix(vec3(0.97, 1.1, 0.86), vec3(1.0), 1.0 - smoothstep(-1.0, 2.0, dist - half_w));
	ALBEDO = surface * (COLOR.rgb * grass + hl_color * headlight_lit(world));
	if (UV2.x < -0.5) {
		// a skirt: one flat colour per 8 m of its length, never the ground texture stretched down its face
		ALBEDO = texture(albedo_texture, (floor(world.xz / 8.0) + 0.5) * 8.0 * ground_uv_per_m).rgb * (COLOR.rgb + hl_color * headlight_lit(world));
	}
}
