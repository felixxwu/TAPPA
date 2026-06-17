shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform vec2 virtual_resolution = vec2(320.0, 240.0);

// The PS1's 4x4 ordered dither matrix, added to the 0-255 color before
// truncation to 5 bits. NOTE: mat4 is column-major and this literal is
// authored column-wise — each vec4 below is a COLUMN of the conventional
// row-written PS1 matrix, so DITHER[x][y] correctly yields row y, col x.
const mat4 DITHER = mat4(
	vec4(-4.0, 2.0, -3.0, 3.0),
	vec4(0.0, -2.0, 1.0, -1.0),
	vec4(-3.0, 3.0, -4.0, 2.0),
	vec4(1.0, -1.0, 0.0, -2.0)
);

void fragment() {
	vec3 color = texture(screen_texture, SCREEN_UV).rgb;
	vec2 virtual_pixel = floor(SCREEN_UV * virtual_resolution);
	int x = int(mod(virtual_pixel.x, 4.0));
	int y = int(mod(virtual_pixel.y, 4.0));
	float dither = DITHER[x][y] / 255.0;
	vec3 quantized = clamp(floor((color + dither) * 255.0 / 8.0) / 31.0, vec3(0.0), vec3(1.0));
	COLOR = vec4(quantized, 1.0);
}
