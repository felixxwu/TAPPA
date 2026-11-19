// Surface detail for LogPile meshes: furrowed bark along the trunk, growth rings and
// radial cracks on the cut ends. Base colours come from the mesh's vertex colours.
// UV2.x is 0 on bark (UV = around, metres along) and 1 on a cut end (UV = metres from centre).
shader_type spatial;
render_mode cull_disabled;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
			mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void fragment() {
	vec3 col = COLOR.rgb;
	if (UV2.x < 0.5) {
		// Bark plates: stretched along the trunk, sharp dark furrows between them.
		vec2 p = vec2(UV.x * 18.0, UV.y * 2.5);
		float plates = noise(p) * 0.65 + noise(p * 2.7) * 0.35;
		float furrow = smoothstep(0.35, 0.15, abs(plates - 0.5));
		col *= mix(1.25, 0.6, furrow) * (0.85 + 0.3 * noise(UV * vec2(4.0, 0.7)));
		ROUGHNESS = 1.0;
	} else {
		float d = length(UV);
		float a = atan(UV.y, UV.x);
		float rings = sin((d + noise(vec2(a * 2.0, d * 9.0)) * 0.006) * 520.0);
		col *= 0.93 + 0.07 * rings;
		// A few dark radial checks, as on a drying cut face.
		float crack = smoothstep(0.985, 1.0, noise(vec2(a * 6.0, 0.5))) * smoothstep(0.0, UV2.y, d);
		col *= 1.0 - 0.5 * crack;
		ROUGHNESS = 0.9;
	}
	ALBEDO = col;
}
