shader_type spatial;
render_mode unshaded, specular_disabled;

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

// --- Spatial REGION blending (overworld only; see features/overworld.md -> "Region blending").
// Off by default, and a stage never writes UV2.y, so with blend_region false every mix below
// takes its A term unchanged and a stage renders bit-for-bit as it did before this existed.
//
// UV2.y carries a baked, pair-INDEPENDENT 0..1 region RANK (TerrainManager._apply_region_blend).
// That is what makes the transition land on the FIXED boundary line on the ground ahead of the car
// instead of repainting the whole world when the car crosses it.
//
// TWO PATHS DECODE IT, and the split is deliberate:
//   - COLOUR (ground tint + tarmac) goes through the rank->look LUT below, which holds EVERY
//     region. A visible chunk can belong to any region, not just one of the two nearest the car,
//     so a two-slot decode painted distant ground with the wrong region's colours and changed its
//     mind as the car drove (the "wrong colours across a boundary" bug).
//   - the ground TEXTURE stays a two-slot cross-fade (albedo_texture / albedo_texture_b), because
//     a texture sampler cannot live in a plain uniform array. Distant ground wears a near
//     region's grass under the CORRECT tint. Accepted: tint carries almost all of the read at
//     distance, and both paths agree exactly at each region's own rank (the LUT evaluates to that
//     region's authored tint there), so the near pair never disagrees with the LUT.
// Slot A is the uniforms above (albedo_texture / albedo_color / tarmac_color), slot B the ones
// here; region_rank_a / region_rank_b are the ranks of the two uploaded regions, so inverse-lerping
// the baked rank between them recovers the 0..1 A->B factor for the texture fade.
uniform bool blend_region = false;
uniform sampler2D albedo_texture_b : source_color, filter_nearest, hint_default_white;
uniform vec4 albedo_color_b : source_color = vec4(1.0);
uniform vec4 tarmac_color_b : source_color = vec4(0.32, 0.32, 0.34, 1.0);
uniform float region_rank_a = 0.0;
uniform float region_rank_b = 1.0;
// Fraction of the rank span the visible cross-fade occupies, centred on the boundary. Small =
// a crisp line, 1.0 = a gradient across the whole span. GameConfig.overworld_region_blend_width.
uniform float region_blend_width = 0.35;

// The 0..1 slot-A -> slot-B factor for this fragment. Zero (and therefore an exact no-op in
// every mix) whenever the feature is off or the two uploaded regions share a rank, which is the
// "the car is deep inside one region, there is no second region to blend to" case.
float region_blend_t(float baked_rank) {
	if (!blend_region) {
		return 0.0;
	}
	float span = region_rank_b - region_rank_a;
	if (abs(span) < 0.0001) {
		return 0.0;
	}
	float raw = clamp((baked_rank - region_rank_a) / span, 0.0, 1.0);
	float w = max(region_blend_width, 0.0001);
	return smoothstep(0.0, 1.0, clamp((raw - 0.5) / w + 0.5, 0.0, 1.0));
}

// --- The rank -> look LUT: EVERY region's colours, uploaded once (Overworld._push_region_lut).
// region_rank[] is ASCENDING (RegionBlendSource assigns rank by sorted id, so entry i's rank is
// i/(n-1)); region_tint[i] / region_tarmac[i] are that region's authored look. region_count is 0
// whenever the LUT is not in use — every stage, and the overworld before the first push — and the
// fragment stage then falls back to the A/B uniforms unchanged, so a stage is bit-for-bit as before.
const int REGION_LUT_MAX = 8;
uniform vec4 region_tint[REGION_LUT_MAX] : source_color;
uniform vec4 region_tarmac[REGION_LUT_MAX] : source_color;
uniform float region_rank[REGION_LUT_MAX];
uniform int region_count = 0;

// The tint and tarmac colour for a baked rank, interpolated between the two LUT entries that
// bracket it with the same feathered ramp region_blend_t uses (so the LUT and the two-slot texture
// fade change over the same band). Below the first rank / above the last it clamps to that entry.
void region_lut_look(float baked_rank, out vec4 tint, out vec4 tarmac) {
	tint = region_tint[0];
	tarmac = region_tarmac[0];
	int n = min(region_count, REGION_LUT_MAX);
	float w = max(region_blend_width, 0.0001);
	for (int i = 0; i + 1 < REGION_LUT_MAX; i++) {
		if (i + 1 >= n) {
			break;
		}
		float lo = region_rank[i];
		float hi = region_rank[i + 1];
		if (baked_rank <= lo) {
			break;
		}
		float raw = clamp((baked_rank - lo) / max(hi - lo, 0.0001), 0.0, 1.0);
		float t = smoothstep(0.0, 1.0, clamp((raw - 0.5) / w + 0.5, 0.0, 1.0));
		tint = mix(region_tint[i], region_tint[i + 1], t);
		tarmac = mix(region_tarmac[i], region_tarmac[i + 1], t);
		if (baked_rank < hi) {
			break;
		}
	}
}

// Fake headlight cone (night weather). Fragment-side here — NOT a vertex stage:
// terrain cells reach 25 m across at the coarsest LOD, so a per-vertex cone would
// snap its edge to triangles, and this shader is deliberately kept free of any
// vertex stage (test_render_smoke.gd::test_terrain_shader_has_no_vertex_stage).
// The include declares only global uniforms and one function, so that ban holds.
#include "res://shaders/headlight_cone.gdshaderinc"
// Overworld fog of war (features/overworld.md). Also fragment-side, also global-uniform
// transport, and a bit-for-bit no-op in every scene that is not the overworld.
#include "res://shaders/overworld_fog.gdshaderinc"

void fragment() {
	// Ground (e.g. grass) vs. road, cross-faded per-fragment by the road weight the
	// terrain bakes into the vertex-colour alpha channel (COLOR.a: 1.0 on the road,
	// ramping to 0.0 off it). The road itself is gravel (road_texture) faded to the
	// flat tarmac colour by the per-vertex tarmac weight in UV2.x (0 = gravel, 1 =
	// tarmac), feathered across the gravel↔tarmac switch the same way. COLOR.rgb
	// stays a plain ground tint × baked light (white by default).
	float road_t = blend_road ? COLOR.a : 0.0;
	float tarmac_t = blend_road ? UV2.x : 0.0;
	// Region cross-fade, spatially. The ground TEXTURE slides from slot A to slot B (two samplers,
	// the pair nearest the car); the ground TINT and the tarmac colour come from the all-regions
	// LUT, so a chunk belonging to a third region still paints in its OWN colours. The GRAVEL
	// sampler is deliberately not doubled — the road is a thin ribbon and a second road sampler
	// would cost a texture unit for something a few metres wide; accepted limitation.
	float region_t = region_blend_t(UV2.y);
	vec4 tint = albedo_color;
	vec4 tarmac = tarmac_color;
	if (blend_region && region_count > 1) {
		region_lut_look(UV2.y, tint, tarmac);
	} else if (blend_region) {
		tint = mix(albedo_color, albedo_color_b, region_t);
		tarmac = mix(tarmac_color, tarmac_color_b, region_t);
	}
	vec3 ground = mix(texture(albedo_texture, UV * texture_tile).rgb,
		texture(albedo_texture_b, UV * texture_tile).rgb, region_t);
	vec3 gravel = texture(road_texture, UV * texture_tile * road_uv_scale).rgb;
	vec3 road = mix(gravel, tarmac.rgb, tarmac_t);
	// Surface and light are kept separate so the headlight can ADD to the light
	// term. It must not multiply: at night COLOR.rgb is baked near-black, and
	// scaling near-black by a bright cone is still near-black. World position comes
	// from INV_VIEW_MATRIX because there is no vertex stage to hand one down; view
	// space would be cheaper but the globals are camera-agnostic and the game has
	// several cameras (BonnetCamera, ChaseCamera, replay cams).
	vec3 surface = mix(ground, road, road_t) * tint.rgb;
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Fog-of-war darkening MULTIPLIES the finished light term, unlike the headlight which adds
	// to it: unexplored ground is meant to go dark whatever is lighting it, headlights
	// included, so a player cannot simply drive up to the frontier and light it up.
	ALBEDO = surface * (COLOR.rgb + hl_color * headlight_lit(world_pos))
		* overworld_fog_at(world_pos);
}
