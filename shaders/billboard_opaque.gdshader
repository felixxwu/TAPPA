// Opaque tight-cutout billboard that becomes a cross when felled. The instanced
// silhouette mesh (see TreeSilhouette) is a "+" of two planes; each vertex carries
// a plane FLAG in COLOR.r (0 = XY plane, 1 = ZY plane) and each instance a FELLED
// flag in INSTANCE_CUSTOM.x (0 = standing, 1 = knocked over).
//
//  - STANDING (INSTANCE_CUSTOM.x == 0): a static star of vertical cards (alpha/blend meshes: six
//    cards at 60 degree steps through the trunk; the traced silhouette mesh: a "+" of two
//    planes), placed by the instance transform. Nothing faces the camera. The cutout is baked
//    into the MESH (no alpha-test), so early-Z stays on on tile-based mobile GPUs.
//  - FELLED (INSTANCE_CUSTOM.x == 1): BOTH planes render at their authored positions
//    and the instance's MODEL transform (a topple tilt about the base) is applied
//    verbatim — the card is locked into the "+" cross and toppled, so a fallen tree
//    reads as a solid 3D shape instead of a flat sheet lying on the ground.
//
// The distance fade is a geometry SHRINK-OUT in vertex() — no per-fragment `discard`
// anywhere. The cutout is baked into the mesh, so the fragment is fully opaque: the
// driver keeps early-Z / hidden-surface removal ON for the draw (any `discard` forces
// HSR off for the whole draw on tile-based mobile GPUs), and overlapping trees occlude
// each other cheaply. A tree keeps its full size however close the camera gets. NOTE: still cull_disabled — the cards are seen from both sides, so flipping to cull_back would halve its
// fill, but the traced-silhouette mesh winding can't be verified headless (a wrong
// flip makes every tree vanish); flip + eyeball in-app as a separate change.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

#include "res://shaders/billboard_tree.gdshaderinc"
