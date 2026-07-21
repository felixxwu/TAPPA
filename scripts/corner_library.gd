class_name CornerLibrary
extends RefCounted
# The rally pacenote turn-type shapes. Each corner is a 2D bezier (Curve2D),
# hand-authored as control points in meters, entry at the origin heading +Y,
# right-hand turns. The number gradient 1-6 goes from sharpest/tightest (1, ~85
# deg, ~18 m radius) to gentlest (6, ~12 deg, ~108 m radius); Square is a sharp
# ~90 deg, Hairpin ~180 deg (a 3-point curve), Straight a plain 50 m line. Turns
# 3-5 are tightened (smaller radius, same angle); turns 1, 2, Square and Hairpin
# carry a longer entry lead-in (a lengthened entry tangent) with their sharpness
# unchanged. The 2D curve is the source of truth; it will later be imprinted onto
# the 3D terrain surface.
#
# points entries: [position, in_control, out_control] (Vector2, meters); the
# in/out controls are relative to position, as Curve2D.add_point expects.

const CORNERS: Array[Dictionary] = [
	#                          position                in_control              out_control
	{
		"name": "1",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 10.001)],
			[Vector2(16.432, 17.932), Vector2(-9.298, -0.814), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "2",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),    Vector2(0.000, 16.649)],
			[Vector2(17.371, 24.808), Vector2(-10.429, -3.796), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "3",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 11.275)],
			[Vector2(14.738, 28.310), Vector2(-9.236, -6.467), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "4",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 13.426)],
			[Vector2(13.371, 35.559), Vector2(-7.344, -8.753), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "5",
		"points": [
			[Vector2(0.000, 0.000),  Vector2(0.000, 0.000),    Vector2(0.000, 16.491)],
			[Vector2(11.817, 43.708), Vector2(-6.492, -13.610), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "6",
		"points": [
			[Vector2(0.000, 0.000),  Vector2(0.000, 0.000),    Vector2(0.000, 18.347)],
			[Vector2(8.360, 65.854), Vector2(-5.170, -18.182), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "Square",
		"points": [
			[Vector2(0.000, 0.000), Vector2(0.000, 0.000),  Vector2(0.000, 13.953)],
			[Vector2(14.600, 14.600), Vector2(-13.302, 0.000), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "Hairpin",
		"points": [
			[Vector2(0.000, 0.000),  Vector2(0.000, 0.000),  Vector2(0.000, 11.457)],
			[Vector2(9.000, 15.000),  Vector2(-4.971, 0.000), Vector2(4.971, 0.000)],
			[Vector2(18.000, 0.000), Vector2(0.000, 11.971),  Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "Straight",
		"points": [
			[Vector2(0.000, 0.000),  Vector2(0.000, 0.000), Vector2(0.000, 0.000)],
			[Vector2(0.000, 75.000), Vector2(0.000, 0.000), Vector2(0.000, 0.000)],
		],
	},
]


# Assemble a Curve2D from one CORNERS entry. The single place point data becomes
# a curve, reused by the catalog scene and the tests.
static func build_curve(spec: Dictionary) -> Curve2D:
	var curve := Curve2D.new()
	for p in spec["points"]:
		curve.add_point(p[0], p[1], p[2])
	return curve
