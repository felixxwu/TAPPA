shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
// No fog: it would tint the whole quad, and with additive blending that shows as a lit square.

// One car lamp drawn as a camera-facing flare: a hot core, a soft halo and a thin
// horizontal lens streak, all procedural. A generic point of light stands in for every
// car's lamp shape; the flare is what hides that it is only a point. See
// features/car-lamps.md. Used on a 1 x 1 QuadMesh placed at the lamp's centre.

uniform vec3 lamp_color : source_color = vec3(1.0);
uniform float level = 0.0;                    // 0 = off, 1 = full brightness
uniform float size_m = 0.5;
uniform vec3 facing = vec3(0.0, 0.0, -1.0);   // the way the lamp shines, in the car's axes
uniform float core_radius = 0.12;
uniform float halo = 0.35;
uniform float streak = 0.4;
uniform float depth_bias_m = 0.3;

varying float v_fade;

void vertex() {
	// Billboard by hand so the quad can also be pulled toward the camera: otherwise the
	// bodywork around the lamp would slice the flare in half.
	vec3 centre = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	centre += normalize(-centre) * depth_bias_m;
	POSITION = PROJECTION_MATRIX * vec4(centre + vec3(VERTEX.xy * size_m, 0.0), 1.0);
	// Fade out as the lamp turns away, so headlights don't glow through the car from behind.
	vec3 shine = normalize((MODEL_MATRIX * vec4(facing, 0.0)).xyz);
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - NODE_POSITION_WORLD);
	v_fade = smoothstep(0.0, 0.35, dot(shine, to_camera));
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float d = length(p);
	float core = 1.0 - smoothstep(core_radius * 0.6, core_radius, d);
	float glow = halo * exp(-d * d * 12.0);
	float flare = streak * exp(-abs(p.y) * 40.0) * max(1.0 - abs(p.x), 0.0);
	vec3 hot = mix(lamp_color, vec3(1.0), 0.6);
	ALBEDO = (hot * core + lamp_color * (glow + flare)) * level * v_fade;
}
