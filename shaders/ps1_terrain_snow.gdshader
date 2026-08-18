shader_type spatial;
render_mode unshaded, specular_disabled;

// DEEP-SNOW TERRAIN VARIANT of ps1_models.gdshader (features/snow-region.md).
//
// Identical to that shader except for the vertex stage at the bottom, which raises the
// ground off-road so the car visibly sinks into the snow.
//
// WHY A SEPARATE SHADER, and not a `snow_depth` uniform on ps1_models itself:
// ps1_models is the shared TERRAIN shader, and terrain is the heaviest geometry in the
// game (tens of thousands of vertices in the loaded chunk ring) on a renderer that
// targets low-end phones. It is deliberately kept free of any vertex stage at all, and
// that ban is enforced by
// test_render_smoke.gd::test_terrain_shader_has_no_vertex_stage. The established answer
// in this codebase is a variant shader — exactly what ps1_models_lit.gdshader already
// is for the car's fake lighting — so the cost lands only where the feature is used.
// world.gd swaps the floor material onto this shader only on a snow stage.
//
// KEEP THE FRAGMENT STAGE IN SYNC with ps1_models.gdshader. The duplication is the
// price of the split; test_render_smoke asserts both stay unshaded and both keep the
// blend_road gate, so a divergence that matters is caught.

uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;
uniform sampler2D road_texture : source_color, filter_nearest, hint_default_white;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 texture_tile = vec2(1.0, 1.0);
uniform bool blend_road = false;
uniform float road_uv_scale = 1.0;
uniform vec4 tarmac_color : source_color = vec4(0.32, 0.32, 0.34, 1.0);
// Metres the VISUAL ground sits above the collision surface off-road. Collision is a
// separate HeightMapShape3D and is untouched, so the wheels still rest at true ground
// level and only the appearance changes — paired with car.gd's deep-snow drag, which
// is what stops the car looking like it is floating through the drift.
uniform float snow_depth = 0.0;

// Spatial region blending — kept in sync with ps1_models.gdshader, see the note above. The Alps
// are a map corner and the overworld swaps to THIS shader there, so the ground must be able to
// blend into its neighbouring region here too or the boundary would snap on snow. Off by
// default; a stage never writes UV2.y, so a snow STAGE is bit-for-bit unchanged.
uniform bool blend_region = false;
uniform sampler2D albedo_texture_b : source_color, filter_nearest, hint_default_white;
uniform vec4 albedo_color_b : source_color = vec4(1.0);
uniform vec4 tarmac_color_b : source_color = vec4(0.32, 0.32, 0.34, 1.0);
uniform float region_rank_a = 0.0;
uniform float region_rank_b = 1.0;
uniform float region_blend_width = 0.35;

// Identical to ps1_models.gdshader::region_blend_t — see its comment for what the rank is.
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

// The all-regions rank -> look LUT — identical to ps1_models.gdshader::region_lut_look, see the
// comments there. Colour (tint + tarmac) comes from here for EVERY region; only the ground TEXTURE
// stays a two-slot fade, because a texture sampler cannot live in a plain uniform array.
const int REGION_LUT_MAX = 8;
uniform vec4 region_tint[REGION_LUT_MAX] : source_color;
uniform vec4 region_tarmac[REGION_LUT_MAX] : source_color;
uniform float region_rank[REGION_LUT_MAX];
uniform int region_count = 0;

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

// Kept in sync with ps1_models.gdshader — see the note above. Uniform-set parity
// between the two is load-bearing: world.gd::_apply_deep_snow_ground swaps the
// floor material between them and re-applies only snow_depth, relying on
// ShaderMaterial keeping its by-name parameter map across the swap. These are
// GLOBAL uniforms rather than material parameters, so they survive the swap
// regardless — but the fragment maths must still match or a snow stage would light
// differently from a dry one.
#include "res://shaders/headlight_cone.gdshaderinc"
// Overworld fog of war (features/overworld.md). The Alps are a map corner, so the overworld
// swaps to THIS shader there — it needs the same darkening or the frontier would vanish on snow.
#include "res://shaders/overworld_fog.gdshaderinc"

void vertex() {
	// Raise off-road only. COLOR.a is the baked road weight the fragment stage blends
	// with (1.0 on the road, ramping to 0.0 off it), so the road is never lifted and
	// the existing smoothstep feather turns what would be a step into a ramp — which
	// reads as a plough bank at the verge.
	VERTEX.y += snow_depth * (1.0 - (blend_road ? COLOR.a : 0.0));
}

void fragment() {
	// Kept identical to ps1_models.gdshader — see the note above.
	float road_t = blend_road ? COLOR.a : 0.0;
	float tarmac_t = blend_road ? UV2.x : 0.0;
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
	vec3 surface = mix(ground, road, road_t) * tint.rgb;
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Multiplies the finished light term — see the note in ps1_models.gdshader.
	ALBEDO = surface * (COLOR.rgb + hl_color * headlight_lit(world_pos))
		* overworld_fog_at(world_pos);
}
