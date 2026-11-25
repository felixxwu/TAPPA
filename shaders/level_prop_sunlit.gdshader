// level_prop for the shop models, which were drawn sun-lit: the same colour and lamps, with the sun shading kept.
shader_type spatial;
render_mode cull_disabled;

#define SUNLIT
#include "res://shaders/headlight_cone.gdshaderinc"
#include "res://shaders/level_prop.gdshaderinc"
