// The level view's tree cards: unshaded, alpha-scissored, nearest-filtered and tinted per species,
// swaying with the same wind globals as free roam's billboard trees.
// One MultiMesh draws up to six species (LevelTrees.KINDS_PER_DRAW): each instance's INSTANCE_CUSTOM.r
// says which of this material's albedoN / tints[N] slots is its species, so a tile is one draw call, not one per species.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform sampler2D albedo0 : source_color, filter_nearest;
uniform sampler2D albedo1 : source_color, filter_nearest;
uniform sampler2D albedo2 : source_color, filter_nearest;
uniform sampler2D albedo3 : source_color, filter_nearest;
uniform sampler2D albedo4 : source_color, filter_nearest;
uniform sampler2D albedo5 : source_color, filter_nearest;
uniform vec4 tints[6] : source_color;
// Pulls the leaf textures' vivid greens and bright highlights towards the muted terrain and bushes.
uniform float saturation : hint_range(0.0, 1.0) = 0.6;
uniform float contrast : hint_range(0.0, 1.0) = 0.6;
uniform float mid_grey : hint_range(0.0, 1.0) = 0.35;
// Darkens the card toward its foot: base_dark at the bottom, none from base_height (0..1 up the card) upwards.
uniform float base_dark : hint_range(0.0, 1.0) = 0.0;
uniform float base_height : hint_range(0.01, 1.0) = 0.35;
// Trees thin out over the last fade_m before draw_end_m (metres from the camera to the tree's root), in a
// screen-door dither, so where they stop never shows as a line however thin the fog is. 0 = no fade.
uniform float draw_end_m = 0.0;
uniform float fade_m = 60.0;
varying float ao_height;
varying flat int slot;
varying float keep;

#include "res://shaders/wind_sway.gdshaderinc"

void vertex() {
	ao_height = VERTEX.y;
	slot = int(INSTANCE_CUSTOM.r + 0.5);
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos += wind_sway_offset(origin, VERTEX.y, length(MODEL_MATRIX[1].xyz));
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	keep = 1.0;
	if (draw_end_m > 0.0) {
		float d = distance(origin, CAMERA_POSITION_WORLD);
		keep = clamp((draw_end_m - d) / max(fade_m, 0.001), 0.0, 1.0);
	}
}

// 4x4 ordered dither threshold in (0, 1) for this pixel.
float bayer4(vec2 p) {
	int x = int(mod(p.x, 4.0));
	int y = int(mod(p.y, 4.0));
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[y * 4 + x]) + 0.5) / 16.0;
}

void fragment() {
	// The textures have no mipmaps (filter_nearest), so sampling inside the branches needs no derivatives.
	vec4 tex;
	if (slot == 0) {
		tex = texture(albedo0, UV);
	} else if (slot == 1) {
		tex = texture(albedo1, UV);
	} else if (slot == 2) {
		tex = texture(albedo2, UV);
	} else if (slot == 3) {
		tex = texture(albedo3, UV);
	} else if (slot == 4) {
		tex = texture(albedo4, UV);
	} else {
		tex = texture(albedo5, UV);
	}
	if (tex.a < 0.5 || keep < bayer4(FRAGCOORD.xy)) {
		discard;
	}
	vec3 c = mix(vec3(mid_grey), tex.rgb, contrast);
	c = mix(vec3(dot(c, vec3(0.299, 0.587, 0.114))), c, saturation);
	ALBEDO = c * tints[min(slot, 5)].rgb * mix(1.0 - base_dark, 1.0, smoothstep(0.0, base_height, ao_height));
}
