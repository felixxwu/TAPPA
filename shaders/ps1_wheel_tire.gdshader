shader_type spatial;
render_mode unshaded, specular_disabled;

// Applies wheel.png to the flat cap faces of the CylinderMesh (the outward-
// facing faces you see from the side). The cylindrical rubber tread uses
// albedo_color — the same uniform world.gd already writes for wheel colour,
// so no world.gd changes are needed.

uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;
// albedo_color = rubber tread colour (world.gd sets this to cfg.wheel_color).
// It does NOT tint the wheel texture — the cap shows the raw texture.
uniform vec4 albedo_color : source_color = vec4(0.12, 0.12, 0.12, 1.0);

uniform float light_amount : hint_range(0.0, 1.0) = 1.0;
uniform vec3 light_dir = vec3(0.4, 0.9, 0.35);
uniform vec3 sun_color : source_color = vec3(0.5);
uniform vec3 sky_color : source_color = vec3(0.5);
uniform vec3 ground_color : source_color = vec3(0.35);

varying vec3 v_light;
varying float v_local_normal_y;

void vertex() {
	// NORMAL in vertex = local (model) space. On a CylinderMesh the cap vertices
	// always have local normal.y = ±1; tread vertices have normal.y ≈ 0. This is
	// stable regardless of how the Tire node is rotated in the scene.
	v_local_normal_y = NORMAL.y;

	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float hemi = wn.y * 0.5 + 0.5;
	vec3 ambient = mix(ground_color, sky_color, hemi);
	float ndl = max(dot(wn, normalize(light_dir)), 0.0);
	vec3 lit = ambient + sun_color * ndl;
	v_light = mix(vec3(1.0), lit, light_amount);
}

void fragment() {
	float cap_mask = smoothstep(0.7, 0.9, abs(v_local_normal_y));

	// Godot's CylinderMesh cap UVs sit in [0.5,1]×[0,0.5] — remap to [0,1]×[0,1]
	// so the full wheel.png is displayed on the cap face.
	vec2 cap_uv = vec2((UV.x - 0.5) * 2.0, UV.y * 2.0);
	vec3 textured = texture(albedo_texture, cap_uv).rgb;

	// albedo_color drives the rubber tread; the cap shows the raw texture.
	vec3 final_color = mix(albedo_color.rgb, textured, cap_mask);
	ALBEDO = final_color * COLOR.rgb * v_light;
}
