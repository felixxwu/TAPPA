shader_type spatial;
render_mode unshaded, specular_disabled, blend_mix, depth_draw_never, cull_back;

// Translucent variant of ps1_models_lit.gdshader, worn by the rival ghost
// (scripts/rival_ghost.gd::_ghost_material) while it is faded.
//
// WHY IT EXISTS: the ghost used to wear a plain unshaded StandardMaterial3D, which
// threw the car's fake per-vertex sun/ambient away — so the rival read as a flat,
// much LIGHTER car than the player's next to it on the start line. This keeps the
// identical lighting maths as ps1_models_lit (so the two cars sit in the same fake
// light) and only adds the one thing a StandardMaterial3D was being used for: a
// blended ALPHA. The lit shader cannot do this itself — blend/depth are render_mode,
// i.e. compile-time, so a see-through variant has to be its own shader.
//
// The FULLY OPAQUE case is not this shader: at alpha 1 rival_ghost.gd clears the
// material override entirely and the body renders with its own materials, which is
// both correctly lit and depth-writing (see _write_alpha).
//
// depth_draw_never mirrors the old DEPTH_DRAW_DISABLED: overlapping ghost panels
// (body over wheel arch) at the same alpha would otherwise punch holes in each other.

uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 texture_tile = vec2(1.0, 1.0);
// The ghost's effective opacity (rival_ghost_opacity scaled by the proximity fade).
uniform float ghost_alpha : hint_range(0.0, 1.0) = 0.4;

// Fake lighting block — same uniforms, same names and same maths as
// ps1_models_lit.gdshader, so GameConfig.apply_car_light drives it unchanged.
uniform float light_amount : hint_range(0.0, 1.0) = 1.0;
uniform vec3 light_dir = vec3(0.4, 0.9, 0.35);          // direction TO the sun
uniform vec3 sun_color : source_color = vec3(0.5);      // directional contribution
uniform vec3 sky_color : source_color = vec3(0.5);      // ambient from above
uniform vec3 ground_color : source_color = vec3(0.35);  // ambient bounce from below

varying vec3 v_light;

#include "res://shaders/headlight_cone.gdshaderinc"

void vertex() {
	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float hemi = wn.y * 0.5 + 0.5;                       // 0 below, 1 above
	vec3 ambient = mix(ground_color, sky_color, hemi);
	float ndl = max(dot(wn, normalize(light_dir)), 0.0);
	vec3 lit = ambient + sun_color * ndl;
	v_light = mix(vec3(1.0), lit, light_amount);
	v_light += hl_color * headlight_lit((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	ALBEDO = texture(albedo_texture, UV * texture_tile).rgb * albedo_color.rgb * COLOR.rgb * v_light;
	ALPHA = ghost_alpha;
}
