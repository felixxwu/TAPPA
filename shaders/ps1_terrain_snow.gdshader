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
	vec3 ground = texture(albedo_texture, UV * texture_tile).rgb;
	vec3 gravel = texture(road_texture, UV * texture_tile * road_uv_scale).rgb;
	vec3 road = mix(gravel, tarmac_color.rgb, tarmac_t);
	ALBEDO = mix(ground, road, road_t) * albedo_color.rgb * COLOR.rgb;
}
