class_name CarSilhouettes
extends RefCounted
# GENERATED — DO NOT EDIT BY HAND. Regenerate with:
#
#   /Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot --headless \
#       --path . -s tools/bake_car_silhouettes.gd
#
# Side-profile silhouettes traced from each car BODY model plus that car's own wheels, in the
# overworld pin glyph's unit box (x -1..1 nose to the RIGHT, y DOWN, longer axis spanning the
# full box, true side-on aspect ratio). Keyed by CarLibrary model id. Baked as source so the
# game never runs the tracer at load; see tools/bake_car_silhouettes.gd for the projection and
# features/overworld.md for the wiring.
#
# Per car: "outline" is the whole car as ONE closed loop (body and wheels already unioned, so
# a rasteriser like PolygonIcon needs nothing else); "wheels" + "wheel_r" are the same two
# wheels as centres and a radius, for a painter that would rather lay crisp circles over the
# traced arches at 14 px.
#
# REBAKE WHEN: a body .glb changes, a body is re-seated in car.tscn, a car is added, or a
# car's `wheelbase` / `wheel_radius` is retuned — the wheels here come from those authored
# values, so an icon can otherwise go quietly stale.
#
# A model with no entry here (a car added since the last bake, or a procedural-body car) is
# NOT an error — the caller falls back to the generic car glyph.

# NOTE static var, not const: a `const` initialiser must be a constant expression and a
# PackedVector2Array constructor is not one, so this mirrors overworld_map.gd's own glyph
# arrays, which are `static var` for the same reason. Treat it as read-only.
static var SILHOUETTES: Dictionary = {
	"mx5": {
		"outline": PackedVector2Array([
			Vector2(-0.324, -0.270), Vector2(0.054, -0.270), Vector2(0.054, -0.243),
			Vector2(0.162, -0.216), Vector2(0.162, -0.189), Vector2(0.297, -0.108),
			Vector2(0.459, -0.108), Vector2(0.459, -0.081), Vector2(0.676, -0.081),
			Vector2(0.676, -0.054), Vector2(0.838, -0.054), Vector2(0.838, -0.027),
			Vector2(0.892, -0.027), Vector2(0.892, 0.000), Vector2(0.973, 0.054), Vector2(0.973, 0.189),
			Vector2(0.946, 0.189), Vector2(0.946, 0.216), Vector2(0.703, 0.216), Vector2(0.703, 0.243),
			Vector2(0.541, 0.243), Vector2(0.541, 0.216), Vector2(0.405, 0.216), Vector2(0.405, 0.243),
			Vector2(-0.351, 0.243), Vector2(-0.351, 0.216), Vector2(-0.459, 0.216),
			Vector2(-0.459, 0.243), Vector2(-0.622, 0.243), Vector2(-0.622, 0.216),
			Vector2(-0.919, 0.189), Vector2(-0.919, 0.162), Vector2(-0.946, 0.162),
			Vector2(-0.946, 0.081), Vector2(-0.973, 0.027), Vector2(-0.919, 0.027),
			Vector2(-0.892, -0.108), Vector2(-0.649, -0.108), Vector2(-0.649, -0.135),
			Vector2(-0.514, -0.135), Vector2(-0.514, -0.162), Vector2(-0.324, -0.243),
		]),
		"wheels": PackedVector2Array([
			Vector2(0.616, 0.113), Vector2(-0.547, 0.113),
		]),
		"wheel_r": 0.142,
	},
	"focus": {
		"outline": PackedVector2Array([
			Vector2(-0.324, -0.324), Vector2(0.135, -0.297), Vector2(0.135, -0.270),
			Vector2(0.514, -0.081), Vector2(0.595, -0.081), Vector2(0.595, -0.054),
			Vector2(0.730, -0.054), Vector2(0.730, -0.027), Vector2(0.838, -0.027),
			Vector2(0.838, 0.000), Vector2(0.892, 0.000), Vector2(0.892, 0.027), Vector2(0.973, 0.108),
			Vector2(0.973, 0.162), Vector2(0.946, 0.162), Vector2(0.946, 0.270), Vector2(0.973, 0.270),
			Vector2(0.973, 0.297), Vector2(0.649, 0.297), Vector2(0.649, 0.324), Vector2(0.541, 0.324),
			Vector2(0.541, 0.297), Vector2(-0.541, 0.270), Vector2(-0.541, 0.297),
			Vector2(-0.676, 0.324), Vector2(-0.676, 0.297), Vector2(-0.973, 0.243),
			Vector2(-0.973, 0.081), Vector2(-0.946, 0.081), Vector2(-0.946, -0.108),
			Vector2(-0.892, -0.108), Vector2(-0.541, -0.297), Vector2(-0.324, -0.297),
		]),
		"wheels": PackedVector2Array([
			Vector2(0.595, 0.179), Vector2(-0.628, 0.179),
		]),
		"wheel_r": 0.140,
	},
	"twingo": {
		"outline": PackedVector2Array([
			Vector2(-0.946, -0.432), Vector2(-0.757, -0.405), Vector2(-0.757, -0.297),
			Vector2(-0.676, -0.297), Vector2(-0.676, -0.324), Vector2(-0.027, -0.324),
			Vector2(-0.027, -0.297), Vector2(0.162, -0.297), Vector2(0.162, -0.270),
			Vector2(0.838, 0.027), Vector2(0.838, 0.135), Vector2(0.892, 0.135), Vector2(0.892, 0.189),
			Vector2(0.919, 0.243), Vector2(0.865, 0.243), Vector2(0.865, 0.297), Vector2(0.730, 0.297),
			Vector2(0.730, 0.351), Vector2(0.676, 0.405), Vector2(0.514, 0.405), Vector2(0.459, 0.324),
			Vector2(-0.541, 0.324), Vector2(-0.541, 0.378), Vector2(-0.730, 0.405),
			Vector2(-0.730, 0.378), Vector2(-0.784, 0.378), Vector2(-0.784, 0.324),
			Vector2(-0.919, 0.189), Vector2(-0.919, 0.108), Vector2(-0.892, 0.108),
			Vector2(-0.892, 0.027), Vector2(-0.919, 0.027), Vector2(-0.973, -0.108),
			Vector2(-0.946, -0.108), Vector2(-0.946, -0.189), Vector2(-0.919, -0.189),
			Vector2(-0.865, -0.324), Vector2(-0.919, -0.324), Vector2(-0.946, -0.378),
		]),
		"wheels": PackedVector2Array([
			Vector2(0.590, 0.264), Vector2(-0.662, 0.264),
		]),
		"wheel_r": 0.149,
	},
	"acty": {
		"outline": PackedVector2Array([
			Vector2(0.216, -0.486), Vector2(0.649, -0.486), Vector2(0.649, -0.459),
			Vector2(0.730, -0.405), Vector2(0.730, -0.351), Vector2(0.946, -0.135),
			Vector2(0.946, 0.054), Vector2(0.973, 0.054), Vector2(0.973, 0.324), Vector2(0.649, 0.324),
			Vector2(0.649, 0.378), Vector2(0.622, 0.378), Vector2(0.568, 0.459), Vector2(0.405, 0.459),
			Vector2(0.405, 0.432), Vector2(0.351, 0.405), Vector2(0.351, 0.351), Vector2(0.324, 0.297),
			Vector2(-0.459, 0.297), Vector2(-0.459, 0.351), Vector2(-0.541, 0.459),
			Vector2(-0.703, 0.459), Vector2(-0.703, 0.432), Vector2(-0.784, 0.378),
			Vector2(-0.784, 0.270), Vector2(-0.919, 0.270), Vector2(-0.973, 0.243),
			Vector2(-0.973, -0.054), Vector2(-0.486, -0.054), Vector2(-0.486, -0.027),
			Vector2(0.189, -0.027), Vector2(0.189, -0.324), Vector2(0.216, -0.324),
		]),
		"wheels": PackedVector2Array([
			Vector2(0.491, 0.306), Vector2(-0.628, 0.306),
		]),
		"wheel_r": 0.159,
	},
	"charger": {
		"outline": PackedVector2Array([
			Vector2(-0.378, -0.162), Vector2(0.189, -0.162), Vector2(0.189, -0.135),
			Vector2(0.324, -0.027), Vector2(0.486, -0.027), Vector2(0.486, 0.000), Vector2(0.811, 0.000),
			Vector2(0.811, 0.027), Vector2(0.973, 0.027), Vector2(0.973, 0.162), Vector2(0.919, 0.162),
			Vector2(0.811, 0.216), Vector2(0.703, 0.216), Vector2(0.703, 0.270), Vector2(0.649, 0.297),
			Vector2(0.541, 0.297), Vector2(0.514, 0.243), Vector2(0.432, 0.243), Vector2(0.432, 0.270),
			Vector2(-0.054, 0.270), Vector2(-0.054, 0.243), Vector2(-0.405, 0.243),
			Vector2(-0.405, 0.270), Vector2(-0.568, 0.297), Vector2(-0.568, 0.270),
			Vector2(-0.622, 0.216), Vector2(-0.757, 0.216), Vector2(-0.757, 0.189),
			Vector2(-0.892, 0.189), Vector2(-0.946, 0.216), Vector2(-0.946, 0.135),
			Vector2(-0.973, 0.135), Vector2(-0.973, 0.000), Vector2(-0.838, 0.000),
			Vector2(-0.838, -0.027), Vector2(-0.649, -0.027), Vector2(-0.649, -0.054),
			Vector2(-0.378, -0.135),
		]),
		"wheels": PackedVector2Array([
			Vector2(0.598, 0.168), Vector2(-0.495, 0.168),
		]),
		"wheel_r": 0.131,
	},
	"porsche911": {
		"outline": PackedVector2Array([
			Vector2(-0.270, -0.270), Vector2(0.108, -0.270), Vector2(0.108, -0.243),
			Vector2(0.162, -0.243), Vector2(0.162, -0.216), Vector2(0.324, -0.108),
			Vector2(0.432, -0.108), Vector2(0.432, -0.081), Vector2(0.703, -0.081),
			Vector2(0.703, -0.054), Vector2(0.838, -0.054), Vector2(0.838, -0.027),
			Vector2(0.919, 0.081), Vector2(0.973, 0.081), Vector2(0.973, 0.135), Vector2(0.919, 0.135),
			Vector2(0.919, 0.216), Vector2(0.676, 0.216), Vector2(0.676, 0.243), Vector2(0.351, 0.243),
			Vector2(0.351, 0.216), Vector2(-0.405, 0.216), Vector2(-0.405, 0.243),
			Vector2(-0.568, 0.243), Vector2(-0.568, 0.216), Vector2(-0.865, 0.189),
			Vector2(-0.865, 0.162), Vector2(-0.973, 0.135), Vector2(-0.973, 0.081),
			Vector2(-0.892, 0.081), Vector2(-0.892, 0.000), Vector2(-0.811, -0.054),
			Vector2(-0.811, -0.081), Vector2(-0.919, -0.135), Vector2(-0.568, -0.135),
			Vector2(-0.514, -0.189), Vector2(-0.432, -0.189), Vector2(-0.351, -0.243),
			Vector2(-0.270, -0.243),
		]),
		"wheels": PackedVector2Array([
			Vector2(0.594, 0.108), Vector2(-0.475, 0.108),
		]),
		"wheel_r": 0.146,
	},
	"viper": {
		"outline": PackedVector2Array([
			Vector2(-0.405, -0.257), Vector2(0.000, -0.257), Vector2(0.000, -0.230),
			Vector2(0.162, -0.149), Vector2(0.243, -0.149), Vector2(0.243, -0.122),
			Vector2(0.676, -0.122), Vector2(0.676, -0.095), Vector2(0.757, -0.095),
			Vector2(0.757, -0.068), Vector2(0.973, 0.014), Vector2(0.973, 0.095), Vector2(0.946, 0.095),
			Vector2(0.946, 0.203), Vector2(0.703, 0.203), Vector2(0.703, 0.230), Vector2(-0.351, 0.230),
			Vector2(-0.405, 0.203), Vector2(-0.405, 0.230), Vector2(-0.568, 0.230),
			Vector2(-0.568, 0.203), Vector2(-0.919, 0.122), Vector2(-0.919, 0.095),
			Vector2(-0.973, 0.041), Vector2(-0.973, 0.014), Vector2(-0.919, 0.014),
			Vector2(-0.919, -0.041), Vector2(-0.946, -0.068), Vector2(-0.919, -0.068),
			Vector2(-0.865, -0.122), Vector2(-0.649, -0.122), Vector2(-0.649, -0.149),
			Vector2(-0.541, -0.149), Vector2(-0.541, -0.176), Vector2(-0.405, -0.230),
		]),
		"wheels": PackedVector2Array([
			Vector2(0.629, 0.095), Vector2(-0.494, 0.095),
		]),
		"wheel_r": 0.147,
	},
	"xjs": {
		"outline": PackedVector2Array([
			Vector2(-0.405, -0.243), Vector2(0.108, -0.243), Vector2(0.108, -0.216),
			Vector2(0.297, -0.108), Vector2(0.486, -0.108), Vector2(0.486, -0.081),
			Vector2(0.703, -0.081), Vector2(0.703, -0.054), Vector2(0.892, -0.054),
			Vector2(0.892, -0.027), Vector2(0.973, 0.054), Vector2(0.973, 0.135), Vector2(0.946, 0.135),
			Vector2(0.919, 0.189), Vector2(0.703, 0.189), Vector2(0.703, 0.216), Vector2(0.541, 0.216),
			Vector2(0.541, 0.189), Vector2(-0.351, 0.189), Vector2(-0.351, 0.216),
			Vector2(-0.514, 0.216), Vector2(-0.514, 0.189), Vector2(-0.865, 0.162),
			Vector2(-0.865, 0.135), Vector2(-0.946, 0.135), Vector2(-0.946, 0.081),
			Vector2(-0.973, 0.081), Vector2(-0.973, 0.054), Vector2(-0.946, 0.054),
			Vector2(-0.946, -0.054), Vector2(-0.865, -0.054), Vector2(-0.865, -0.081),
			Vector2(-0.757, -0.081), Vector2(-0.757, -0.108), Vector2(-0.649, -0.108),
			Vector2(-0.595, -0.162), Vector2(-0.514, -0.162), Vector2(-0.405, -0.216),
		]),
		"wheels": PackedVector2Array([
			Vector2(0.627, 0.095), Vector2(-0.434, 0.095),
		]),
		"wheel_r": 0.131,
	},
	"beast": {
		"outline": PackedVector2Array([
			Vector2(-0.838, -0.230), Vector2(-0.081, -0.230), Vector2(-0.081, -0.203),
			Vector2(0.081, -0.122), Vector2(0.541, -0.122), Vector2(0.541, -0.095),
			Vector2(0.757, -0.095), Vector2(0.757, -0.068), Vector2(0.946, -0.068),
			Vector2(0.946, -0.014), Vector2(0.973, -0.014), Vector2(0.973, 0.095), Vector2(0.946, 0.095),
			Vector2(0.892, 0.149), Vector2(0.703, 0.149), Vector2(0.703, 0.203), Vector2(0.649, 0.230),
			Vector2(0.568, 0.230), Vector2(0.514, 0.203), Vector2(0.514, 0.149), Vector2(0.432, 0.149),
			Vector2(0.432, 0.176), Vector2(-0.405, 0.176), Vector2(-0.405, 0.149),
			Vector2(-0.432, 0.149), Vector2(-0.432, 0.203), Vector2(-0.568, 0.230),
			Vector2(-0.568, 0.203), Vector2(-0.622, 0.203), Vector2(-0.622, 0.149),
			Vector2(-0.676, 0.095), Vector2(-0.811, 0.095), Vector2(-0.811, 0.068),
			Vector2(-0.946, 0.068), Vector2(-0.973, 0.041), Vector2(-0.973, -0.095),
			Vector2(-0.838, -0.203),
		]),
		"wheels": PackedVector2Array([
			Vector2(0.610, 0.106), Vector2(-0.527, 0.106),
		]),
		"wheel_r": 0.119,
	},
}

# Cache of convex decompositions, built on first use per model. `draw_colored_polygon` is
# happiest with convex input (see overworld_map.gd's glyph header), and a traced car outline is
# concave at the wheel gap and under the windscreen, so each outline is split once into convex
# pieces and the pieces are reused for every subsequent draw — the pins repaint every frame.
static var _convex: Dictionary = {}


## Whether anything is baked for this model id. The caller's cue to use its own generic glyph.
static func has(model_id: String) -> bool:
	return SILHOUETTES.has(model_id)


## The traced outline for a model id, or an EMPTY array when nothing is baked for it — the
## caller must fall back to its own generic shape rather than drawing nothing.
static func outline(model_id: String) -> PackedVector2Array:
	var shape: Dictionary = SILHOUETTES.get(model_id, {})
	return shape.get("outline", PackedVector2Array())


## The two wheel CENTRES, in the same unit box as the outline. Empty for an unknown model.
static func wheels(model_id: String) -> PackedVector2Array:
	var shape: Dictionary = SILHOUETTES.get(model_id, {})
	return shape.get("wheels", PackedVector2Array())


## The wheel radius, in the same unit box as the outline. 0.0 for an unknown model.
static func wheel_radius(model_id: String) -> float:
	var shape: Dictionary = SILHOUETTES.get(model_id, {})
	return float(shape.get("wheel_r", 0.0))


## The silhouette as convex pieces, ready to hand to `draw_colored_polygon` one at a time.
## Empty for an unknown model, and empty (not partial) if the decomposition fails.
static func convex_pieces(model_id: String) -> Array:
	if _convex.has(model_id):
		return _convex[model_id]
	var poly := outline(model_id)
	var pieces: Array = []
	if poly.size() >= 3:
		for piece: PackedVector2Array in Geometry2D.decompose_polygon_in_convex(poly):
			if piece.size() >= 3:
				pieces.append(piece)
	_convex[model_id] = pieces
	return pieces
