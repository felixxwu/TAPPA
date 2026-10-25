// The money dropped at a wreck (LootDirector._sync_dropped_node): a crystal that bobs up and down
// over the spot until the car drives back to it.
shader_type spatial;
render_mode cull_disabled;

uniform vec4 color : source_color = vec4(1.0);
uniform float bob_m = 0.25;
uniform float bob_period_s = 2.2;

void vertex() {
	VERTEX.y += sin(TIME * TAU / bob_period_s) * bob_m;
}

void fragment() {
	ALBEDO = color.rgb;
	// Lit for the facets, but glowing enough to read in the dark.
	EMISSION = color.rgb * 0.6;
	ROUGHNESS = 0.2;
	SPECULAR = 0.8;
}
