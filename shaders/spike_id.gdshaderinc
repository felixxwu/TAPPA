// SPIKE (throwaway): object-ID outline pass (scripts/spike_id_pass.gd).
// id_pass is only true on the ID-twin duplicate of a material. object_id < 0 = terrain.
// Packing (must match ps1_post_process.gdshader's decode):
//   rg = object hash (objects) or normal.xz * 0.5 + 0.5 (terrain)
//   b  = (terrain ? 0.5 : 0.0) + spike_dist_enc(view distance) * 0.49
// Sky is the viewport's black background.
uniform bool id_pass = false;
// A plain uniform on a per-twin material: instance uniforms don't reach MultiMesh
// draws on GL Compatibility.
uniform float object_id = 0.0;
varying flat vec3 v_spike_id;

const float SPIKE_DIST_SCALE = 150.0;

float spike_dist_enc(float dist) {
	return 1.0 - exp(-dist / SPIKE_DIST_SCALE);
}

vec3 spike_pack(vec2 rg, bool terrain, float dist) {
	return vec3(rg, (terrain ? 0.5 : 0.0) + spike_dist_enc(dist) * 0.49);
}

vec3 spike_terrain_color(vec3 world_normal, float dist) {
	vec3 n = normalize(world_normal);
	n *= sign(n.y + 1e-4);  // face up regardless of winding
	return spike_pack(n.xz * 0.5 + 0.5, true, dist);
}

vec3 spike_id_color(float id, int inst) {
	float h = id + float(inst) * 7.31;
	return 0.2 + 0.8 * fract(sin(h * vec3(12.9898, 78.233, 37.719)) * 43758.5453);
}
