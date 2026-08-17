// Fake headlight cone — the ONE source of truth, included by every shader the
// headlights can fall on (ps1_models, ps1_terrain_snow, ps1_models_lit,
// billboard_opaque, tree_canopy). See todo/night-weather-and-headlights.md.
//
// WHY THIS EXISTS AT ALL: terrain shading is baked into vertex colours on the CPU
// (TerrainManager.vertex_colors writes ARRAY_COLOR per chunk), and the renderer has
// NO light nodes anywhere — every shader is `unshaded`, so a SpotLight3D would do
// nothing. Driving a moving light by rebaking those vertex colours would mean
// regenerating ~127k verts every frame. Instead the cone is evaluated analytically
// from a handful of global uniforms, costing no draw calls, no geometry and no CPU
// per-frame work beyond one uniform push.
//
// TRANSPORT: `global uniform` (declared in project.godot's [shader_globals] and set
// via RenderingServer.global_shader_parameter_set) rather than per-material
// parameters. The materials that need this are built in five different scripts with
// no common registry, and terrain chunks stream in continuously — a per-material
// push would need re-registration bookkeeping on every chunk load. Globals have
// none, and cannot go stale mid-frame.
//
// LEAK WARNING: global shader parameters persist across scene changes. The podium
// and HQ share these shaders, so headlight_amount MUST be reset to 0 when entering any
// non-stage scene — see world.gd/HeadlightCone.reset().

global uniform vec3 hl_pos;        // world-space cone apex, MIDPOINT between the lamps
global uniform vec3 hl_dir;        // world-space aim, normalised and pitched on upload
global uniform vec3 hl_right;      // world-space car right, for the lamp separation
global uniform vec3 hl_color;      // light the cone ADDS (see below)
global uniform float hl_range;     // metres to full falloff
global uniform float hl_cos_inner; // cos(inner half-angle) — full brightness within
global uniform float hl_cos_outer; // cos(outer half-angle) — zero beyond
global uniform float hl_separation; // metres between the two lamps; 0 = a single cone
// Cone strength, authored PER WEATHER CONDITION (WeatherLibrary's "headlights" key):
// 0 = lights off and a bit-for-bit no-op, 1 = full strength as night runs it. A
// condition whose world is only half-dark (storm) authors this low, because the cone
// is ADDED to a light term that is already brighter than night's.
global uniform float headlight_amount;

// One cone, from one apex.
float _headlight_cone_at(vec3 world_pos, vec3 apex) {
	vec3 v = world_pos - apex;
	float d = length(v);
	// smoothstep's edges are cosines, so it runs from the OUTER (smaller cosine,
	// wider angle) to the INNER edge — hence outer is the first argument.
	float cone = smoothstep(hl_cos_outer, hl_cos_inner, dot(v / max(d, 0.001), hl_dir));
	float att = 1.0 - smoothstep(0.0, hl_range, d);
	return cone * att;
}

// Scalar cone strength at a world position. Returned as a FLOAT, not a colour, so
// shaders that must carry it across the vertex→fragment boundary can use a
// `varying float` rather than adding a vec3 interpolator (bushes are numerous and
// interpolator bandwidth is a real cost on tile-based mobile GPUs). Multiply by
// hl_color at the point of use.
//
// TWO LAMPS: the pair shares aim, range, angles and colour — only the apex differs —
// so the second lamp costs one more _headlight_cone_at (a length, a normalize, a dot
// and two smoothsteps), and no extra parameters beyond hl_right/hl_separation. That
// doubling is only paid per-FRAGMENT on terrain; every other shader evaluates this
// per-vertex, where it is noise.
//
// Combined with max(), not a sum: two overlapping cones that ADDED would produce a
// double-bright wedge straight ahead, which reads as a third light rather than as
// two beams crossing. max() keeps the overlap at lamp brightness and lets the pair
// read as a widened pool with a soft notch at the outer edges.
//
// hl_separation == 0 collapses to a single cone and SKIPS the second evaluation
// entirely. The branch is on a global uniform, so it is coherent across the whole
// draw — every fragment in every wavefront takes the same side, which is the cheap
// case for a GPU branch.
float headlight_lit(vec3 world_pos) {
	if (headlight_amount <= 0.0) {
		return 0.0;
	}
	if (hl_separation <= 0.0) {
		return _headlight_cone_at(world_pos, hl_pos) * headlight_amount;
	}
	vec3 lamp_offset = hl_right * (hl_separation * 0.5);
	float left = _headlight_cone_at(world_pos, hl_pos - lamp_offset);
	float right = _headlight_cone_at(world_pos, hl_pos + lamp_offset);
	return max(left, right) * headlight_amount;
}

// THE CONE MUST BE ADDITIVE, NEVER A MULTIPLY.
//
// The darkening is not done in a shader at all: a low night_sun_energy_mult scales
// tm.sun_color in world.gd::_apply_overcast_look, and the terrain bakes that dark
// light into COLOR.rgb at chunk generation. By the time any of this runs, the world
// is ALREADY dark — so multiplying a near-zero light term by a bright cone factor
// is still near zero. A multiplicative cone cannot re-light a darkened bake.
//
// The flip side, and why headlight_amount is per-condition: on a condition that only
// DIMS the day (storm's sun_energy_mult is a fraction, not near-zero) the same additive
// cone lands on a much brighter light term, so night's strength there sums past 1 and
// the lit pool clips to white. The fix is authored, not shader-side — a lower
// "headlights" value in that condition's table entry.
//
// Every shader here already separates surface from light (COLOR.rgb on terrain,
// v_light in ps1_models_lit, v_tint in billboard_opaque), so the cone is always
// `+ hl_color * headlight_lit(...)` on the LIGHT term, leaving the surface term
// untouched:
//
//     ALBEDO = surface * (light + hl_color * headlight_lit(world_pos));
