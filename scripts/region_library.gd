class_name RegionLibrary
extends RefCounted
# Authored catalogue of REGIONS (parallel to RallyLibrary.RALLIES). A region groups
# rallies by their `region` tag and carries optional look overrides for the driven
# world (grass/gravel/sky/fog/tints/layers) — a missing key inherits the scene /
# GameConfig baseline. Regions unlock in sequence (derived from showdown completion),
# and each region has exactly one showdown. See features/regions.md.

# The home region's satellite map, used when a region authors no `map_image` of
# its own (the home region ships override-free — see REGIONS below).
const DEFAULT_MAP_IMAGE := "res://textures/map_table.jpg"

# Whitelisted look-override keys (used by look_of + world.gd).
const LOOK_KEYS := [
	"map_image", "sky_panorama", "grass_texture", "gravel_texture",
	"tree_mix", "bush_billboard", "spawn_bush_mesh", "background_color",
	"terrain_tint", "terrain_layers",
]

# The home region's billboard tree (also the fallback when a region authors no
# `tree_mix`). Its "profile" selects the GameConfig sizing/jitter block a species
# uses — "home" → tree_size_m et al., "region" → region_tree_billboard_size_m et al.
# (see Foliage.spawn_trees). All balance values stay in GameConfig; the region only
# authors WHICH texture, WHICH profile, and the mix WEIGHT.
const DEFAULT_TREE_MIX: Array = [
	{"texture": "res://textures/tree.png", "profile": "home", "weight": 1.0},
]

const REGIONS: Array[Dictionary] = [
	# Region 0 — the existing world. It authors its foliage split explicitly so the
	# split is config-driven everywhere (100% home tree.png, 3D ground-cover bushes
	# on); every other look field inherits the scene (main.tscn / hq_environment) +
	# GameConfig baseline unchanged, so the home world still looks byte-identical.
	{
		"id": "home", "name": "Rally Country",
		"tree_mix": [
			{"texture": "res://textures/tree.png", "profile": "home", "weight": 1.0},
		],
		"spawn_bush_mesh": true,
	},
	# Region 1 — Greece. Ships the three swapped textures + sky, plus a Greek tree
	# split: 70% the star-shaped Greek billboard (tree-greece.webp, a large low, dry
	# Mediterranean canopy — the "region" sizing profile) and 30% the home tree.png
	# (the smaller "home" profile), so the arid stands read as mostly-olive with a few
	# ordinary trees mixed in. spawn_bush_mesh = false drops the green 3D ground-cover
	# bushes entirely (the arid map has no lush undergrowth). Tints inherit home for now.
	{
		"id": "greece", "name": "Greece",
		"map_image": "res://textures/greece.png",
		"sky_panorama": "res://textures/sky-greece.jpg",
		"grass_texture": "res://textures/grass-greece.jpg",
		"tree_mix": [
			{"texture": "res://textures/tree-greece.webp", "profile": "region", "weight": 0.7},
			{"texture": "res://textures/tree.png", "profile": "home", "weight": 0.3},
		],
		"spawn_bush_mesh": false,
		"gravel_texture": "res://textures/gravel-greece.jpg",
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

static func is_final(region_id: String) -> bool:
	var i := index_of(region_id)
	return i >= 0 and i == count() - 1

static func region_for_rally(rally_id: String) -> Dictionary:
	return by_id(String(RallyLibrary.by_id(rally_id).get("region", "")))

static func rallies_in(region_id: String) -> Array:
	var out: Array = []
	for rally in RallyLibrary.all():
		if String(rally.get("region", "")) == region_id:
			out.append(rally)
	return out

static func showdown_of(region_id: String) -> Dictionary:
	for rally in rallies_in(region_id):
		if bool(rally.get("showdown", false)):
			return rally
	return {}

static func unlocked(region_id: String, profile: Dictionary) -> bool:
	var i := index_of(region_id)
	if i <= 0:
		return i == 0  # first region always open; unknown id → false
	var prev := all()[i - 1]
	var prev_sd := showdown_of(String(prev.get("id", "")))
	var rallies: Dictionary = profile.get("rallies", {})
	return rallies.get(prev_sd.get("id", ""), {}).get("completed", false)

static func showdown_unlocked(region_id: String, profile: Dictionary) -> bool:
	# A region's showdown can't be "unlocked" if the region itself isn't reachable
	# yet (guards a region whose non-showdown rallies happen to be vacuously all
	# "done" only because it has none authored, or none completed via direct
	# profile manipulation in a test — the region gate must hold first).
	if not unlocked(region_id, profile):
		return false
	var rallies: Dictionary = profile.get("rallies", {})
	for rally in rallies_in(region_id):
		if bool(rally.get("showdown", false)):
			continue
		if not rallies.get(rally["id"], {}).get("completed", false):
			return false
	return true

# Whether a rally passes its region's showdown gate right now: non-showdown rallies
# always pass; a showdown passes only once its region's showdown is unlocked.
# (Completion is a separate check the callers do.) The one predicate shared by the
# eligibility query and the reward-draw walk.
static func rally_showdown_gate_open(rally: Dictionary, profile: Dictionary) -> bool:
	if not bool(rally.get("showdown", false)):
		return true
	return showdown_unlocked(String(rally.get("region", "")), profile)

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

static func look_of(region_id: String) -> Dictionary:
	var region := by_id(region_id)
	var look: Dictionary = {}
	for key in LOOK_KEYS:
		if region.has(key):
			look[key] = region[key]
	return look
