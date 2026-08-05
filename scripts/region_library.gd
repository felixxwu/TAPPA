class_name RegionLibrary
extends RefCounted
# Authored catalogue of REGIONS (parallel to RallyLibrary.RALLIES). A region is one
# CORNER of the single world map: it groups rallies by their `region` tag and carries
# optional look overrides for the driven world (grass/gravel/sky/fog/tints/layers) — a
# missing key inherits the scene / GameConfig baseline — plus its own waterline.
# Regions do NOT unlock in sequence; every corner is open from the start, and a region
# gates nothing — it owns only its look and its waterline. See features/regions.md.

# The one world map. Every region is a corner of this single satellite image, so a
# region no longer owns a map image of its own — `map_image` is not a look key.
const DEFAULT_MAP_IMAGE := "res://textures/map_world.jpg"

# Whitelisted look-override keys (used by look_of + world.gd). Deliberately NOT here:
# `map_image` (there is one world map now), `look_from` (plumbing — see look_of) and
# `water_level` (needed by track generation, before the look is applied).
const LOOK_KEYS := [
	"sky_panorama", "grass_texture", "gravel_texture",
	"tree_mix", "bush_billboard", "spawn_bush_mesh", "background_color",
	"terrain_tint", "terrain_layers", "tarmac_color", "road_marking_color",
	"grass_particle_color",
]

# The home region's billboard tree (also the fallback when a region authors no
# `tree_mix`). Its "profile" selects the GameConfig sizing/jitter block a species
# uses — "home" → tree_size_m et al., "region" → region_tree_billboard_size_m et al.
# (see Foliage.spawn_trees). All balance values stay in GameConfig; the region only
# authors WHICH texture, WHICH profile, and the mix WEIGHT.
const DEFAULT_TREE_MIX: Array = [
	{"texture": "res://textures/tree.png", "profile": "home", "weight": 1.0},
]

# The four authored corners of the world map. ORDER CARRIES NO MEANING — regions do not
# unlock in sequence and there is no "final" region (credits fire once every special event
# is won, see RallyLibrary.all_specials_completed), so do NOT re-introduce any ordering
# dependency here.
#
# Regions no longer gate rallies AT ALL: the old one-showdown-per-region invariant is
# retired, and specials are gated on the global ordinary-completion count
# (RallyLibrary.rally_revealed via completions_required),
# so a corner may hold any number of them, including none. A region's only job is its LOOK
# and its waterline.
#
# Ids are load-bearing: "home" in particular is hardcoded in
# world.gd._current_region_look() as the default/challenge/fallback region, so never
# rename it. The coastal corners carry no look block of their own — they resolve their
# parent's via `look_from` — but each corner authors its OWN `water_level`, which is
# the whole point of the split (see water_level_of).
const REGIONS: Array[Dictionary] = [
	# The existing world. It authors its foliage split explicitly so the split is
	# config-driven everywhere (100% home tree.png, 3D ground-cover bushes on); every
	# other look field inherits the scene (main.tscn / hq_environment) + GameConfig
	# baseline unchanged, so the home world still looks byte-identical.
	{
		"id": "home", "name": "Rally Country",
		"water_level": -12.0,
		"tree_mix": [
			{"texture": "res://textures/tree.png", "profile": "home", "weight": 1.0},
		],
		"spawn_bush_mesh": true,
	},
	# The same forest look with the sea raised — a lakeland / forested shore.
	{
		"id": "home_coast", "name": "The Lakes",
		"look_from": "home",
		"water_level": -5.0,
	},
	# Greece. Ships the three swapped textures + sky, plus a Greek tree
	# split: 70% the star-shaped Greek billboard (tree-greece.webp, a large low, dry
	# Mediterranean canopy — the "region" sizing profile) and 30% the home tree.png
	# (the smaller "home" profile), so the arid stands read as mostly-olive with a few
	# ordinary trees mixed in. spawn_bush_mesh = false drops the green 3D ground-cover
	# bushes entirely (the arid map has no lush undergrowth). Terrain tints inherit home
	# for now, but the tarmac runs quite a bit brighter than home's (sun-bleached
	# Mediterranean asphalt) and its lane paint is yellow rather than home's off-white.
	# grass_particle_color overrides GameConfig's home-green wheel-dust blade with
	# the dry olive/tan of grass-greece.jpg (samples average ~(0.53, 0.50, 0.42);
	# the home green read as a mismatch flung off wheels on this arid ground).
	{
		"id": "greece", "name": "Greece",
		"water_level": -12.0,
		"sky_panorama": "res://textures/sky-greece.jpg",
		"grass_texture": "res://textures/grass-greece.jpg",
		"tree_mix": [
			{"texture": "res://textures/tree-greece.webp", "profile": "region", "weight": 0.7},
			{"texture": "res://textures/tree.png", "profile": "home", "weight": 0.3},
		],
		"spawn_bush_mesh": false,
		"gravel_texture": "res://textures/gravel-greece.jpg",
		"tarmac_color": Color(0.52, 0.50, 0.46),
		"road_marking_color": Color(0.85, 0.70, 0.16),
		"grass_particle_color": Color(0.52, 0.49, 0.38),
	},
	# The same arid look with the sea raised — the Mediterranean shoreline.
	{
		"id": "greece_coast", "name": "The Coast",
		"look_from": "greece",
		"water_level": -5.0,
	},
]

static var _seam := Registry.Seam.new(REGIONS)

static func all() -> Array[Dictionary]:
	return _seam.all()

static func override_for_test(regions: Array[Dictionary]) -> void:
	_seam.override_for_test(regions)

static func reset() -> void:
	_seam.reset()

static func count() -> int:
	return all().size()

static func by_id(id: String) -> Dictionary:
	return Registry.by_id(all(), id)

static func index_of(id: String) -> int:
	return Registry.index_of(all(), id)

static func id_at(i: int) -> String:
	return String(all()[i].get("id", ""))

# The region's authored waterline in metres, or 0.0 when it authors none — ALWAYS
# pair a call with has_water_level(), because callers resolve
# `event override → region → GameConfig baseline` and a region that authors nothing
# must fall through to the GameConfig baseline rather than to any number here.
# Deliberately NOT inherited through `look_from`: "home_coast is home, but the water
# is higher" only works if each corner authors its own waterline.
static func water_level_of(region_id: String) -> float:
	return float(by_id(region_id).get("water_level", 0.0))

# Whether this region authors a waterline at all (see water_level_of). False for an
# unknown id.
static func has_water_level(region_id: String) -> bool:
	return by_id(region_id).has("water_level")

static func region_for_rally(rally_id: String) -> Dictionary:
	return by_id(String(RallyLibrary.by_id(rally_id).get("region", "")))

static func rallies_in(region_id: String) -> Array:
	var out: Array = []
	for rally in RallyLibrary.all():
		if String(rally.get("region", "")) == region_id:
			out.append(rally)
	return out

# The tree species split for a resolved region look: the authored `tree_mix`, or the
# default single home tree when a region authors none (free roam / unknown id). Each
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
