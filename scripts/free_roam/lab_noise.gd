class_name LabNoise
extends RefCounted
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# The road-network lab's random numbers and noise (tools/road_network_lab.html), reproduced
# bit for bit, so the game builds the same island as the lab for the same seed. JavaScript
# does this maths in 32-bit integers, so every step here is masked back to 32 bits.

const U32 := 0xFFFFFFFF


# The low 32 bits of a 32-bit product (JavaScript's Math.imul), done in two halves so the
# intermediate product never overflows a 64-bit int.
static func imul(a: int, b: int) -> int:
	a &= U32
	b &= U32
	var lo := (a * (b & 0xFFFF)) & U32
	var hi := ((a * (b >> 16)) & 0xFFFF) << 16
	return (lo + hi) & U32


# Every hash constant is below 2³¹, so a 32-bit value times one never overflows a 64-bit int
# and the product can simply be masked; only Rng needs the split multiply above.
static func hash2(x: int, y: int, s: int) -> float:
	var h := (((x & U32) * 374761393) & U32) ^ (((y & U32) * 668265263) & U32) ^ (((s & U32) * 2147483647) & U32)
	h = ((h ^ (h >> 13)) * 1274126177) & U32
	return float(h ^ (h >> 16)) / 4294967296.0


# hash2 written out at the four corners, since calls are what cost most in GDScript.
static func vnoise(x: float, y: float, s: int) -> float:
	var xi := floorf(x)
	var yi := floorf(y)
	var xf := x - xi
	var yf := y - yi
	var u := xf * xf * (3.0 - 2.0 * xf)
	var v := yf * yf * (3.0 - 2.0 * yf)
	var ix := int(xi)
	var iy := int(yi)
	var hx0 := ((ix & U32) * 374761393) & U32
	var hx1 := (((ix + 1) & U32) * 374761393) & U32
	var hy0 := ((iy & U32) * 668265263) & U32
	var hy1 := (((iy + 1) & U32) * 668265263) & U32
	var hs := ((s & U32) * 2147483647) & U32
	var h := hx0 ^ hy0 ^ hs
	h = ((h ^ (h >> 13)) * 1274126177) & U32
	var a := float(h ^ (h >> 16)) / 4294967296.0
	h = hx1 ^ hy0 ^ hs
	h = ((h ^ (h >> 13)) * 1274126177) & U32
	var b := float(h ^ (h >> 16)) / 4294967296.0
	h = hx0 ^ hy1 ^ hs
	h = ((h ^ (h >> 13)) * 1274126177) & U32
	var c := float(h ^ (h >> 16)) / 4294967296.0
	h = hx1 ^ hy1 ^ hs
	h = ((h ^ (h >> 13)) * 1274126177) & U32
	var d := float(h ^ (h >> 16)) / 4294967296.0
	return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v


const _GX := [1.0, -1.0, 0.0, 0.0, 0.7071067811865476, -0.7071067811865476, 0.7071067811865476, -0.7071067811865476]
const _GY := [0.0, 0.0, 1.0, -1.0, 0.7071067811865476, 0.7071067811865476, -0.7071067811865476, -0.7071067811865476]


# Classic 2D gradient (Perlin) noise: a hashed gradient at each lattice corner, quintic fade.
static func perlin(x: float, y: float, s: int) -> float:
	var xi := floorf(x)
	var yi := floorf(y)
	var xf := x - xi
	var yf := y - yi
	var ix := int(xi)
	var iy := int(yi)
	var k00 := floori(hash2(ix, iy, s) * 8.0)
	var k10 := floori(hash2(ix + 1, iy, s) * 8.0)
	var k01 := floori(hash2(ix, iy + 1, s) * 8.0)
	var k11 := floori(hash2(ix + 1, iy + 1, s) * 8.0)
	var n00: float = _GX[k00] * xf + _GY[k00] * yf
	var n10: float = _GX[k10] * (xf - 1.0) + _GY[k10] * yf
	var n01: float = _GX[k01] * xf + _GY[k01] * (yf - 1.0)
	var n11: float = _GX[k11] * (xf - 1.0) + _GY[k11] * (yf - 1.0)
	var u := xf * xf * xf * (xf * (xf * 6.0 - 15.0) + 10.0)
	var v := yf * yf * yf * (yf * (yf * 6.0 - 15.0) + 10.0)
	var nx0 := n00 + (n10 - n00) * u
	var nx1 := n01 + (n11 - n01) * u
	return nx0 + (nx1 - nx0) * v


static func fbm(x: float, y: float, s: int) -> float:
	return vnoise(x, y, s) * 0.6 + vnoise(x * 2.1, y * 2.1, s + 7) * 0.3 + vnoise(x * 4.3, y * 4.3, s + 13) * 0.1


static func smooth(a: float, b: float, x: float) -> float:
	var t := maxf(0.0, minf(1.0, (x - a) / (b - a)))
	return t * t * (3.0 - 2.0 * t)


static func hyp(x: float, y: float) -> float:
	return sqrt(x * x + y * y)


# The lab's seeded random stream (mulberry32).
class Rng:
	var _a := 0

	func _init(seed_value: int) -> void:
		_a = seed_value & LabNoise.U32

	func next() -> float:
		_a = (_a + 0x6D2B79F5) & LabNoise.U32
		var t := LabNoise.imul(_a ^ (_a >> 15), 1 | _a)
		t = ((t + LabNoise.imul(t ^ (t >> 7), 61 | t)) & LabNoise.U32) ^ t
		return float(t ^ (t >> 14)) / 4294967296.0
