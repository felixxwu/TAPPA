class_name MapFog
extends RefCounted
# The fog-of-war mask, shared by BOTH hubs.
#
# The world map is dark except where the player has driven (features/map-exploration.md). This
# builds that darkness as a small greyscale texture: 1 where the ground is lit, falling to 0
# across a soft band beyond each lit circle's rim.
#
# Two consumers, which is why it lives in a file of its own rather than in either hub:
#
#   * the HQ map table multiplies it into the map plane (`hq.gd::_apply_map_fog`);
#   * the overworld feeds the same texture to the terrain shader as a global uniform, so
#     unrevealed GROUND renders unlit (`overworld.gd::_push_fog_uniforms`).
#
# It reads `RallyLibrary.lit_sources` — the SAME derivation that decides which rallies are
# enterable — so what the player sees lit and what they can actually enter can never disagree.
# That is the whole reason the predicate was factored out, and it is why this must never grow a
# lookalike distance test of its own.
#
# Pure and static: profile in, texture out, no hub state touched.

# Mask resolution. Small on purpose — it is a smooth falloff field sampled with bilinear
# filtering, not artwork, and it is rebuilt whenever progress changes. 64x64 over the whole map
# is well under a texel per lit-circle rim at the shipped `map_reveal_radius`.
const MASK_SIZE := 64


# The lit mask for `profile`, in the same normalised 0..1 space as a rally's `map_pos`.
static func build(profile: Dictionary) -> ImageTexture:
	var sources := RallyLibrary.lit_sources(profile)
	var softness: float = maxf(Config.data.map_fog_edge_softness, 0.001)
	var img := Image.create(MASK_SIZE, MASK_SIZE, false, Image.FORMAT_R8)
	var step := 1.0 / float(MASK_SIZE)
	for y in MASK_SIZE:
		for x in MASK_SIZE:
			# Sample at the CENTRE of each cell, so the mask lines up with the map rather than
			# being shifted half a texel toward the origin.
			var p := Vector2((float(x) + 0.5) * step, (float(y) + 0.5) * step)
			var lit := 0.0
			for src in sources:
				var centre: Vector2 = src[0]
				var radius: float = src[1]
				# 1 inside, falling to 0 across the softness band beyond the rim. Max rather
				# than sum, so overlapping circles stay fully lit instead of blowing out.
				var d := p.distance_to(centre)
				lit = maxf(lit, clampf((radius - d) / softness + 1.0, 0.0, 1.0))
				if lit >= 1.0:
					break
			img.set_pixel(x, y, Color(lit, lit, lit))
	return ImageTexture.create_from_image(img)
