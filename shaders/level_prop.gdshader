// The level's props (buildings, fences, hedges, shop models, teleport obelisks): texture x colour x vertex colour,
// unshaded, then lit like the ground: world_light dimmed by the weather plus the headlight cone and exhaust flash, per fragment.
shader_type spatial;
render_mode unshaded, cull_disabled;

#include "res://shaders/headlight_cone.gdshaderinc"
#include "res://shaders/level_prop.gdshaderinc"
