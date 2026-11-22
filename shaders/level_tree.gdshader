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
varying float ao_height;
varying flat int slot;

#include "res://shaders/wind_sway.gdshaderinc"

void vertex() {
	ao_height = VERTEX.y;
	slot = int(INSTANCE_CUSTOM.r + 0.5);
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos += wind_sway_offset(origin, VERTEX.y, length(MODEL_MATRIX[1].xyz));
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
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
	if (tex.a < 0.5) {
		discard;
	}
	vec3 c = mix(vec3(mid_grey), tex.rgb, contrast);
	c = mix(vec3(dot(c, vec3(0.299, 0.587, 0.114))), c, saturation);
	ALBEDO = c * tints[min(slot, 5)].rgb * mix(1.0 - base_dark, 1.0, smoothstep(0.0, base_height, ao_height));
}
