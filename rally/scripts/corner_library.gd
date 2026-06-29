class_name CornerLibrary
extends RefCounted
# The rally pacenote turn-type shapes. Each corner is a 2D bezier (Curve2D),
# hand-authored as control points in meters, entry at the origin heading +Y,
# right-hand turns. The number gradient 1-6 goes from sharpest/tightest (1, ~85
# deg, ~18 m radius) to gentlest (6, ~12 deg, ~108 m radius); Square is a sharp
# ~90 deg, Hairpin ~180 deg, Straight a plain 50 m line. "Right 4 tightens 2" is
# a compound example proving authored multi-point curves work. Every turn except
# the Hairpin (and the plain Straight) is scaled 1.2x larger than its original
# authored size: the angles are unchanged, only the radii/geometry grow. The 2D
# curve is the source of truth; it will later be imprinted onto the 3D terrain
# surface.
#
# points entries: [position, in_control, out_control] (Vector2, meters); the
# in/out controls are relative to position, as Curve2D.add_point expects.

const CORNERS: Array[Dictionary] = [
	#                          position                in_control              out_control
	{
		"name": "1",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 9.334)],
			[Vector2(16.432, 17.932), Vector2(-9.298, -0.814), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "2",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),    Vector2(0.000, 11.099)],
			[Vector2(17.371, 24.808), Vector2(-10.429, -3.796), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "3",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),    Vector2(0.000, 12.528)],
			[Vector2(16.375, 31.456), Vector2(-10.262, -7.186), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "4",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 12.696)],
			[Vector2(12.634, 39.510), Vector2(-8.160, -9.725), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "5",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),    Vector2(0.000, 14.990)],
			[Vector2(10.908, 48.564), Vector2(-7.213, -15.122), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "6",
		"points": [
			[Vector2(0.000, 0.000),  Vector2(0.000, 0.000),    Vector2(0.000, 18.347)],
			[Vector2(8.360, 60.854), Vector2(-5.170, -18.182), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "Square",
		"points": [
			[Vector2(0.000, 0.000), Vector2(0.000, 0.000),  Vector2(0.000, 5.302)],
			[Vector2(9.600, 9.600), Vector2(-5.302, 0.000), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "Hairpin",
		"points": [
			[Vector2(0.000, 0.000),  Vector2(0.000, 0.000),  Vector2(0.000, 4.971)],
			[Vector2(9.000, 9.000),  Vector2(-4.971, 0.000), Vector2(4.971, 0.000)],
			[Vector2(18.000, 0.000), Vector2(0.000, 4.971),  Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "Straight",
		"points": [
			[Vector2(0.000, 0.000),  Vector2(0.000, 0.000), Vector2(0.000, 0.000)],
			[Vector2(0.000, 50.000), Vector2(0.000, 0.000), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "Right 4 tightens 2",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 12.696)],
			[Vector2(12.634, 34.710), Vector2(-8.160, -9.725), Vector2(2.978, 3.550)],
			[Vector2(23.828, 42.548), Vector2(-4.355, -1.585), Vector2(0.000, 0.000)],
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
