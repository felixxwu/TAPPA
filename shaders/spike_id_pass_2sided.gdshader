shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

// SPIKE (throwaway): two-sided twin of spike_id_pass.gdshader, for sources that render both faces.
#include "res://shaders/spike_id.gdshaderinc"

varying vec3 v_world;

void vertex() {
	v_spike_id = spike_id_color(object_id, INSTANCE_ID);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Terrain meshes carry no usable NORMAL: take the facet normal from derivatives.
	ALBEDO = object_id < 0.0
		? spike_terrain_color(cross(dFdy(v_world), dFdx(v_world)), length(VERTEX))
		: spike_pack(v_spike_id.rg, false, length(VERTEX));
}
