// The level view's tree cards: unshaded, alpha-scissored, nearest-filtered and tinted per species,
// swaying with the same wind globals as free roam's billboard trees.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest;
uniform vec4 tint : source_color = vec4(1.0);

#include "res://shaders/wind_sway.gdshaderinc"

void vertex() {
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
	ALBEDO = tex.rgb * tint.rgb;
}
