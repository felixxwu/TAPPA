class_name CornerLibrary
extends RefCounted
# The rally pacenote turn-type shapes. Each corner is a 2D bezier (Curve2D),
# hand-authored as control points in meters, entry at the origin heading +Y,
# right-hand turns. The number gradient 1-6 goes from sharpest/tightest (1, ~85
# deg, ~15 m radius) to gentlest (6, ~12 deg, ~90 m radius); Square is a sharp
# ~90 deg, Hairpin ~180 deg, Straight a plain 50 m line. "Right 4 tightens 2" is
# a compound example proving authored multi-point curves work. The 2D curve is
# the source of truth; it will later be imprinted onto the 3D terrain surface.
#
# points entries: [position, in_control, out_control] (Vector2, meters); the
# in/out controls are relative to position, as Curve2D.add_point expects.

const CORNERS: Array[Dictionary] = [
	#                          position                in_control              out_control
	{
		"name": "1",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 7.778)],
			[Vector2(13.693, 14.943), Vector2(-7.748, -0.678), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "2",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 9.249)],
			[Vector2(14.476, 20.673), Vector2(-8.691, -3.163), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "3",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 10.440)],
			[Vector2(13.646, 26.213), Vector2(-8.552, -5.988), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "4",
		"points": [
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 10.580)],
			[Vector2(10.528, 32.925), Vector2(-6.800, -8.104), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "5",
		"points": [
			[Vector2(0.000, 0.000),  Vector2(0.000, 0.000),   Vector2(0.000, 12.492)],
			[Vector2(9.090, 40.470), Vector2(-6.011, -12.602), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "6",
		"points": [
			[Vector2(0.000, 0.000),  Vector2(0.000, 0.000),   Vector2(0.000, 15.289)],
			[Vector2(6.967, 50.712), Vector2(-4.308, -15.152), Vector2(0.000, 0.000)],
		],
	},
	{
		"name": "Square",
		"points": [
			[Vector2(0.000, 0.000), Vector2(0.000, 0.000),  Vector2(0.000, 4.418)],
			[Vector2(8.000, 8.000), Vector2(-4.418, 0.000), Vector2(0.000, 0.000)],
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
			[Vector2(0.000, 0.000),   Vector2(0.000, 0.000),   Vector2(0.000, 10.580)],
			[Vector2(10.528, 28.925), Vector2(-6.800, -8.104), Vector2(2.482, 2.958)],
			[Vector2(19.857, 35.457), Vector2(-3.629, -1.321), Vector2(0.000, 0.000)],
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
