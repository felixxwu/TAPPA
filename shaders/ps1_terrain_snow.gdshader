shader_type spatial;
render_mode unshaded, specular_disabled;

// DEEP-SNOW TERRAIN VARIANT of ps1_models.gdshader (features/snow-region.md).
//
// Identical to that shader except for the vertex stage just above fragment(), which raises the
// ground off-road so the car visibly sinks into the snow. Props are NOT lifted to match: the
// trees, bushes and rocks are seated on the collision height, so they read as buried in it.
//
// WHY A SEPARATE SHADER, and not a `snow_depth` uniform on ps1_models itself:
// ps1_models is the shared TERRAIN shader, and terrain is the heaviest geometry in the
// game on a renderer that targets low-end phones. It is deliberately kept free of any vertex
// stage at all, enforced by test_render_smoke.gd::test_terrain_shader_has_no_vertex_stage.
// The variant puts the cost only where the feature is used: free roam's snow ring
// (TerrainStreamer._material_for) and a snow stage (WorldRuntime.apply_deep_snow).
//
// EVERYTHING BUT THE VERTEX STAGE IS A COPY of ps1_models.gdshader. Change the two together;
// test_render_smoke.gd::test_snow_terrain_shader_matches_the_base_shader fails when the
// uniforms or the fragment stage drift apart.

uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;
uniform sampler2D road_texture : source_color, filter_nearest, hint_default_white;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 texture_tile = vec2(1.0, 1.0);
// Terrain-only road blend. Off by default so meshes that share this shader but
// carry no vertex-colour array (the car, the MX-5 body) — whose COLOR defaults
// to opaque white — keep sampling albedo_texture and are unaffected.
uniform bool blend_road = false;
// Road texture tiling relative to the ground texture (road_tile_per_meter /
// terrain_tile_per_meter). 1.0 = same density as the ground; higher = finer.
uniform float road_uv_scale = 1.0;
// Flat tarmac fill colour. TODO: replace with a proper tarmac texture (a second
// road sampler) — for now tarmac sections are a solid grey that still picks up the
// baked terrain lighting in COLOR.rgb. See todo/tarmac-texture.md.
uniform vec4 tarmac_color : source_color = vec4(0.32, 0.32, 0.34, 1.0);

// --- Per-pixel road paint (free roam; TerrainStreamer._arrays). Off by default, so a stage
// keeps its per-vertex COLOR.a road weight. On, the road is painted per FRAGMENT from the
// distance to the road the vertices carry, so its edge is a smooth line rather than following
// the (2 m, or 16 m far away) mesh triangles. The vertex channels mean something else then:
//   UV.x  signed distance to the road (side by sign), UV.y  unsigned distance less a per-mesh
//   slack (the road distance is max(|UV.x|, UV.y)), UV2.x  tarmac weight, UV2.y  arc length
//   along the road, COLOR.a  lane-marking weight. The ground texture is placed from the world
//   position instead of UV (ground_uv_per_m).
uniform bool paint_road_per_pixel = false;
uniform float ground_uv_per_m = 0.125;
// RoadTerrain.paint_weight, per pixel: 1 inside road_paint_mid_m - road_paint_half_m, 0 beyond
// road_paint_mid_m + road_paint_half_m, smoothstep between.
uniform float road_paint_mid_m = 2.4;
uniform float road_paint_half_m = 0.5;
// Lane paint on tarmac: two solid edge lines road_marking_edge_m out from the centre and a
// dashed centre line, road_marking_width_m wide. Strength 0 turns them off (a region without
// markings).
uniform float road_marking_strength = 0.0;
uniform vec4 road_marking_color : source_color = vec4(0.82, 0.82, 0.78, 1.0);
uniform float road_marking_width_m = 0.12;
uniform float road_marking_edge_m = 1.5;
uniform float road_marking_dash_m = 1.5;
uniform float road_marking_gap_m = 3.0;

// --- Biome border fade (free roam; TerrainStreamer._pair_material). Only chunks that touch a
// border turn this on. Slot A (the uniforms above) is the inner ring, slot B (the _b uniforms) the
// outer one, and each pixel works out how far out it is in rings exactly as RoadTerrain.ring_coord
// does, so the fade follows the true wobbly border and lines up across chunk edges.
uniform bool fade_rings = false;
uniform sampler2D road_texture_b : source_color, filter_nearest, hint_default_white;
uniform vec4 road_marking_color_b : source_color = vec4(0.82, 0.82, 0.78, 1.0);
uniform float ring_border = 1.0;
uniform float ring_half = 0.01;
uniform float ring_scale_m = 1000.0;
uniform float ring_count = 1.0;
uniform int ring_seed = 0;

// LabNoise.vnoise in 32-bit unsigned maths, which wraps exactly like the CPU's masked ints.
float ring_corner(int x, int y, uint hs) {
	uint h = (uint(x) * 374761393u) ^ (uint(y) * 668265263u) ^ hs;
	h = (h ^ (h >> 13u)) * 1274126177u;
	return float(h ^ (h >> 16u)) / 4294967296.0;
}

float ring_vnoise(vec2 p, int s) {
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * (3.0 - 2.0 * f);
	int ix = int(i.x);
	int iy = int(i.y);
	uint hs = uint(s) * 2147483647u;
	float a = ring_corner(ix, iy, hs);
	float b = ring_corner(ix + 1, iy, hs);
	float c = ring_corner(ix, iy + 1, hs);
	float d = ring_corner(ix + 1, iy + 1, hs);
	return a + (b - a) * u.x + (c - a) * u.y + (a - b - c + d) * u.x * u.y;
}

float ring_coord_at(vec2 p) {
	vec2 q = p / 1500.0 + 9.0;
	float fbm = ring_vnoise(q, ring_seed) * 0.6 + ring_vnoise(q * 2.1, ring_seed + 7) * 0.3
		+ ring_vnoise(q * 4.3, ring_seed + 13) * 0.1;
	return (length(p) / ring_scale_m + (fbm - 0.5) * 0.25) * ring_count;
}

// Slot B of the free-roam ring fade (see fade_rings above): the outer ring's ground look.
uniform sampler2D albedo_texture_b : source_color, filter_nearest, hint_default_white;
uniform vec4 albedo_color_b : source_color = vec4(1.0);
uniform vec4 tarmac_color_b : source_color = vec4(0.32, 0.32, 0.34, 1.0);

// Fake headlight cone (night weather). Fragment-side here — NOT a vertex stage:
// terrain cells reach 25 m across at the coarsest LOD, so a per-vertex cone would
// snap its edge to triangles, and this shader is deliberately kept free of any
// vertex stage (test_render_smoke.gd::test_terrain_shader_has_no_vertex_stage).
// The include declares only global uniforms and one function, so that ban holds.
#include "res://shaders/headlight_cone.gdshaderinc"


// --- Deep snow. Metres the VISIBLE ground sits above the collision surface off-road.
// Collision is a separate HeightMapShape3D and is untouched, so the wheels still rest at true
// ground level; car.gd's deep-snow drag is what makes it read as ploughing. snow_depth_b is the
// outer ring's depth at a free-roam biome border (fade_rings), faded exactly like its textures,
// so the lift meets the single-ring chunks on either side without a step.
uniform float snow_depth = 0.0;
uniform float snow_depth_b = 0.0;
// Free roam only: how far past the painted road edge the ground takes to rise to full depth.
uniform float snow_bank_m = 2.0;

void vertex() {
	// Off-road weight: 0 on the road (never lifted), ramping to 1 away from it, which reads as a
	// plough bank at the verge. Free roam bakes the distance to the road into UV (see
	// paint_road_per_pixel), and the bank starts where the paint ends. A stage bakes its road
	// weight into COLOR.a, whose smoothstep feather does the ramping.
	float off_road = 1.0;
	if (blend_road && paint_road_per_pixel) {
		float d = max(abs(UV.x), UV.y);
		float edge = road_paint_mid_m + road_paint_half_m;
		off_road = smoothstep(edge, edge + snow_bank_m, d);
	} else if (blend_road) {
		off_road = 1.0 - COLOR.a;
	}
	float depth = snow_depth;
	if (fade_rings) {
		vec2 xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
		depth = mix(snow_depth, snow_depth_b, smoothstep(-ring_half, ring_half, ring_coord_at(xz) - ring_border));
	}
	VERTEX.y += depth * off_road;
}

void fragment() {
	// Ground (e.g. grass) vs. road, cross-faded per-fragment by the road weight the
	// terrain bakes into the vertex-colour alpha channel (COLOR.a: 1.0 on the road,
	// ramping to 0.0 off it). The road itself is gravel (road_texture) faded to the
	// flat tarmac colour by the per-vertex tarmac weight in UV2.x (0 = gravel, 1 =
	// tarmac), feathered across the gravel↔tarmac switch the same way. COLOR.rgb
	// stays a plain ground tint × baked light (white by default).
	float road_t = blend_road ? COLOR.a : 0.0;
	float tarmac_t = blend_road ? UV2.x : 0.0;
	vec2 ground_uv = UV;
	float lines = 0.0;
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (blend_road && paint_road_per_pixel) {
		ground_uv = world_pos.xz * ground_uv_per_m;
		float d = max(abs(UV.x), UV.y);
		road_t = 1.0 - smoothstep(road_paint_mid_m - road_paint_half_m, road_paint_mid_m + road_paint_half_m, d);
		// A line's coverage, softened over one pixel's worth of distance so it doesn't crawl.
		float aa = max(fwidth(d), 0.001);
		float hw = road_marking_width_m * 0.5;
		float edge = 1.0 - smoothstep(hw - aa, hw + aa, abs(d - road_marking_edge_m));
		float centre = 1.0 - smoothstep(hw - aa, hw + aa, d);
		float period = max(road_marking_dash_m + road_marking_gap_m, 0.01);
		centre *= step(mod(UV2.y, period), road_marking_dash_m);
		lines = max(edge, centre) * road_marking_strength * smoothstep(0.4, 0.6, COLOR.a)
			* smoothstep(0.4, 0.6, tarmac_t);
	}
	float region_t = 0.0;
	vec4 tint = albedo_color;
	vec4 tarmac = tarmac_color;
	vec4 marking = road_marking_color;
	if (fade_rings) {
		region_t = smoothstep(-ring_half, ring_half, ring_coord_at(world_pos.xz) - ring_border);
		tint = mix(albedo_color, albedo_color_b, region_t);
		tarmac = mix(tarmac_color, tarmac_color_b, region_t);
		marking = mix(road_marking_color, road_marking_color_b, region_t);
	}
	vec3 ground = mix(texture(albedo_texture, ground_uv * texture_tile).rgb,
		texture(albedo_texture_b, ground_uv * texture_tile).rgb, region_t);
	vec3 gravel = texture(road_texture, ground_uv * texture_tile * road_uv_scale).rgb;
	if (fade_rings) {
		gravel = mix(gravel, texture(road_texture_b, ground_uv * texture_tile * road_uv_scale).rgb, region_t);
	}
	vec3 road = mix(gravel, tarmac.rgb, tarmac_t);
	// Surface and light are kept separate so the headlight can ADD to the light
	// term. It must not multiply: at night COLOR.rgb is baked near-black, and
	// scaling near-black by a bright cone is still near-black. World position comes
	// from INV_VIEW_MATRIX because there is no vertex stage to hand one down; view
	// space would be cheaper but the globals are camera-agnostic and the game has
	// several cameras (BonnetCamera, ChaseCamera, replay cams).
	vec3 surface = mix(ground, road, road_t) * tint.rgb;
	// lane paint keeps its own colour rather than taking the ground tint
	surface = mix(surface, marking.rgb, lines * road_t);
	ALBEDO = surface * (COLOR.rgb + hl_color * headlight_lit(world_pos));
}
