shader_type spatial;
render_mode unshaded, specular_disabled;

// Car-only variant of ps1_models.gdshader with cheap fake per-vertex (Gouraud)
// lighting. It is deliberately SEPARATE from ps1_models.gdshader so the heavy
// terrain (tens of thousands of vertices in the loaded chunk ring) keeps its
// pass-through vertex path and pays nothing for a feature only the car uses —
// adding the vertex() stage to the shared shader was a real mobile regression.
// Only the handful of car/wheel/MX-5 vertices run this. Still render_mode
// unshaded: no engine lighting pass, no shadows, no light nodes.

uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 texture_tile = vec2(1.0, 1.0);

// Fake lighting, all in world space so shading tracks the car as it turns.
// light_amount blends the whole effect in (0 = flat, 1 = full); GameConfig's
// Car Lighting group drives these via world.gd / car.gd (cfg.apply_car_light).
uniform float light_amount : hint_range(0.0, 1.0) = 1.0;
uniform vec3 light_dir = vec3(0.4, 0.9, 0.35);          // direction TO the sun
uniform vec3 sun_color : source_color = vec3(0.5);      // directional contribution
uniform vec3 sky_color : source_color = vec3(0.5);      // ambient from above
uniform vec3 ground_color : source_color = vec3(0.35);  // ambient bounce from below

varying vec3 v_light;

void vertex() {
	// World-space normal (uniform-scaled meshes only, which is all of ours).
	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float hemi = wn.y * 0.5 + 0.5;                       // 0 below, 1 above
	vec3 ambient = mix(ground_color, sky_color, hemi);
	float ndl = max(dot(wn, normalize(light_dir)), 0.0);
	vec3 lit = ambient + sun_color * ndl;
	// light_amount == 0 → exactly vec3(1.0), i.e. a no-op multiply.
	v_light = mix(vec3(1.0), lit, light_amount);
}

void fragment() {
	ALBEDO = texture(albedo_texture, UV * texture_tile).rgb * albedo_color.rgb * COLOR.rgb * v_light;
}
