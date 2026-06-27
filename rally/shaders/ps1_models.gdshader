shader_type spatial;
render_mode unshaded, specular_disabled;

uniform sampler2D albedo_texture : source_color, filter_nearest, hint_default_white;
uniform sampler2D road_texture : source_color, filter_nearest, hint_default_white;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 texture_tile = vec2(1.0, 1.0);
// Terrain-only road blend. Off by default so meshes that share this shader but
// carry no vertex-colour array (the car, the MX-5 body) — whose COLOR defaults
// to opaque white — keep sampling albedo_texture and are unaffected.
uniform bool blend_road = false;
// Road texture tiling relative to the ground texture (road_tile_per_meter /
// terrain_tile_per_meter). 1.0 = same density as the ground; higher = finer.
uniform float road_uv_scale = 1.0;

void fragment() {
	// Ground (e.g. grass) vs. road (e.g. gravel), cross-faded per-fragment by the
	// road weight the terrain bakes into the vertex-colour alpha channel
	// (COLOR.a: 1.0 on the road, ramping to 0.0 off it). COLOR.rgb stays a plain
	// ground tint (white by default).
	float road_t = blend_road ? COLOR.a : 0.0;
	vec3 ground = texture(albedo_texture, UV * texture_tile).rgb;
	vec3 road = texture(road_texture, UV * texture_tile * road_uv_scale).rgb;
	ALBEDO = mix(ground, road, road_t) * albedo_color.rgb * COLOR.rgb;
}
