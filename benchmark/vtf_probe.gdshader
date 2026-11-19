shader_type spatial;
render_mode unshaded;

uniform sampler2D tex : filter_nearest;
uniform bool two_channel;
varying float h;

void vertex() {
	ivec2 p = clamp(ivec2(floor((VERTEX.xz / 256.0 + 0.5) * 256.0)), ivec2(0), ivec2(255));
	vec4 t = texelFetch(tex, p, 0);
	h = two_channel ? (t.r * 255.0 * 256.0 + t.g * 255.0) / 65535.0 : t.r;
	VERTEX.y = h * 20.0;
}

void fragment() {
	ALBEDO = vec3(h);
}
