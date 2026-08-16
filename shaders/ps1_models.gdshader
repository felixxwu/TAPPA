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

// Fake headlight cone (night weather). Fragment-side here — NOT a vertex stage:
// terrain cells reach 25 m across at the coarsest LOD, so a per-vertex cone would
// snap its edge to triangles, and this shader is deliberately kept free of any
// vertex stage (test_render_smoke.gd::test_terrain_shader_has_no_vertex_stage).
// The include declares only global uniforms and one function, so that ban holds.
#include "res://shaders/headlight_cone.gdshaderinc"

void fragment() {
	// Ground (e.g. grass) vs. road, cross-faded per-fragment by the road weight the
	// terrain bakes into the vertex-colour alpha channel (COLOR.a: 1.0 on the road,
	// ramping to 0.0 off it). The road itself is gravel (road_texture) faded to the
	// flat tarmac colour by the per-vertex tarmac weight in UV2.x (0 = gravel, 1 =
	// tarmac), feathered across the gravel↔tarmac switch the same way. COLOR.rgb
	// stays a plain ground tint × baked light (white by default).
	float road_t = blend_road ? COLOR.a : 0.0;
	float tarmac_t = blend_road ? UV2.x : 0.0;
	vec3 ground = texture(albedo_texture, UV * texture_tile).rgb;
	vec3 gravel = texture(road_texture, UV * texture_tile * road_uv_scale).rgb;
	vec3 road = mix(gravel, tarmac_color.rgb, tarmac_t);
	// Surface and light are kept separate so the headlight can ADD to the light
	// term. It must not multiply: at night COLOR.rgb is baked near-black, and
	// scaling near-black by a bright cone is still near-black. World position comes
	// from INV_VIEW_MATRIX because there is no vertex stage to hand one down; view
	// space would be cheaper but the globals are camera-agnostic and the game has
	// several cameras (BonnetCamera, ChaseCamera, replay cams).
	vec3 surface = mix(ground, road, road_t) * albedo_color.rgb;
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ALBEDO = surface * (COLOR.rgb + hl_color * headlight_lit(world_pos));
}
