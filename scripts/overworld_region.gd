class_name OverworldRegion
extends RefCounted
# Positional region lookup for the overworld HQ — the per-POSITION counterpart to
# world.gd::_current_region_look(), which resolves ONE region for a whole world and
# caches it for the scene's lifetime. In the life-size map there is no single answer:
# the player drives from one corner into another, so the region has to be a function of
# where the car is. See docs/superpowers/specs/2026-08-17-overworld-hq-design.md,
# slice 4, and features/regions.md.
#
# WHY THE NEAREST PIN, AND WHY NOTHING IS AUTHORED HERE
# ----------------------------------------------------
# No region footprint exists anywhere in GDScript, and this file deliberately does not
# add one. The footprint is defined implicitly by tools/fit_map_pins.py, whose
# `usable()` accepts a pin only when it lies within REGION_REACH (0.22) of one of that
# region's ORIGINAL pins — i.e. a region's territory is the union of discs around its
# own pins. The runtime restatement of that rule is a Voronoi over the shipped pin set:
# the region of the NEAREST rally pin. That needs no new authoring, and it re-derives
# for free whenever a pin moves — the same property that lets `map_pos` double as the
# progression graph (features/map-exploration.md).
#
# Nothing here hardcodes a region id or a rally id (beyond the documented "home"
# fallback, which world.gd already hardcodes as its own default), and the pin set comes
# from RallyLibrary.all(), so a test that installs a synthetic roster through the
# Registry.Seam override gets a Voronoi over the synthetic pins.
#
# HOT PATHS
# ---------
# region_at() and look_at() are cheap but linear in the roster; region_weights_at()
# allocates a small Dictionary. NEITHER IS FOR THE PER-WHEEL PHYSICS PATH. For grip,
# use surface_grip_scratch_at(), which mirrors Drivetrain.surface_tire_params' reused
# scratch dict — see its docstring.

# The documented fallback region id. world.gd::_current_region_look() hardcodes "home"
# as its default/challenge/fallback, and region_library.gd's header calls the id
# load-bearing for exactly that reason, so an empty roster resolves here rather than to
# an empty string that RegionLibrary would then fail to look up.
const FALLBACK_REGION := "home"

# Blend cutoff for region_weights_at(), as a MULTIPLE of the nearest pin's distance: a
# pin further than nearest_distance * BLEND_SPREAD contributes nothing. Expressed as a
# ratio rather than an absolute map distance so the blend band scales with how densely
# the roster is pinned — a crowded corner cross-fades over a short span, a sparse one
# over a long span, and neither needs retuning when the roster grows.
const BLEND_SPREAD := 1.6

# How many pins may contribute to one blend. A cap keeps the query allocation-light and
# bounds the dictionary size; four is enough for any junction of regions the Voronoi can
# actually produce.
const BLEND_MAX_PINS := 4

# Positional tolerance (normalised map units) for the memoised grip query. A move
# smaller than this reuses the previous answer outright. ~1 m on a 4 km map.
const GRIP_MEMO_EPSILON := 0.00025

# Derived Voronoi sites: [[Vector2 map_pos, String region_id], ...]. Rebuilt whenever
# the roster stamp changes.
var _sites: Array = []
# The roster stamp the sites were derived from. `null` = nothing derived yet, which can
# never compare equal to a real stamp (the hq._map_pins_stamp precedent).
var _sites_stamp = null

# Memoised grip state. `_grip_scratch` is handed out BY REFERENCE on every call, so it
# is filled in place and never reallocated.
var _grip_scratch: Dictionary = {}
var _grip_memo_pos := Vector2.INF
var _grip_memo_stamp = null
var _grip_memo_cfg: GameConfig = null


# The region id whose territory contains `map_pos` — the region of the nearest rally
# pin. FALLBACK_REGION for an empty roster.
func region_at(map_pos: Vector2) -> String:
	_ensure_sites()
	var best_id := FALLBACK_REGION
	var best_d2 := INF
	for site in _sites:
		var d2: float = (site[0] as Vector2).distance_squared_to(map_pos)
		if d2 < best_d2:
			best_d2 = d2
			best_id = site[1]
	return best_id


# Region id -> weight in 0..1, summing to 1.0, for cross-fading looks rather than
# snapping them (slice 4 blends ground textures, tints and sky between corners).
#
# Derived from the nearest BLEND_MAX_PINS pins, with any pin beyond
# nearest_distance * BLEND_SPREAD dropped and a squared linear falloff over what
# remains. Consequences of that shape, all intentional:
#   - deep inside a region every contributing pin belongs to it, so the blend collapses
#     to {region: 1.0} and costs nothing visually;
#   - exactly on a two-region boundary the two nearest pins are equidistant and split
#     50/50, so the cross-fade is symmetric and has no seam;
#   - the falloff is squared so the transition eases in at the far edge instead of
#     starting with a visible kink.
#
# Allocates one small Dictionary per call. Fine per frame for look blending; NOT for the
# per-wheel physics path — see surface_grip_scratch_at().
func region_weights_at(map_pos: Vector2) -> Dictionary:
	_ensure_sites()
	var out: Dictionary = {}
	if _sites.is_empty():
		out[FALLBACK_REGION] = 1.0
		return out

	# Nearest BLEND_MAX_PINS distances + ids, kept by insertion into fixed small arrays
	# so there is no sort and no intermediate array of the whole roster.
	var d: Array[float] = []
	var ids: Array[String] = []
	for site in _sites:
		var dist: float = (site[0] as Vector2).distance_to(map_pos)
		var slot := d.size()
		while slot > 0 and dist < d[slot - 1]:
			slot -= 1
		if slot >= BLEND_MAX_PINS:
			continue
		d.insert(slot, dist)
		ids.insert(slot, site[1])
		if d.size() > BLEND_MAX_PINS:
			d.resize(BLEND_MAX_PINS)
			ids.resize(BLEND_MAX_PINS)

	var nearest := d[0]
	# Standing on a pin: that region owns the point outright, and the falloff below
	# would divide by zero.
	if nearest <= 0.0:
		out[ids[0]] = 1.0
		return out

	var cutoff := nearest * BLEND_SPREAD
	var total := 0.0
	for i in range(d.size()):
		if d[i] >= cutoff:
			continue
		var t := 1.0 - d[i] / cutoff
		var w := t * t
		if w <= 0.0:
			continue
		out[ids[i]] = float(out.get(ids[i], 0.0)) + w
		total += w
	if total <= 0.0:
		out.clear()
		out[ids[0]] = 1.0
		return out
	for key in out:
		out[key] = float(out[key]) / total
	return out


# The whitelisted look overrides for the region at `map_pos` — the positional equivalent
# of world.gd's cached `_current_region_look()`. Resolution rules (including `look_from`
# inheritance) stay entirely inside RegionLibrary.look_of.
func look_at(map_pos: Vector2) -> Dictionary:
	return RegionLibrary.look_of(region_at(map_pos))


# The authored waterline in metres at `map_pos`, or `fallback` when the region there
# authors none.
#
# Gated on RegionLibrary.has_water_level rather than on the returned number, because
# water_level_of documents 0.0 as a REAL value (sea level) and not a sentinel — treating
# a zero as "absent" would silently substitute the GameConfig baseline for a region that
# deliberately authored sea level.
func water_level_at(map_pos: Vector2, fallback: float) -> float:
	var region_id := region_at(map_pos)
	if not RegionLibrary.has_water_level(region_id):
		return fallback
	return RegionLibrary.water_level_of(region_id)


# The per-surface grip scales at `map_pos` — {grass, gravel, tarmac} resolved from the
# GameConfig fields the region NAMES — or {} where the region overrides none.
#
# Gated on has_surface_grip for the same reason as above: {} is a real value meaning
# "inherit the authored baseline", and every non-alpine region relies on it.
#
# Allocates. For the per-wheel path use surface_grip_scratch_at().
func surface_grip_at(cfg: GameConfig, map_pos: Vector2) -> Dictionary:
	var region_id := region_at(map_pos)
	if not RegionLibrary.has_surface_grip(region_id):
		return {}
	return RegionLibrary.surface_grip_of(cfg, region_id)


# Memoised, allocation-free variant of surface_grip_at for the per-wheel contact path.
#
# INTENDED USAGE — identical to Drivetrain.surface_tire_params: the returned Dictionary
# is a REUSED scratch owned by this object. Read it immediately; never store it, never
# mutate it, and never hold two results at once, because the next call overwrites it in
# place. In exchange, a repeat call from a nearby position (within GRIP_MEMO_EPSILON, and
# with the same cfg and an unchanged roster) does no work and allocates nothing — which
# is the common case when four wheels query the same contact patch on the same frame.
#
# Empty means "this region overrides nothing; use the authored baseline", exactly as
# surface_grip_at's {} does.
func surface_grip_scratch_at(cfg: GameConfig, map_pos: Vector2) -> Dictionary:
	# Resolve the sites FIRST: a rebuild clears the memo, and doing it after the memo
	# write below would clear the entry we just made and turn every call into a miss.
	_ensure_sites()
	var stamp: Variant = _sites_stamp
	if (cfg == _grip_memo_cfg and stamp == _grip_memo_stamp
			and _grip_memo_pos.distance_squared_to(map_pos)
				<= GRIP_MEMO_EPSILON * GRIP_MEMO_EPSILON):
		return _grip_scratch
	_grip_memo_cfg = cfg
	_grip_memo_stamp = stamp
	_grip_memo_pos = map_pos
	_grip_scratch.clear()
	var region_id := region_at(map_pos)
	if not RegionLibrary.has_surface_grip(region_id):
		return _grip_scratch
	# Copy into the scratch rather than returning RegionLibrary's fresh dict, so the
	# identity callers are told to expect never changes.
	var resolved := RegionLibrary.surface_grip_of(cfg, region_id)
	for key in resolved:
		_grip_scratch[key] = resolved[key]
	return _grip_scratch


# --- Derivation + invalidation -------------------------------------------------

# Rebuild the Voronoi sites when the roster changed. A cheap stamp checked on demand rather
# than an explicit invalidate() call, so a test that swaps the roster through
# RallyLibrary.override_for_test gets a fresh answer instead of a stale one — a stale Voronoi
# would silently mis-colour the whole map.
#
# The stamp is the seam's SWAP COUNTER, not a hash of the roster's contents (see
# _roster_stamp). One consequence: mutating an entry IN PLACE inside an already-installed
# roster — a test poking rally["map_pos"] on the dict it handed to override_for_test — does
# not bump the counter and so does not invalidate. Re-install the roster instead of editing
# it under us.
func _ensure_sites() -> void:
	var stamp := _roster_stamp()
	if stamp == _sites_stamp:
		return
	_sites_stamp = stamp
	_sites = []
	for rally in RallyLibrary.all():
		var region_id := String(rally.get("region", ""))
		if region_id == "":
			continue
		_sites.append([RallyLibrary.map_pos_of(rally), region_id])
	# The memo is derived from the sites, so it dies with them.
	_grip_memo_pos = Vector2.INF
	_grip_memo_stamp = null


# The roster's swap counter (Registry.Seam.version), NOT a hash of its contents.
#
# This used to build an id/region/map_pos tuple per rally and hash the lot. That was
# correct but self-defeating: _ensure_sites runs BEFORE the memo check in
# surface_grip_scratch_at, which is called per wheel per physics tick, so the whole
# roster was allocated and hashed on every contact query and the allocation-free memo it
# guards never saved anything. An O(1) counter makes the guard as cheap as the memo
# assumes it is.
#
# The trade is deliberate: the counter also bumps for roster swaps that leave every
# id/region/map_pos unchanged, so a test that overrides with an identical roster now
# rebuilds the Voronoi. That is a rare, cheap false invalidation, and it errs toward
# recomputing — the opposite direction from a stale Voronoi silently mis-colouring the
# whole map, which is the failure this stamp exists to prevent.
func _roster_stamp() -> int:
	return RallyLibrary.roster_version()
