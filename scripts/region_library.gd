class_name RegionLibrary
extends RefCounted
# Docs: features/regions.md — update in the same change as this file.
# Tests: tests/headless/test_menu_flow.gd, tests/headless/test_menu_nav.gd, tests/headless/test_region_library.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'RegionLibrary' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).
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
# `map_image` (there is one world map now), `look_from` (the inherit-another-region's-look
# idiom, resolved by look_of before this filter — see the note above REGIONS) and
# `water_level` (needed by track generation, before the look is applied).
const LOOK_KEYS := [
	"sky_panorama", "grass_texture", "gravel_texture",
	"tree_mix", "bush_billboard", "spawn_bush_mesh", "background_color",
	"terrain_tint", "terrain_layers", "tarmac_color", "road_marking_color",
	"grass_particle_color", "grass_particle_square", "rock_density",
]

# The home region's billboard tree (also the fallback when a region authors no
# `tree_mix`). Its "profile" selects the GameConfig sizing/jitter block a species
# uses — "home" → tree_size_m et al., "region" → region_tree_billboard_size_m et al.
# (see Foliage.spawn_trees). Balance values stay in GameConfig; a species authors WHICH
# texture, WHICH profile, the mix WEIGHT, and optionally `size_scale` — a Vector2
# width/height multiplier on the profile's base size, stating that TEXTURE'S OWN
# proportions. That last one is art metadata rather than balance: the profile card is
# square, so without it a tall narrow cutout is stretched to 1:1 and drawn far too wide.
# Omitted (every home/Greece species) it is Vector2.ONE and changes nothing.
const DEFAULT_TREE_MIX: Array = [
	{"texture": "res://textures/tree.png", "profile": "home", "weight": 1.0},
]

# The four authored corners of the world map. ORDER CARRIES NO MEANING — regions do not
# unlock in sequence and there is no "final" region (credits fire once every special event
# is won, see RallyLibrary.all_specials_completed), so do NOT re-introduce any ordering
# dependency. Regions gate nothing: a region's only job is its LOOK and its waterline.
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
# with its own trees, `greece_coast` is greece with its own waterline. `water_level` is
# never inherited — every corner authors its own (see water_level_of). Ids are
# load-bearing: "home" is hardcoded in world.gd._current_region_look(), so never rename it.
#
# ADDING A ROW HERE IS A FOUR-PART CHANGE, and part 2 is the one that ships half-done: a
# REGIONS entry is INERT alone — a rally's `region` tag is the only thing that ever
# selects a region, so an untagged one renders nowhere.
#   1. the row below (never invent a filename — `ls textures/`, see above);
#   2. reachability: ADD A NEW RALLY to RallyLibrary.RALLIES (scripts/rally_library.gd) —
#      paste the template below and edit the # EDIT fields. Do NOT satisfy this by
#      retagging an existing rally: that goes green while silently restyling a rally whose
#      map_pos and authored weather belong to its OLD region (a probe moved a mid-map
#      fog/night rally into an arid canyon that way). Guarded by test_region_assets.gd ->
#      test_every_region_is_reachable_from_at_least_one_rally.
#
#      {
#          "id": "<region_id>_trial", "name": "<Rally Name>",     # EDIT both
#          "region": "<region_id>",                               # EDIT: your new region's id
#          "difficulty": 2, "special": false, "restriction": {},  # {} = open to every car
#          "map_pos": Vector2(0.05, 0.46),  # PASTE AS-IS — a currently-free pin, legal today
#              # (clear of every authored pin and of HQ by well over RallyLibrary.MIN_PIN_SEPARATION,
#              # and close enough to an existing pin to be reachable). A guard test keeps this
#              # literal honest: test_the_template_map_pos_is_still_a_legal_free_pin reddens and
#              # prints a replacement if someone authors a pin near it.
#              # Want it in a specific corner instead? `RallyLibrary.suggest_map_pos("<region_id>")`
#              # computes one at runtime — but you do NOT need to run anything to use this row.
#          "events": [  # 3 stages. `water_level` should match the region's own waterline, and
#              # the stages must NOT all share one weather (test_every_multi_stage_rally_mixes_weather).
#              {"seed": 90001, "turn_count": 20, "forestiness": 0.5, "surface_mix": 0.4, "straightness": 0.85, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 28.0},
#              {"seed": 90002, "turn_count": 20, "forestiness": 0.5, "surface_mix": 0.4, "straightness": 0.85, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 28.0, "weather": "rain"},
#              {"seed": 90003, "turn_count": 21, "forestiness": 0.5, "surface_mix": 0.4, "straightness": 0.85, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 28.0},
#          ],
#      },
#      Those are every field a rally needs; `prize_car`, `reveal_radius` and per-event
#      `weather` are optional (and "sandstorm" is desert-only, test-enforced).
#   3. features/regions.md — the prose region list (test_region_docs.gd fails on this);
#   4. features/terrain.md if the row changes how terrain is built.
const REGIONS: Array[Dictionary] = [
	# The existing world. It authors its foliage split explicitly so the split is
	# config-driven everywhere (100% home tree.png, 3D ground-cover bushes on); every
	# other look field inherits the scene (main.tscn / hq_environment) + GameConfig
	# baseline unchanged, so the home world still looks byte-identical.
	{
		"id": "home", "name": "Rally Country",
		"water_level": -12.0,
		# size_scale 1.25 uniform — the home forest 25% bigger than the profile's
		# authored card (7.5 -> 9.375 m). Done HERE, on the species, rather than by
		# raising GameConfig.tree_size_m, because that profile is shared: Greece's 30%
		# of ordinary trees, both Alps conifers and the taiga spire all sit on it, and
		# all four are tuned relative to its current value. Bumping the profile would
		# silently scale every one of them. This scales the home forest and nothing else
		# (home_coast included, since it inherits this whole block — same forest).
		#
		# Uniform on both axes on purpose: it changes SIZE only, leaving the billboard
		# at the 1:1 the square profile card already gave it. tree.png's cutout is
		# actually 164x256 (w/h 0.64), so it has always been drawn wider than its own
		# proportions — correcting that is a separate, much more visible change than
		# the one asked for here, so it is deliberately left alone.
		"tree_mix": [
			{"texture": "res://textures/tree.png", "profile": "home", "weight": 1.0,
			 "size_scale": Vector2(1.25, 1.25)},   # 9.375 x 9.375 m
		],
		"spawn_bush_mesh": true,
	},
	# The same forest look with the sea raised — a lakeland / forested shore.
	{
		"id": "home_coast", "name": "The Lakes",
		"look_from": "home",
		"water_level": -5.0,
	},
	# The taiga — the NW corner. Deliberately the THINNEST region in the catalogue:
	# `look_from: "home"` takes home's sky, gravel, tarmac, lane paint, terrain tints
	# and ground cover wholesale, and the ONLY thing overridden is which tree grows
	# there. That is the entire design. A boreal forest is not a different planet from
	# a temperate one — same grey overcast, same dirt, same green ground — it is the
	# same country with a different tree, and every extra override would blur the one
	# signal that actually separates the two corners.
	#
	# Which puts all the weight on the silhouette, hence the size_scale. The spire's
	# natural w/h is 0.30 (the narrowest cutout in the source pack — see
	# tools/gen_taiga_tree.py), so x is 0.30 * y to draw it at its own proportions
	# rather than stretched to the profile's square card. KEEP THAT RELATIONSHIP if you
	# retune the height: raising y alone stretches the tree into a needle.
	#
	# y = 3.0 makes it 22.5 m against the home broadleaf's 7.5 m and the Alps' ~12.9 m —
	# three times the forest the player just drove through. Overscaled against a real
	# spruce (40-60 m exists, but not next to a 7.5 m broadleaf), and deliberately: the
	# corner shares every other look key with home, so the skyline is the ONLY thing
	# saying "somewhere else" and it has to say it from a moving car.
	#
	# spawn_bush_mesh stays inherited (true, from home) on purpose. Real taiga has a
	# dense low mat of shrub under the canopy, and the bare-trunked spire leaves a lot
	# of empty ground that wants filling — the opposite of Greece and the Alps, which
	# both drop ground cover.
	{
		"id": "taiga", "name": "The Taiga",
		"look_from": "home",
		"water_level": -12.0,
		"tree_mix": [
			{"texture": "res://textures/tree-taiga.webp", "profile": "home", "weight": 1.0,
			 "size_scale": Vector2(0.90, 3.0)},   # 6.75 x 22.5 m, ratio 0.30
		],
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
		# The stoniest region in the catalogue. It is the one place that authors NO 3D
		# ground cover (spawn_bush_mesh false above), so the verge here is bare in a way
		# no other region's is — rocks are what fills it, and the arid look wants them.
		"rock_density": 2.5,
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
	# The alpine NE corner. The one region that does more than look different: it is
	# also the first to influence HANDLING, via the two non-LOOK_KEYS blocks below.
	# See features/snow-region.md.
	#
	# Look: the road and the open ground are both snow — near-white, deliberately
	# textured rather than flat, because this renderer is unshaded with baked vertex
	# lighting and a dead-flat albedo reads as a silhouette with no form. Tarmac is
	# home's asphalt lightened, as a dusting rather than a different material.
	# Conifers only, and no 3D ground cover at all (nothing grows through snow).
	# grass_particle_color turns the wheel spray white — the home green would read as
	# grass blades flung off a snowfield.
	{
		"id": "snow", "name": "The Alps",
		"water_level": -12.0,
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
		# `size_scale` states each species' BASELINE PROPORTIONS. The profile card is
		# square (tree_size_m 7.5 x 7.5), so a billboard is stretched to 1:1 whatever
		# shape its cutout really is — and these conifers are tall and narrow (natural
		# w/h 0.49 and 0.63), so unscaled they were drawn at up to twice their real
		# width and read as fat christmas trees. The x values restore each texture's own
		# ratio; the y values add height, because a spruce stand wants to be taller than
		# the home broadleaf forest. Every other species omits the key and is therefore
		# untouched.
		#
		# Both pairs were then scaled by 1.5 across BOTH axes to grow the forest 50%
		# (4.1 x 8.6 -> 6.2 x 12.9, and 5.1 x 8.3 -> 7.7 x 12.4). Uniformly on both axes
		# on purpose: the ratio each x was chosen to restore survives a uniform multiply,
		# and scaling y alone would stretch these back into the needles the x values
		# exist to prevent. KEEP THAT RULE when resizing again — the trailing `ratio`
		# comments are the invariant to check against.
		"tree_mix": [
			{"texture": "res://textures/tree-snow.webp", "profile": "home", "weight": 0.6,
			 "size_scale": Vector2(0.825, 1.725)},   # 6.2 x 12.9 m, ratio 0.48
			{"texture": "res://textures/tree-snow-laden.webp", "profile": "home", "weight": 0.4,
			 "size_scale": Vector2(1.02, 1.65)},     # 7.7 x 12.4 m, ratio 0.62
		],
		# No undergrowth, same as Greece: under real snow cover there is nothing
		# growing through. A snowed version of the ground-cover clump was tried and
		# dropped — it read as debris scattered on the snow rather than as buried
		# shrubs, and the clean snow surface is the better look.
		"spawn_bush_mesh": false,
		# The sparsest rocks in the catalogue, for the same reason there is no
		# undergrowth: deep snow BURIES loose stone. What survives reads as the odd
		# boulder too big to be covered, so the few that remain are still worth having
		# — 0.0 would say this landscape has no rock in it at all, which is wrong for
		# the Alps. Kept low rather than absent.
		"rock_density": 0.3,
		"tarmac_color": Color(0.46, 0.47, 0.50),
		"grass_particle_color": Color(0.90, 0.92, 0.95),
		# ...and grass_particle_square makes it the right SHAPE as well as the right
		# colour. The off-road particle is modelled as a torn-up blade of grass — slim
		# and tall — which stays wrong when merely painted white: a snowfield throws
		# clods of powder, not white blades. This swaps it to the square the gravel
		# clod already uses, sized off the same wheel_particle_size_m, so the two can
		# never drift apart.
		"grass_particle_square": true,
		# NOT optional here, unlike in the other regions. world.gd drives BOTH
		# env.background_color and env.fog_light_color off this, and the scene baseline
		# in main.tscn is an olive green (0.482, 0.498, 0.403) chosen for the home
		# forest. Left unauthored, the Alps inherit it and the distant terrain hazes
		# GREEN behind white snow — the single most obvious thing wrong with the region
		# before this was set. (Greece gets away with inheriting it because olive haze
		# suits arid ground; snow does not.)
		#
		# Sampled from the horizon band of sky-snow.jpg (avg rgb 144,154,167) so the fog
		# resolves into the panorama instead of banding against it.
		"background_color": Color(0.567, 0.604, 0.658),
		# Lane paint is buried; road_marking_color is deliberately omitted rather than
		# set to white, which would read as fresh paint on a snowy road.

		# --- Handling. NOT LOOK_KEYS, and deliberately so: these are consumed by
		# StageConfig.apply_event_config at stage setup, not by world.gd's look pass
		# after generation, so folding them into look_of would deliver them too late
		# AND leak non-look keys into the dict world.gd treats as look overrides. Same
		# reasoning that keeps `water_level` out of the whitelist.
		#
		# They name GameConfig fields rather than authoring numbers (the WeatherLibrary
		# pattern), so every tunable stays in config/game_config.tres.
		"surface_grip": {
			"grass": "snow_grass_grip",     # deep snow at the roadside
			"gravel": "snow_gravel_grip",   # packed snow road
			"tarmac": "snow_tarmac_grip",   # a dusting over asphalt
		},
		"deep_snow": {
			"depth": "snow_visual_depth_m",
			"drag": "snow_deep_drag",
		},
		# The lakes up here are FROZEN: the water plane becomes a solid surface the car
		# drives out onto and slides across, instead of the soft drag hazard it is in
		# every other region. Same config-block indirection as the two blocks above.
		# Only the GRIP is named here. The ice colours are read straight off GameConfig
		# by LakeField.build — they are a global look for ice, not a per-region choice,
		# and naming them here would be data nothing reads.
		"frozen_water": {"grip": "ice_grip"},
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


# --- Handling overrides (features/snow-region.md) -----------------------------
# A region may override the per-surface grip scales and author a deep-snow block. Both
# are read at stage setup by StageConfig.apply_event_config, NOT through look_of — see
# the comment on the snow entry for why they are not LOOK_KEYS.
#
# Like water_level, each is a has_*/­*_of PAIR rather than one function returning a
# sentinel: GDScript has no null, and "the region authors no override" must never be
# confused with a real value. Callers gate on the has_* before trusting the resolver.
#
# Also like water_level, NEITHER is inherited through `look_from`. A snow-coast child
# would author its own or have none — "same look, own handling" is the same split that
# makes the coastal regions work.

# The three per-surface μ scales this region overrides, resolved from the GameConfig
# fields it NAMES (it never authors numbers, so all tuning stays in game_config.tres).
# {} when the region authors none — the overwhelmingly common case, and the reason
# every other region's grip is byte-identical to the authored baseline.
static func surface_grip_of(cfg: GameConfig, region_id: String) -> Dictionary:
	return _resolve_fields(cfg, by_id(region_id).get("surface_grip", {}))

# Whether this region overrides per-surface grip at all. False for an unknown id.
static func has_surface_grip(region_id: String) -> bool:
	return by_id(region_id).has("surface_grip")

# The deep-snow block — {depth, drag} — resolved from the named GameConfig fields.
# {} when the region authors none, which is how every non-snow stage gets a zero
# drag and a zero visual raise for free.
static func deep_snow_of(cfg: GameConfig, region_id: String) -> Dictionary:
	return _resolve_fields(cfg, by_id(region_id).get("deep_snow", {}))

# Whether this region authors deep snow at all. False for an unknown id.
static func has_deep_snow(region_id: String) -> bool:
	return by_id(region_id).has("deep_snow")

# The frozen-lake block — {grip, color, shore_color} — resolved from the named
# GameConfig fields. {} when the region's water is liquid, which is every region but
# the Alps, so the lake stays the soft hazard it has always been by default.
static func frozen_water_of(cfg: GameConfig, region_id: String) -> Dictionary:
	return _resolve_fields(cfg, by_id(region_id).get("frozen_water", {}))

# Whether this region's water is frozen at all. False for an unknown id.
static func has_frozen_water(region_id: String) -> bool:
	return by_id(region_id).has("frozen_water")

# Shared resolver for a {key: <GameConfig field name>} block.
#
# Returns the config values AS-IS, deliberately un-coerced: these blocks name floats
# today but nothing about the pattern is numeric, and an earlier float() here crashed
# rally start the moment a block named a Color field. Callers coerce at the point of
# use, where the expected type is actually known.
#
# A field the config does not carry is SKIPPED rather than defaulted, so a typo shows up
# as the baseline value plus a warning, never as a silent 0.0 that would read as
# "no grip at all".
static func _resolve_fields(cfg: GameConfig, block: Dictionary) -> Dictionary:
	var out := {}
	if cfg == null:
		return out
	for key in block:
		var field := String(block[key])
		if field == "":
			continue
		# Test the RESOLVED VALUE for null rather than probing the property with `in`:
		# on an Object `in` does not mean "has this property", so it let a mis-named
		# field through to float(null) — which fails as "Nonexistent 'float'
		# constructor" at rally start rather than anywhere near the typo.
		var value: Variant = cfg.get(field)
		if value != null:
			out[key] = value
		else:
			push_warning("RegionLibrary: '%s' names GameConfig.%s, which does not exist"
				% [key, field])
	return out

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

# How many rocks this region scatters, as a MULTIPLIER on GameConfig.rock_groups_per_turn
# (see features/rocks.md). 1.0 is the unremarkable middle every region gets by default;
# stony regions author more, and a region whose ground is buried under snow authors
# less. Clamped non-negative — 0.0 is a legitimate authoring choice meaning "no rocks
# here", and negative would otherwise flip the scatter's cell maths.
#
# Density is the ONLY thing a region varies about rocks: the models, colours and
# hitboxes are shared everywhere, so a boulder reads the same wherever you meet it.
static func rock_density(look: Dictionary) -> float:
	return maxf(float(look.get("rock_density", 1.0)), 0.0)

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
