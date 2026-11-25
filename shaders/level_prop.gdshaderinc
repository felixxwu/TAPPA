// The body shared by level_prop.gdshader (unshaded) and level_prop_sunlit.gdshader (lit by the sun); include headlight_cone first.
uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
// Same texture drawn smooth, for the hedges' leaf texture and netting; the PS1 samplers elsewhere stay nearest (test_render_smoke exempts "linear_ok").
uniform sampler2D albedo_texture_linear : source_color, filter_linear_mipmap, repeat_enable, hint_default_white; // linear_ok
uniform bool linear_filter = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool vertex_color_is_srgb = false;
uniform float alpha_scissor = 0.0;
uniform bool backface_cull = false;

uniform float roughness = 1.0;
uniform float metallic = 0.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
}

void fragment() {
	if (backface_cull && !FRONT_FACING) {
		discard;
	}
	vec4 tex = linear_filter ? texture(albedo_texture_linear, UV) : texture(albedo_texture, UV);
	vec3 vc = vertex_color_is_srgb ? srgb_to_linear(COLOR.rgb) : COLOR.rgb;
	vec4 col = tex * albedo_color * vec4(vc, COLOR.a);
	if (alpha_scissor > 0.0 && col.a < alpha_scissor) {
		discard;
	}
	vec3 light = world_light + hl_color * headlight_lit(world_pos) + flash_lit(world_pos);
#ifdef SUNLIT
	// lit by the level's sun, so the lamps go in as emission and stay bright when the world is dark
	ALBEDO = col.rgb * world_light;
	EMISSION = col.rgb * (light - world_light);
	ROUGHNESS = roughness;
	METALLIC = metallic;
#else
	ALBEDO = col.rgb * light;
#endif
}
