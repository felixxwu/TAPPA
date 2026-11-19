// The visibility bake's tree cards (tools/bake_level.gd): each instance paints its ID as a flat colour through the real alpha cut-out.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled;

uniform sampler2D albedo : filter_nearest;

varying vec3 id_colour;

void vertex() {
	id_colour = INSTANCE_CUSTOM.rgb;
}

void fragment() {
	if (texture(albedo, UV).a < 0.5) {
		discard;
	}
	ALBEDO = id_colour;
}
