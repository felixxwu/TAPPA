// Free roam's coins on the road (TerrainStreamer._coin_marker): a flat disc stood on its edge,
// spinning and bobbing on its spot. Doing it in the shader keeps thousands of coins free of scripts.
shader_type spatial;

uniform vec4 color : source_color = vec4(0.97, 0.8, 0.13, 1.0);
uniform float bob_m = 0.2;
uniform float bob_period_s = 2.2;
uniform float spin_period_s = 1.6;
// Seconds into the motion, so neighbouring coins don't move in step.
uniform float phase = 0.0;

varying float v_headlight;

#include "res://shaders/headlight_cone.gdshaderinc"

// The mesh is a CylinderMesh (its faces up and down): tip it onto its edge, then spin it about
// the vertical.
vec3 stand_and_spin(vec3 v, float a) {
	v = vec3(v.x, -v.z, v.y);
	return vec3(v.x * cos(a) + v.z * sin(a), v.y, -v.x * sin(a) + v.z * cos(a));
}

void vertex() {
	float t = TIME + phase;
	float a = t * TAU / spin_period_s;
	VERTEX = stand_and_spin(VERTEX, a);
	NORMAL = stand_and_spin(NORMAL, a);
	VERTEX.y += sin(t * TAU / bob_period_s) * bob_m;
	v_headlight = headlight_lit((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz, normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz));
}

void fragment() {
	ALBEDO = color.rgb;
	// Lit so it glints as it turns, glowing enough to read in the dark, and brighter in the headlights.
	EMISSION = color.rgb * (0.5 + hl_color * v_headlight);
	METALLIC = 0.8;
	ROUGHNESS = 0.3;
}
