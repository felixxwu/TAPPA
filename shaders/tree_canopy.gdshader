// The ground bushes' leaf/frond shell (scripts/foliage.gd bush_mesh): unshaded and
// double-sided (cull_disabled), because single-sided back-face culling rendered the
// single-sided cards concave / "front faces missing" on some web/device GL targets
// (see features/trees.md), so cull_back is NOT safe here.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest_mipmap;
// Flat tint multiplied over the texture (the bushes' cfg.bush_tint); white = no tint.
uniform vec4 tint : source_color = vec4(1.0);

#include "res://shaders/spike_id.gdshaderinc"
#include "res://shaders/headlight_cone.gdshaderinc"

// Scalar cone strength, carried as a FLOAT rather than a vec3: this shader had no
// varyings at all, and bushes are instanced densely, so adding a full colour
// interpolator would cost bandwidth for no gain — hl_color is applied in fragment.
varying float v_headlight;

void vertex() {
	if (id_pass) {  // keep the hash out of the normal colour pass
		v_spike_id = spike_id_color(object_id, INSTANCE_ID);
	}
	v_headlight = headlight_lit((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	// COLOR.rgb is TreeMeshField's baked per-instance terrain light and tint is the
	// authored bush tint — together the LIGHT term, which the headlight ADDS to. The
	// texture is the surface term and stays outside the brackets.
	ALBEDO = texture(albedo, UV).rgb * (COLOR.rgb * tint.rgb + hl_color * v_headlight);
	if (id_pass) {
		ALBEDO = spike_pack(v_spike_id.rg, false, length(VERTEX));
	}
}
