// The tree billboard blended by its texture's alpha on a static six-card star, so its edges are soft. Picked
// by GameConfig.tree_cutout_mode. Blended pixels still write depth, so trees hide each other in the
// right order: the Compatibility renderer (web) has no depth prepass, and without depth the trees
// of a field draw over each other in whatever order they were spawned. The cost is a faint halo
// where a soft edge is drawn before a tree behind it. Pixels below 0.1 alpha are dropped.
shader_type spatial;
// Front faces only: opposite star cards share a plane and would flicker against each other.
render_mode unshaded, cull_back, blend_mix, depth_draw_always;

#define ALPHA_BLEND
#include "res://shaders/billboard_tree.gdshaderinc"
