// Free roam's beam of light over a rest stop or a piece of loot (scripts/free_roam/site_beacons.gd).
// A see-through column that fades out as it reaches into the sky rather than ending in a hard
// cut-off. Unshaded, through fog (a beacon reads through the weather), never casting a shadow.
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled, depth_draw_never;

// The beam's colour; its alpha is the opacity at the foot (SiteBeacons fades it with distance).
uniform vec4 color : source_color = vec4(1.0, 1.0, 1.0, 0.6);
// The mesh's height, so the fade works in fractions of the beam.
uniform float height = 100.0;
// Where (as a fraction of the height, from the foot) the beam starts to fade, reaching zero at the top.
uniform float fade_start = 0.25;

varying float up;

void vertex() {
	up = clamp(VERTEX.y / height + 0.5, 0.0, 1.0);
}

void fragment() {
	ALBEDO = color.rgb;
	ALPHA = color.a * (1.0 - smoothstep(fade_start, 1.0, up));
}
