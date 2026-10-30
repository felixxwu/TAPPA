// Opaque low-poly dust puff — the material behind the DustPuffs pool
// (scripts/dust_puffs.gd, features/dust-puffs.md).
//
// Every instance shares ONE flat-shaded blob mesh, built once at load. A puff's size,
// stretch and tumble all live in its MultiMesh instance basis (rewritten per tick as
// it grows), so the mesh itself never changes after load.
//
// Opaque and depth-writing, so overlapping puffs are drawn once per pixel with no
// transparency sorting — the reason this effect is cheap on mobile where a stack of
// alpha-blended sprites behind a chase camera is not.
//
// Lighting is the car's fake per-vertex sun/sky/ground block (ps1_models_lit), fed by
// GameConfig.apply_car_light, so puffs sit in the same light as the car. The mesh is
// flat-shaded (one normal per face), so per-vertex lighting reads as faceted tones.
shader_type spatial;
render_mode unshaded, specular_disabled, cull_back, depth_draw_opaque;

uniform float light_amount : hint_range(0.0, 1.0) = 1.0;
uniform vec3 light_dir = vec3(0.4, 0.9, 0.35);          // direction TO the sun
uniform vec3 sun_color : source_color = vec3(0.5);
uniform vec3 sky_color : source_color = vec3(0.5);
uniform vec3 ground_color : source_color = vec3(0.35);

// A puff whose centre is closer than camera_hide_m to the camera is collapsed to
// nothing, and it grows back to full size by camera_show_m. The chase camera drives
// straight through the trail the car leaves; a solid polygon sliding through the
// lens would black out the screen, so near puffs simply get out of the way.
uniform float camera_hide_m = 1.5;
uniform float camera_show_m = 3.5;

varying vec3 v_color;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float near_scale = smoothstep(camera_hide_m, camera_show_m, distance(origin, cam));
	VERTEX *= near_scale;
	// MODEL_NORMAL_MATRIX, not MODEL_MATRIX: each puff is stretched non-uniformly.
	vec3 wn = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	float hemi = wn.y * 0.5 + 0.5;
	vec3 ambient = mix(ground_color, sky_color, hemi);
	float ndl = max(dot(wn, normalize(light_dir)), 0.0);
	vec3 lit = mix(vec3(1.0), ambient + sun_color * ndl, light_amount);
	// Per-instance colour (mm.use_colors) arrives in COLOR.
	v_color = COLOR.rgb * lit;
}

void fragment() {
	ALBEDO = v_color;
}
