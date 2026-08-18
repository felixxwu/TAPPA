// Overworld fog-of-war darkening — the ONE source of truth, included by the shaders the
// overworld's ground is drawn with (ps1_models, ps1_terrain_snow). See features/overworld.md.
//
// WHAT IT DOES: the world map is dark except where the player has driven
// (features/map-exploration.md). In the HQ that fog multiplies a flat map plane; out here the
// same mask has to darken the actual GROUND, so the frontier the player drives up to is the
// same frontier the table draws.
//
// WHY A MASK TEXTURE AND NOT A DISTANCE TEST: "lit" is the union of a circle per completed
// rally (`RallyLibrary.lit_sources`), so there is no closed-form distance to a frontier — and
// re-deriving it per fragment would mean uploading every circle. `MapFog.build` rasterises the
// union CPU-side into a 64x64 R8 field, which is bilinear-filtered here for free; a coarse,
// smoothly-filtered mask is exactly right for a soft frontier, and it is rebuilt only when
// progress changes.
//
// FRAGMENT-SIDE ONLY, deliberately: terrain cells reach 25 m across at the coarsest LOD, so a
// per-vertex fog would snap the frontier to triangle edges, and ps1_models is kept free of any
// vertex stage (test_render_smoke.gd::test_terrain_shader_has_no_vertex_stage). This include
// declares only global uniforms and one function, so that ban still holds.
//
// TRANSPORT: `global uniform`, for the same reason the headlight cone uses them — terrain
// chunks stream in continuously, so a per-material push would need re-registration bookkeeping
// on every chunk load.
//
// LEAK WARNING: global shader parameters persist across scene changes, and these shaders are
// shared with every stage, the podium and the HQ. `ow_fog_amount` MUST return to 0 when leaving
// the overworld, or a rally stage inherits the overworld's fog — the exact failure
// `HeadlightCone.reset()` exists to prevent for the cone. See Overworld._clear_fog_uniforms.

global uniform sampler2D ow_fog_mask;   // 64x64 R8 lit field, 0..1, in normalised map space
global uniform float ow_fog_size_m;     // metres across the whole map, for world -> map_pos
global uniform float ow_fog_unlit;      // brightness multiplier where fully unlit (0 = black)
global uniform float ow_fog_amount;     // 0 = bit-for-bit no-op (every non-overworld scene)


// The light multiplier at a world position: 1.0 inside the explored frontier, falling to
// `ow_fog_unlit` outside it. A bit-for-bit 1.0 when `ow_fog_amount` is 0, so nothing that
// shares this shader pays for the feature.
float overworld_fog_at(vec3 world_pos) {
	if (ow_fog_amount <= 0.0 || ow_fog_size_m <= 0.0) {
		return 1.0;
	}
	// The inverse of Overworld.world_xz: map_pos = world_xz / size + 0.5, with z -> y. Kept
	// identical to the GDScript side on purpose — if the two ever disagree the fog slides off
	// the pins it is supposed to be drawn around.
	vec2 map_pos = world_pos.xz / ow_fog_size_m + vec2(0.5);
	// Outside the map is never lit. Sampling would clamp to the edge texel and smear the
	// border circle out to sea instead.
	if (map_pos.x < 0.0 || map_pos.x > 1.0 || map_pos.y < 0.0 || map_pos.y > 1.0) {
		return mix(1.0, ow_fog_unlit, ow_fog_amount);
	}
	float lit = texture(ow_fog_mask, map_pos).r;
	return mix(1.0, mix(ow_fog_unlit, 1.0, lit), ow_fog_amount);
}
