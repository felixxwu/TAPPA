// The tree star shader body, shared by billboard_opaque.gdshader (the cutout baked into the
// mesh, no discard), billboard_alpha.gdshader (a plain card cut out per pixel by its alpha, the way
// trees used to be drawn) and billboard_blend.gdshader (the card blended by its alpha), kept so
// their costs can be compared on a phone. Each sets its own render_mode. See the header of
// billboard_opaque.gdshader for how it works.

uniform sampler2D albedo : source_color, filter_nearest;
uniform float render_distance = 80.0;
uniform float fade_band = 15.0;
// Bias distant sampling toward cheaper mips (mobile texture-bandwidth win).
uniform float lod_bias = 0.0;
// Fake hemisphere-ambient + one directional sun, matching the terrain
// (terrain_manager._bake_light / ps1_models_lit.gdshader). A star card's
// normal is horizontal, so hemi is fixed at 0.5 (a
// vertical surface sees half sky, half ground). NO source_color hint: terrain
// bakes raw Color floats, so trees match the ground by using them raw too.
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform vec3 sun_color = vec3(0.0);
uniform vec3 sky_color = vec3(1.0);
uniform vec3 ground_color = vec3(1.0);
// 0 = flat (unlit, no-op multiply), 1 = full shading. Default 0 keeps a material
// that never sets these rendering exactly as before.
uniform float light_amount = 0.0;

varying vec3 v_tint;

#include "res://shaders/spike_id.gdshaderinc"
#include "res://shaders/headlight_cone.gdshaderinc"
#include "res://shaders/wind_sway.gdshaderinc"

void vertex() {
	if (id_pass) {  // keep the hash out of the normal colour pass
		v_spike_id = spike_id_color(object_id, INSTANCE_ID);
	}
	// Per-instance world origin (base, column 3 of the model matrix) and its scaled
	// height (column 1 length — the authored size baked into the instance basis).
	vec3 origin = MODEL_MATRIX[3].xyz;
	float height = length(MODEL_MATRIX[1].xyz);
	// Distance is measured to the TRUNK AXIS (the camera projected onto the trunk line,
	// clamped to the tree's [base, base+height] span), not the ground-level base.
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float ref_y = clamp(cam.y, origin.y, origin.y + height);
	float cam_dist = distance(cam, vec3(origin.x, ref_y, origin.z));
	// Distance shrink-out: 1 up close, 0 at the far cutoff.
	float scale = clamp((render_distance - cam_dist) / max(fade_band, 0.001), 0.0, 1.0);

	// Fixed hemisphere ambient for a vertical card (hemi = 0.5).
	vec3 ambient = mix(ground_color, sky_color, 0.5);

	bool felled = INSTANCE_CUSTOM.x > 0.5;
	vec3 world_pos;
	if (felled) {
		// Locked cross: the MODEL transform already carries the topple tilt + the
		// authored size scale. Shrink toward the base pivot for the distance fade.
		world_pos = (MODEL_MATRIX * vec4(VERTEX * scale, 1.0)).xyz;
		// Ambient-only: felled trees lie flat and are a rare, transient minority,
		// so skip the directional term rather than derive a per-plane normal.
		v_tint = mix(vec3(1.0), ambient, light_amount);
	} else {
		// Standing: a static star of vertical cards, drawn exactly where the mesh and
		// the instance transform (size + yaw) put them. No camera facing.
		world_pos = (MODEL_MATRIX * vec4(VERTEX * scale, 1.0)).xyz;
		// Wind sway is standing-only, and NOT scaled by the distance shrink, so a
		// shrinking canopy collapses straight down onto its base instead of swinging.
		world_pos += wind_sway_offset(origin, VERTEX.y, height);
		// Light with the card's own normal, flipped to face the camera. The traced
		// silhouette mesh has no normals, so fall back to its plane's axis.
		vec3 n = length(NORMAL) > 0.5 ? NORMAL : (COLOR.r > 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0));
		n = normalize((MODEL_MATRIX * vec4(n, 0.0)).xyz);
		if (dot(n, INV_VIEW_MATRIX[3].xyz - origin) < 0.0) {
			n = -n;
		}
		float ndl = max(dot(n, sun_dir), 0.0);
		vec3 lit = ambient + sun_color * ndl;
		v_tint = mix(vec3(1.0), lit, light_amount);
	}
	// Fake headlight cone (night weather), ADDED to the light term — never a
	// multiply, since at night v_tint is already near-black and scaling it by a
	// bright cone stays near-black. Applied here rather than inside the branches so
	// FELLED trees get it too: their branch is ambient-only, and a knocked-over tree
	// sitting unlit inside the headlight pool would read as a hole in the light.
	// Per-vertex is exact enough — cards are small in world space — and it avoids
	// paying the cone per fragment across a dense tree field.
	v_tint = v_tint * world_light + hl_color * headlight_lit(world_pos) + flash_lit(world_pos);
	// Rewrite to clip space directly; the default MODELVIEW path is bypassed.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
}

void fragment() {
	vec4 tex = texture(albedo, UV, lod_bias);
#ifdef ALPHA_CUTOUT
	if (tex.a < 0.5) {
		discard;
	}
#endif
#ifdef ALPHA_BLEND
	if (tex.a < 0.1) {
		discard;
	}
	ALPHA = tex.a;
#endif
	ALBEDO = tex.rgb * v_tint;
	if (id_pass) {
		ALBEDO = spike_pack(v_spike_id.rg, false, length(VERTEX));
	}
}
