// Free roam's loot on the road: a crystal that bobs up and down on its spot
// (TerrainStreamer._loot_marker). Bobbing in the shader keeps thousands of markers free of scripts.
shader_type spatial;
render_mode cull_disabled;

uniform vec4 color : source_color = vec4(1.0);
uniform float bob_m = 0.25;
uniform float bob_period_s = 2.2;
// Seconds into the bob, so neighbouring crystals don't move in step.
uniform float phase = 0.0;

void vertex() {
	VERTEX.y += sin((TIME + phase) * TAU / bob_period_s) * bob_m;
}

void fragment() {
	ALBEDO = color.rgb;
	// Lit for the facets, but glowing enough to read in the dark.
	EMISSION = color.rgb * 0.6;
	ROUGHNESS = 0.2;
	SPECULAR = 0.8;
}
