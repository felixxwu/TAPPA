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

// Fake per-vertex lighting (PS1/PS2-style Gouraud) computed in the shader — the
// material stays render_mode unshaded, so the engine still runs NO lighting
// pass, casts no shadows, and needs no light nodes. We just tint ALBEDO by a
// hemisphere ambient + one hardcoded directional "sun", interpolated across the
// triangle for free by the rasteriser. light_amount blends the whole effect in:
// 0.0 = perfectly flat (the terrain and anything that leaves it at the default
// is untouched), 1.0 = full fake lighting (the car sets this). All directions
// are in world space so shading tracks the car as it turns.
uniform float light_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 light_dir = vec3(0.4, 0.9, 0.35);          // direction TO the sun
uniform vec3 sun_color : source_color = vec3(0.5);      // directional contribution
uniform vec3 sky_color : source_color = vec3(0.5);      // ambient from above
uniform vec3 ground_color : source_color = vec3(0.35);  // ambient bounce from below

varying vec3 v_light;

void vertex() {
	// World-space normal (uniform-scaled meshes only, which is all of ours).
	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float hemi = wn.y * 0.5 + 0.5;                       // 0 below, 1 above
	vec3 ambient = mix(ground_color, sky_color, hemi);
	float ndl = max(dot(wn, normalize(light_dir)), 0.0);
	vec3 lit = ambient + sun_color * ndl;
	// light_amount == 0 → exactly vec3(1.0), i.e. a no-op multiply.
	v_light = mix(vec3(1.0), lit, light_amount);
}

void fragment() {
	// Ground (e.g. grass) vs. road (e.g. gravel), cross-faded per-fragment by the
	// road weight the terrain bakes into the vertex-colour alpha channel
	// (COLOR.a: 1.0 on the road, ramping to 0.0 off it). COLOR.rgb stays a plain
	// ground tint (white by default).
	float road_t = blend_road ? COLOR.a : 0.0;
	vec3 ground = texture(albedo_texture, UV * texture_tile).rgb;
	vec3 road = texture(road_texture, UV * texture_tile * road_uv_scale).rgb;
	ALBEDO = mix(ground, road, road_t) * albedo_color.rgb * COLOR.rgb * v_light;
}
