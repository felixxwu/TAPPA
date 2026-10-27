// The money dropped at a wreck (LootDirector._sync_dropped_node): a crystal that bobs up and down
// over the spot until the car drives back to it.
shader_type spatial;
render_mode cull_disabled;

uniform vec4 color : source_color = vec4(1.0);
uniform float bob_m = 0.25;
uniform float bob_period_s = 2.2;

varying float v_headlight;

#include "res://shaders/headlight_cone.gdshaderinc"

void vertex() {
	VERTEX.y += sin(TIME * TAU / bob_period_s) * bob_m;
	v_headlight = headlight_lit((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz, normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz));
}

void fragment() {
	ALBEDO = color.rgb;
	// Lit for the facets, glowing enough to read in the dark, and brighter in the headlights.
	EMISSION = color.rgb * (0.6 + hl_color * v_headlight);
	ROUGHNESS = 0.2;
	SPECULAR = 0.8;
}
