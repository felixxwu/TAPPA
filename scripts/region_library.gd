class_name RegionLibrary
extends RefCounted
# Docs: features/regions.md — update in the same change as this file.
# Tests: tests/headless/test_region_library.gd, tests/headless/test_region_assets.gd, tests/headless/test_region_docs.gd — extend in the same change.
# Authored catalogue of region LOOKS (grass/gravel/sky/fog/tints, tree species). A
# missing key inherits the scene / GameConfig baseline. The live game reads only
# look_of("home"); see features/regions.md before building on the rest.


# Whitelisted look-override keys (used by look_of + the level). Deliberately NOT here:
# `map_image` (there is one world map now), `look_from` (the inherit-another-region's-look
# idiom, resolved by look_of before this filter — see the note above REGIONS).
const LOOK_KEYS := [
	"sky_panorama", "grass_texture", "gravel_texture",
	"tree_mix", "bush_billboard", "spawn_bush_mesh", "background_color",
	"terrain_tint", "grass_particle_color", "grass_particle_square", "dust_color",
]

# The home region's billboard tree (also the fallback when a region authors no
# `tree_mix`). Its "profile" selects the GameConfig sizing/jitter block a species
# uses — "home" → tree_size_m et al., "region" → region_tree_billboard_size_m et al.
# Balance values stay in GameConfig; a species authors WHICH
# texture, WHICH profile, the mix WEIGHT, and optionally `size_scale` — a Vector2
# width/height multiplier on the profile's base size, stating that TEXTURE'S OWN
# proportions. That last one is art metadata rather than balance: the profile card is
# square, so without it a tall narrow cutout is stretched to 1:1 and drawn far too wide.
# Omitted (every home/Greece species) it is Vector2.ONE and changes nothing.
const DEFAULT_TREE_MIX: Array = [
	{"texture": "res://textures/tree.png", "profile": "home", "weight": 1.0},
]

# The authored regions.
#
# NEVER INVENT AN ASSET FILENAME. Every res:// path authored here must be a file that
# already exists — the -greece/-snow naming convention makes made-up names look right,
# but a dangling sky_panorama/grass_texture/gravel_texture loads as null and ships as an
# untextured world with every test green. List textures/ and pick real files. Guarded by
# tests/headless/test_region_assets.gd -> test_every_authored_region_resource_path_resolves.
#
# A REGION THAT IS A VARIANT OF ANOTHER MUST NOT CLONE ITS LOOK BLOCK. Author
# `"look_from": "<other_region_id>"` and then only the keys that DIFFER — that is this
# table's authoring idiom, not internal plumbing. Worked examples below: `taiga` is home
# with its own trees. Ids are load-bearing: "home" is the default region, so never rename it.
#
# ADDING A ROW HERE:
#   1. the row below (never invent a filename — `ls textures/`, see above);
#   2. features/regions.md — the prose region list (test_region_docs.gd fails on this).
const REGIONS: Array[Dictionary] = [
	# The existing world. It authors its foliage split explicitly so the split is
	# config-driven everywhere (100% home tree.png, 3D ground-cover bushes on); every
	# other look field inherits the scene environment + GameConfig
	# baseline unchanged, so the home world still looks byte-identical.
	{
		"id": "home",
		# size_scale sets each species' size and card shape: height 9.375 m (the profile's 7.5
		# x 1.25), width = height x the atlas frame's aspect. It is done here, not on the
		# shared GameConfig profile, so the other species keep their tuned sizes.
		"tree_mix": [
			{"texture": "res://textures/tree.png", "profile": "home", "weight": 1.0,
			 "size_scale": Vector2(1.294, 1.25)}, # 9.375 m tall, frame aspect 1.035
		],
		"spawn_bush_mesh": true,
	},
	# The Greek-inspired arid region. Ships the three swapped textures
	# + sky, plus a Greek tree
	# split: 70% the star-shaped Greek billboard (tree-greece.webp, a large low, dry
	# Mediterranean canopy — the "region" sizing profile) and 30% the home tree.png
	# (the smaller "home" profile), so the arid stands read as mostly-olive with a few
	# ordinary trees mixed in. spawn_bush_mesh = false drops the green 3D ground-cover
	# bushes entirely (the arid map has no lush undergrowth). Terrain tints inherit home.
	# grass_particle_color overrides GameConfig's home-green wheel-dust blade with
	# the dry olive/tan of grass-greece.jpg (samples average ~(0.53, 0.50, 0.42);
	# the home green read as a mismatch flung off wheels on this arid ground).
	{
		"id": "greece",
		"sky_panorama": "res://textures/sky-greece.jpg",
		"grass_texture": "res://textures/grass-greece.jpg",
		"tree_mix": [
			{"texture": "res://textures/tree-greece.webp", "profile": "region", "weight": 0.7,
			 "size_scale": Vector2(1.273, 1.0)}, # frame aspect 1.273 at the profile height
			{"texture": "res://textures/tree.png", "profile": "home", "weight": 0.3},
		],
		"spawn_bush_mesh": false,
		"gravel_texture": "res://textures/gravel-greece.jpg",
		"grass_particle_color": Color(0.52, 0.49, 0.38),
		# Dust puffs on gravel take the gravel's colour (gravel-greece.jpg averages this).
		"dust_color": Color(0.74, 0.73, 0.65),
	},
	# The taiga — the NW corner. Deliberately the THINNEST region in the catalogue:
	# `look_from: "home"` takes home's sky, gravel, terrain tints
	# and ground cover wholesale, and the ONLY thing overridden is which tree grows
	# there. That is the entire design. A boreal forest is not a different planet from
	# a temperate one — same grey overcast, same dirt, same green ground — it is the
	# same country with a different tree, and every extra override would blur the one
	# signal that actually separates the two corners.
	#
	# Which puts all the weight on the silhouette, hence the size_scale: x = 0.31 * y matches
	# the spire's atlas frame aspect (0.310), so raise the height by scaling both axes.
	# y = 3.0 makes it 22.5 m against the home broadleaf's 7.5 m, deliberately: the
	# skyline is the ONLY thing saying "somewhere else" and it has to say it from a car.
	#
	# spawn_bush_mesh stays inherited (true, from home) on purpose. Real taiga has a
	# dense low mat of shrub under the canopy, and the bare-trunked spire leaves a lot
	# of empty ground that wants filling — the opposite of Greece and the Alps, which
	# both drop ground cover.
	{
		"id": "taiga",
		"look_from": "home",
		"tree_mix": [
			{"texture": "res://textures/tree-taiga.webp", "profile": "home", "weight": 1.0,
			 "size_scale": Vector2(0.93, 3.0)}, # 6.98 x 22.5 m, frame aspect 0.310
		],
	},
	# Home's look under another name; it used to differ only in its (now deleted) sea level.
	{
		"id": "home_coast",
		"look_from": "home",
	},
	# The alpine NE corner. See features/snow-region.md.
	#
	# Look: the road and the open ground are both snow — near-white, deliberately
	# textured rather than flat, because this renderer is unshaded with baked vertex
	# lighting and a dead-flat albedo reads as a silhouette with no form.
	# Conifers only, and no 3D ground cover at all (nothing grows through snow).
	# grass_particle_color turns the wheel spray white — the home green would read as
	# grass blades flung off a snowfield.
	{
		"id": "snow",
		"sky_panorama": "res://textures/sky-snow.jpg",
		"grass_texture": "res://textures/snow-ground.jpg",
		"gravel_texture": "res://textures/snow-road.jpg",
		# Two conifers rather than one, for a reason the art forced: the source pack's
		# densest spruce has the best silhouette but carries almost no snow, while the
		# one that genuinely does is shorter and scruffier. Mixing them gives a stand
		# that has both a strong skyline and visible snow load. 60/40 so the taller tree
		# sets the shape of the forest and the laden one breaks it up.
		# Both are CC0 photographs — see tools/gen_snow_trees.py for provenance.
		#
		# `size_scale` sets each species' height and width = height x its atlas frame aspect.
		# KEEP that ratio if you resize (scale both axes together); the trailing comments
		# state it.
		"tree_mix": [
			{"texture": "res://textures/tree-snow.webp", "profile": "home", "weight": 0.6,
			 "size_scale": Vector2(1.572, 1.72)}, # 12.9 m tall, frame aspect 0.914
			{"texture": "res://textures/tree-snow-laden.webp", "profile": "home", "weight": 0.4,
			 "size_scale": Vector2(1.556, 1.653)}, # 12.4 m tall, frame aspect 0.941
		],
		# No undergrowth, same as Greece: under real snow cover there is nothing
		# growing through. A snowed version of the ground-cover clump was tried and
		# dropped — it read as debris scattered on the snow rather than as buried
		# shrubs, and the clean snow surface is the better look.
		"spawn_bush_mesh": false,
		"grass_particle_color": Color(0.90, 0.92, 0.95),
		# ...and grass_particle_square makes it the right SHAPE as well as the right
		# colour. The off-road particle is modelled as a torn-up blade of grass — slim
		# and tall — which stays wrong when merely painted white: a snowfield throws
		# clods of powder, not white blades. This swaps it to the square the gravel
		# clod already uses, sized off the same wheel_particle_size_m, so the two can
		# never drift apart.
		"grass_particle_square": true,
		# Dust puffs on the snow road take its colour (snow-road.jpg averages this).
		"dust_color": Color(0.75, 0.76, 0.78),
		# NOT optional here, unlike in the other regions. The level drives BOTH
		# env.background_color and env.fog_light_color off this, and the scene baseline
		# is an olive green (0.482, 0.498, 0.403) chosen for the home
		# forest. Left unauthored, the Alps inherit it and the distant terrain hazes
		# GREEN behind white snow — the single most obvious thing wrong with the region
		# before this was set. (Greece gets away with inheriting it because olive haze
		# suits arid ground; snow does not.)
		#
		# Sampled from the horizon band of sky-snow.jpg (avg rgb 144,154,167) so the fog
		# resolves into the panorama instead of banding against it.
		"background_color": Color(0.567, 0.604, 0.658),
	},
]

static var _seam := Registry.Seam.new(REGIONS)

static func all() -> Array[Dictionary]:
	return _seam.all()

static func override_for_test(regions: Array[Dictionary]) -> void:
	_seam.override_for_test(regions)

static func reset() -> void:
	_seam.reset()

static func by_id(id: String) -> Dictionary:
	return Registry.by_id(all(), id)

static func index_of(id: String) -> int:
	return Registry.index_of(all(), id)


# The tree species split for a resolved region look: the authored `tree_mix`, or the
# default single home tree when a region authors none (unknown id). Each
# entry is {texture, profile, weight}; see DEFAULT_TREE_MIX. Pure — takes the look
# dict (from look_of), so callers don't re-resolve the region.
static func tree_mix(look: Dictionary) -> Array:
	var mix: Array = look.get("tree_mix", [])
	return mix if not mix.is_empty() else DEFAULT_TREE_MIX

# Whether the 3D ground-cover bush mesh spawns for this region look — config-driven,
# defaults true (a region that authors nothing keeps the bushes, like the base scene).
static func spawns_bush_mesh(look: Dictionary) -> bool:
	return bool(look.get("spawn_bush_mesh", true))

# The region's look overrides, filtered through the LOOK_KEYS whitelist. A region may
# author `"look_from": "<other_region_id>"` to inherit that region's look block (the
# coastal corners share their inland parent's look); the parent's whitelisted keys are
# resolved first and the region's own overlaid on top, so own keys win. ONE level only
# — a parent's own `look_from` is not followed, so chains/cycles are impossible.
# `look_from` is not a LOOK_KEY, so it never leaks into the returned dict.
static func look_of(region_id: String) -> Dictionary:
	var region := by_id(region_id)
	var look: Dictionary = {}
	var parent_id := String(region.get("look_from", ""))
	if parent_id != "" and parent_id != region_id:
		_collect_look(by_id(parent_id), look)
	_collect_look(region, look)
	return look

static func _collect_look(region: Dictionary, into: Dictionary) -> void:
	for key in LOOK_KEYS:
		if region.has(key):
			into[key] = region[key]
