// The level view's tree cards: unshaded, alpha-scissored, nearest-filtered and tinted per species,
// swaying with the same wind globals as free roam's billboard trees.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest;
uniform vec4 tint : source_color = vec4(1.0);
// Pulls the leaf textures' vivid greens and bright highlights towards the muted terrain and bushes.
uniform float saturation : hint_range(0.0, 1.0) = 0.6;
uniform float contrast : hint_range(0.0, 1.0) = 0.6;
uniform float mid_grey : hint_range(0.0, 1.0) = 0.35;
// Darkens the card toward its foot: base_dark at the bottom, none from base_height (0..1 up the card) upwards.
uniform float base_dark : hint_range(0.0, 1.0) = 0.0;
uniform float base_height : hint_range(0.01, 1.0) = 0.35;
varying float ao_height;

#include "res://shaders/wind_sway.gdshaderinc"

void vertex() {
	ao_height = VERTEX.y;
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos += wind_sway_offset(origin, VERTEX.y, length(MODEL_MATRIX[1].xyz));
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
}

void fragment() {
	vec4 tex = texture(albedo, UV);
	if (tex.a < 0.5) {
		discard;
	}
	vec3 c = mix(vec3(mid_grey), tex.rgb, contrast);
	c = mix(vec3(dot(c, vec3(0.299, 0.587, 0.114))), c, saturation);
	ALBEDO = c * tint.rgb * mix(1.0 - base_dark, 1.0, smoothstep(0.0, base_height, ao_height));
}
