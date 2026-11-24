// The level view's minimap (scripts/level_minimap.gd): a north-up map picture, turned heading-up round the car, seen tilted, cut to a circle.
shader_type canvas_item;

uniform sampler2D map_tex : filter_linear, repeat_disable;
uniform vec4 fog_color : source_color = vec4(0.06, 0.058, 0.05, 1.0);
uniform vec4 rim_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
// Far edge width over near edge width.
uniform float near_frac = 0.5;
// The picture is this much wider than the circle's ground at the car's row, so the tilted circle stays covered.
uniform float widen = 0.6;
uniform float rim_w = 0.025;
uniform vec2 car_uv = vec2(0.5);  // where the car is now in the picture
uniform float turn = 0.0;  // heading-up to world rotation
uniform float view_m = 400.0;  // ground across the circle at the car's row
uniform float pic_m = 880.0;  // ground across the whole picture
uniform float car_depth = 0.68;

void fragment() {
	float den = near_frac + (1.0 - near_frac) * UV.y;
	vec2 g = vec2(0.5 + (UV.x - 0.5) * widen / den, UV.y / den);
	float d = length(UV - 0.5) - 0.5;
	float aa = max(fwidth(d), 1e-4);
	float inside = 1.0 - smoothstep(-aa, aa, d);
	vec2 local = vec2(g.x - 0.5, g.y - car_depth) * view_m;
	float c = cos(turn), s = sin(turn);
	vec2 p = car_uv + vec2(c * local.x - s * local.y, s * local.x + c * local.y) / pic_m;
	vec4 m = texture(map_tex, clamp(p, 0.0, 1.0));
	vec3 col = m.rgb + fog_color.rgb * (1.0 - m.a);
	float out_of_pic = step(0.0, max(max(-p.x, p.x - 1.0), max(-p.y, p.y - 1.0)));
	col = mix(col, fog_color.rgb, out_of_pic);
	float rim = smoothstep(-rim_w - aa, -rim_w + aa, d);
	col = mix(col, rim_color.rgb, rim * rim_color.a);
	COLOR = vec4(col, inside);
}
