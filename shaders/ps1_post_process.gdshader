shader_type canvas_item;

// Applied to the PostProcess SubViewportContainer in main.tscn: TEXTURE is the
// SubViewport's rendered 3D frame, so no hint_screen_texture is needed. The
// screen-texture hint forced a full-screen backbuffer copy (render-pass break +
// mid-frame command submit) every frame on the Compatibility backend; sampling
// the subviewport texture we already have is free.
uniform vec2 virtual_resolution = vec2(320.0, 240.0);

// --- Colour grade (Race Driver: GRID look) -----------------------------------
// Desaturate + contrast + a warm-brown SPLIT TONE (brown shadows, cream
// highlights — GRID's signature was never a uniform sepia wash) + a vignette.
// Runs BEFORE the dither/quantise below so the 5-bit banding lands in the graded
// palette; grading afterwards would smear the 32 quantised levels back into
// intermediate values and soften the exact banding the PS1 look is built on.
// All the maths here is sRGB-space (TEXTURE is the SubViewport's already-encoded
// output, not linear) — that is intended for this era of look, so don't
// "correct" it to linear. Defaults mirror config/game_config.tres and MUST stay
// non-zero: mat_post in main.tscn only authors virtual_resolution, so any path
// that doesn't run world.gd's _ready (the editor viewport) grades on these.
// Master strength. 0 = exact passthrough (vignette included), 1 = full grade.
uniform float grade_amount : hint_range(0.0, 1.0) = 0.7;
// 1 = untouched, 0 = greyscale.
uniform float grade_saturation : hint_range(0.0, 1.0) = 0.7;
// 1 = untouched. Contrast pivots around mid-grey.
uniform float grade_contrast : hint_range(0.5, 2.0) = 1.15;
// Tint pushed into the dark end / the bright end, crossfaded by luma.
uniform vec4 grade_shadow_tint : source_color = vec4(0.62, 0.52, 0.40, 1.0);
uniform vec4 grade_highlight_tint : source_color = vec4(1.0, 0.94, 0.78, 1.0);
// Corner darkening. 0 = off; radius is where the falloff starts.
uniform float grade_vignette_strength : hint_range(0.0, 1.0) = 0.25;
uniform float grade_vignette_radius : hint_range(0.0, 1.5) = 0.75;

const vec3 LUMA_709 = vec3(0.2126, 0.7152, 0.0722);

// SPIKE (throwaway): object-ID outline (scripts/spike_id_pass.gd).
uniform sampler2D id_texture : filter_nearest;
uniform bool use_id_outline = false;
uniform float outline_strength : hint_range(0.0, 1.0) = 0.4;
uniform float outline_width : hint_range(0.5, 4.0) = 0.5;
// Terrain pixels carry a normal (blue = TERRAIN_MARK); two terrain pixels edge only
// where their normals differ by more than this angle.
uniform float crease_angle_deg : hint_range(1.0, 90.0) = 30.0;
// Live Environment fog density (pushed per frame by spike_id_pass.gd); edges fade by
// the fog at the nearer of their two pixels, times this.
uniform float scene_fog_density = 0.0;
uniform float outline_fog_fade : hint_range(0.0, 2.0) = 1.0;
// Centre-to-corner distance on the same scale as the vignette's `dist` below
// (1.0 = edge midpoint), i.e. sqrt(2). The vignette reaches full strength here.
const float CORNER_DIST = 1.4142136;

// Shift a tint's HUE without touching brightness, by dividing out its own
// luminance. Without this a tint multiply can only ever DARKEN (the inspector
// clamps a Color export's components to 1.0), so a brown tint dims the whole
// stage, the tuner fights that with contrast, and the result is mud. Keeping
// tint and exposure independent is the whole point.
// The max() is NOT optional: the divide explodes as the tint approaches black,
// and a near-black grade_shadow_tint is exactly what "crushed warm-brown
// blacks" invites someone to author.
vec3 luma_normalized(vec3 tint) {
	return tint / max(dot(tint, LUMA_709), 1e-3);
}

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

// SPIKE: decode of spike_id.gdshaderinc's packing — keep the two in step.
const float SPIKE_DIST_SCALE = 150.0;

bool is_sky(vec3 c) {
	return c.b < 0.002 && c.r < 0.002 && c.g < 0.002;
}

bool is_terrain(vec3 c) {
	return c.b >= 0.5;
}

vec3 terrain_normal(vec3 c) {
	vec2 xz = c.rg * 2.0 - 1.0;
	return vec3(xz.x, sqrt(max(1.0 - dot(xz, xz), 0.0)), xz.y);
}

// Godot's exponential depth fog at this pixel (sky counts as fully fogged).
float id_fog(vec3 c) {
	if (is_sky(c)) {
		return 1.0;
	}
	float enc = (c.b - (is_terrain(c) ? 0.5 : 0.0)) / 0.49;
	float dist = -SPIKE_DIST_SCALE * log(max(1.0 - enc, 1e-4));
	return 1.0 - exp(-scene_fog_density * dist);
}

// Edge strength between c and neighbour q: 1 at a new object / sky boundary or a
// terrain crease sharper than crease_cos, faded by the fog at the nearer pixel.
float id_edge(vec3 c, vec3 q, float crease_cos) {
	float e;
	if (is_terrain(c) && is_terrain(q)) {
		e = step(dot(terrain_normal(c), terrain_normal(q)), crease_cos);
	} else {
		e = float(is_terrain(c) != is_terrain(q) || is_sky(c) != is_sky(q)
			|| distance(c.rg, q.rg) > 0.01);
	}
	if (e == 0.0) {
		return 0.0;  // fog only matters on edge pixels
	}
	return e * clamp(1.0 - min(id_fog(c), id_fog(q)) * outline_fog_fade, 0.0, 1.0);
}

void fragment() {
	vec3 original = texture(TEXTURE, UV).rgb;

	// SPIKE: darken where the object ID changes between neighbours.
	if (use_id_outline) {
		vec2 px = TEXTURE_PIXEL_SIZE * outline_width;
		vec3 c = texture(id_texture, UV).rgb;
		float crease_cos = cos(radians(crease_angle_deg));
		float edge = max(max(id_edge(c, texture(id_texture, UV + vec2(px.x, 0.0)).rgb, crease_cos),
				id_edge(c, texture(id_texture, UV - vec2(px.x, 0.0)).rgb, crease_cos)),
			max(id_edge(c, texture(id_texture, UV + vec2(0.0, px.y)).rgb, crease_cos),
				id_edge(c, texture(id_texture, UV - vec2(0.0, px.y)).rgb, crease_cos)));
		original *= 1.0 - edge * outline_strength;
	}

	// Luma is taken ONCE from the untouched sample and reused for both the
	// desaturation lerp and the split-tone crossfade. Deliberately not
	// recomputed after contrast: sourcing it from the original keeps the
	// shadow/highlight boundary fixed, so retuning grade_contrast doesn't also
	// slide the tint crossover around.
	float luma = dot(original, LUMA_709);

	vec3 graded = mix(vec3(luma), original, grade_saturation);
	graded = (graded - 0.5) * grade_contrast + 0.5;
	graded *= luma_normalized(mix(grade_shadow_tint.rgb, grade_highlight_tint.rgb,
		smoothstep(0.0, 1.0, luma)));

	// Vignette lives INSIDE the graded branch, before the master blend below —
	// applied after it, grade_amount = 0 would still darken the corners and the
	// "0 is a true bypass" contract would be a lie.
	// Computed in UV space, so it's an ellipse on screen rather than a circle
	// (the frame is already ~1.48:1 in pixels before DisplayStretch widens it by
	// another 1.2). That's the intended look, but it does mean the shape follows
	// the window aspect — a very wide display gets a more stretched vignette.
	// dist: 0 at the centre, 1 at the edge midpoints, ~1.414 in the corners.
	float dist = length(UV - vec2(0.5)) * 2.0;
	float vignette = 1.0 - smoothstep(grade_vignette_radius, CORNER_DIST, dist);
	graded *= mix(1.0, vignette, grade_vignette_strength);

	vec3 color = mix(original, graded, grade_amount);

	vec2 virtual_pixel = floor(UV * virtual_resolution);
	int x = int(mod(virtual_pixel.x, 4.0));
	int y = int(mod(virtual_pixel.y, 4.0));
	float dither = DITHER[x][y] / 255.0;
	vec3 quantized = clamp(floor((color + dither) * 255.0 / 8.0) / 31.0, vec3(0.0), vec3(1.0));
	COLOR = vec4(quantized, 1.0);
}
