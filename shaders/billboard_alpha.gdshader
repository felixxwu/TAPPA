// The tree billboard cut out per pixel by its texture's alpha (discard below 0.5) on a plain card,
// instead of billboard_opaque's traced silhouette. Picked by GameConfig.tree_cutout_mode, so the
// cost of each can be measured (features/benchmark.md).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

#define ALPHA_CUTOUT
#include "res://shaders/billboard_tree.gdshaderinc"
