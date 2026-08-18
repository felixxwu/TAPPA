class_name OverworldPads
extends RefCounted
# The overworld's FLAT PADS: a level circle of ground baked under every rally zone and under
# the garage, so the things that stand on those spots — a zone's light tube, its floating
# marker, its parked ghost car, and above all the GARAGE BUILDING — sit on level ground
# instead of straddling a slope. Geometry and queries ONLY; nothing here touches the scene
# tree, the terrain or a material. A second pass (TerrainManager._apply_pad_flatten, plus
# TerrainManager.pad_height inside the pure-noise generator) consumes `pad_at` /
# `pads_in_rect` and rewrites the ground.
#
# The shape of this class deliberately mirrors OverworldRoads: a duck-typed positional source
# with a cheap per-chunk reject (`pads_in_rect`), a per-point query (`pad_at`), an influence
# radius (`influence_m`) and a stable `stamp()` the chunk cache folds into its invalidation
# key. TerrainManager never references either type by class.
#
# DETERMINISM / PURITY
#
# Pure function of (roster pin positions, size, radii, feather, terrain height at the pad
# centres AND on a ring around each pad — see `_feather_for`). No RNG, no roster order dependence (the stamp sorts its per-pad parts), no scene
# state. Two builds with the same inputs answer identically, which is what lets the flattened
# ground be cached to disk.
#
# COORDINATE MAPPING IS INJECTED. `build()` takes a `to_world` Callable (Overworld's
# `_zone_world_pos`) so this file NEVER re-derives map_pos -> world XZ. The zone layer, the
# road network and the pads must all agree on where a pin is, and there is exactly one
# implementation of that conversion.
#
# PAD SHAPES — both pads are CIRCLES.
#
#   rally zone: radius `zone_radius_m`. Covers the trigger radius plus the tube base, the
#               marker's shadow and a parked ghost car.
#   garage:     radius `garage_radius_m`, which is larger. The building's footprint is a
#               RECTANGLE (`overworld_garage_bay_width_m` x `overworld_garage_bay_depth_m`,
#               7.5 x 12 m), and a rectangular pad would be the tight fit — but a circle
#               CIRCUMSCRIBING that rectangle (half-diagonal ~7.1 m) plus the forecourt the
#               player drives in across is just as level, needs no orientation (the pad would
#               otherwise have to know which way the building faces, coupling this file to
#               overworld_garage.gd), and keeps the query a single squared-distance test in
#               the per-vertex hot loop. The default `garage_radius_m` is comfortably larger
#               than that half-diagonal so the approach is level too.
#
# COST. `pad_at` runs PER VERTEX during chunk generation (2,601 per chunk), so it must not
# allocate: it returns a VECTOR2 (weight, target height) rather than a Dictionary. A Vector2
# lives inline in a Variant, so a per-vertex call is heap-allocation free — unlike
# OverworldRoads.road_at, whose Dictionary return cost 2,601 allocations per carved chunk until
# `road_at_into` was added beside it.
#
# CORRECTED: this note used to justify the stateless return by claiming compute_chunk_data runs
# on worker threads, so a reused scratch (the Drivetrain.surface_tire_params pattern) would be a
# data race. THERE ARE NO WORKER THREADS — `WorkerThreadPool`, `Thread` and `Mutex` appear in
# exactly one file in all of scripts/ (cloud/google_sign_in.gd), and target platforms include
# single-threaded ones (mobile web), so threads are not an available escape hatch either. A
# reused scratch would be perfectly safe here. The Vector2 return is still the right call, just
# for a plainer reason: two floats are all the query has to say, so a scratch would buy nothing
# and cost the caller a "read it before the next call" rule.


# --- Defaults (all overridable; GameConfig drives them via `from_config`) ----------------

## Radius (metres) of the level circle under a rally zone.
const DEFAULT_ZONE_RADIUS_M := 12.0
## Radius (metres) of the level circle under the garage. Larger — see "PAD SHAPES".
const DEFAULT_GARAGE_RADIUS_M := 16.0
## Width (metres) of the feather band OUTSIDE a pad's radius, over which the flatten ramps
## from full to nothing. This is the MINIMUM — a pad on uneven ground widens its own band until
## the ramp is under `_max_grade` (see `_feather_for`). Wide enough that the pad reads as a
## shaped clearing, not a mesa —
## and, more importantly, wide enough to stay DRIVABLE. The steepest grade a smoothstep
## feather can produce is 1.5 * (height difference across the pad) / feather width, so a 14 m
## band keeps a ~1.5 m step (about the worst the shipped terrain layers produce across a 16 m
## garage pad) near 16%, comfortably under the ~22% a FWD car can climb on snow grip
## (rally_library.gd). Narrowing this on a steep site is how you strand a player on the lip of
## the very pad they were driving to.
const DEFAULT_FEATHER_M := 14.0
## The steepest grade (rise / run) the feather ramp is allowed to reach, as a fraction. A pad
## whose surroundings are rough enough that the base feather would exceed this WIDENS its own
## band until the ramp is back under the cap — see `_feather_for`. 0.15 (15%) sits under the
## ~22% a FWD car climbs on snow grip, with margin for the fact that the ramp's steepest point
## is only an estimate of what the player actually drives across.
const DEFAULT_MAX_GRADE := 0.15
## Hard ceiling on a widened feather, metres. Past this the clearing would swallow half the
## neighbourhood; a pad on a cliff edge accepts a steeper lip rather than growing without bound.
const DEFAULT_MAX_FEATHER_M := 60.0
## Ring samples per widening iteration, and how many times the widening is re-evaluated. Each
## iteration re-samples at the ring the previous one landed on, so the estimate only ever grows
## and converges in two or three passes.
const _RING_SAMPLES := 16
const _WIDEN_PASSES := 3
## The id of the garage pad — exempt from the radius shrink (see `_shrink_to_fit`), and named
## once here rather than spelled as a literal in three places.
const HQ_PAD_ID := "__hq__"
## The most of its authored radius a crowded pad may give up, and the step it gives it up in.
## A pad still has to cover what stands on it, so the shrink is bounded, not free.
const _MIN_RADIUS_SHARE := 0.5
const _SHRINK_STEP_SHARE := 0.05
## Floor on `1 - w` when weighting overlapping pads, so a pad's INTERIOR (w == 1) outvotes its
## neighbours by ~1e6 : 1 and stays exactly flat, without an actual division by zero. See
## `pad_at` for why the weight is w/(1-w) and not the w^8 this replaced.
const _BLEND_EPSILON := 1e-6


# --- Parameters (immutable after construction) -------------------------------------------

var _zone_radius_m: float
var _garage_radius_m: float
var _feather_m: float
var _max_grade: float
var _max_feather_m: float

# --- Built state -------------------------------------------------------------------------

var _size_m := 0.0
var _built := false
# Flat, parallel per-pad arrays so the hot query allocates nothing.
var _px := PackedFloat32Array()   # world x of the pad centre
var _pz := PackedFloat32Array()   # world z of the pad centre
var _pr := PackedFloat32Array()   # pad radius (full flatten inside this)
var _ph := PackedFloat32Array()   # pad target height — the level the ground is driven to
var _pf := PackedFloat32Array()   # THIS pad's feather width (>= _feather_m; see _feather_for)
var _ids := PackedStringArray()   # pad id ("__hq__" for the garage), for the stamp only
# Largest built feather, so influence_m() stays conservative for the widened pads.
var _widest_feather_m := 0.0


## `p_`-prefixed parameters where the name would otherwise shadow the same-named getter
## below; warnings are errors in this project.
func _init(p_zone_radius_m: float = DEFAULT_ZONE_RADIUS_M,
		p_garage_radius_m: float = DEFAULT_GARAGE_RADIUS_M,
		p_feather_m: float = DEFAULT_FEATHER_M,
		p_max_grade: float = DEFAULT_MAX_GRADE,
		p_max_feather_m: float = DEFAULT_MAX_FEATHER_M) -> void:
	_zone_radius_m = maxf(p_zone_radius_m, 0.0)
	_garage_radius_m = maxf(p_garage_radius_m, 0.0)
	_feather_m = maxf(p_feather_m, 0.0)
	_max_grade = maxf(p_max_grade, 0.01)
	_max_feather_m = maxf(p_max_feather_m, _feather_m)
	_widest_feather_m = _feather_m


## Build from the authored tunables.
static func from_config(cfg: GameConfig) -> OverworldPads:
	return OverworldPads.new(cfg.overworld_pad_zone_radius_m,
		cfg.overworld_pad_garage_radius_m, cfg.overworld_pad_feather_m,
		cfg.overworld_pad_max_grade, cfg.overworld_pad_max_feather_m)


## Place one pad per rally pin plus one for the garage, and resolve each pad's LEVEL.
##
## `to_world` maps a normalised map_pos to a world position (Vector3; y ignored) — injected,
## never re-derived here. `height_at` answers the terrain's own GENERATED height at a world
## XZ; the pad's level is that height sampled AT THE PAD CENTRE, so a pad sits where the
## ground naturally is rather than at an arbitrary altitude.
##
## `height_at` MUST be the terrain's pure generator (TerrainManager._noise_height_at) and
## this build MUST run BEFORE the pads are attached as the terrain's pad source — otherwise
## the sample would read back a height the pads themselves had already flattened, and the
## pad level would depend on the order chunks were generated in.
## `hq_map_pos` is INJECTED for the same reason OverworldRoads takes it: the garage moves with the
## player's first-car rally, and this file stays a pure geometric builder.
func build(size_m: float, to_world: Callable, height_at: Callable,
		hq_map_pos: Vector2 = RallyLibrary.HQ_MAP_POS) -> void:
	_size_m = size_m
	_px = PackedFloat32Array()
	_pz = PackedFloat32Array()
	_pr = PackedFloat32Array()
	_ph = PackedFloat32Array()
	_pf = PackedFloat32Array()
	_ids = PackedStringArray()
	_widest_feather_m = _feather_m
	if to_world.is_valid():
		for rally in RallyLibrary.all():
			_add_pad(String(rally.get("id", "")), RallyLibrary.map_pos_of(rally),
				_zone_radius_m, to_world, height_at)
		_add_pad(HQ_PAD_ID, hq_map_pos, _garage_radius_m, to_world, height_at)
	# Feathers LAST, once every pad is placed: a band is capped by its nearest neighbour.
	_resolve_feathers(height_at)
	_built = true


func _add_pad(id: String, map_pos: Vector2, radius: float, to_world: Callable,
		height_at: Callable) -> void:
	if radius <= 0.0:
		return
	var w: Vector3 = to_world.call(map_pos)
	var level := _level_for(w.x, w.z, radius, height_at)
	_px.append(w.x)
	_pz.append(w.z)
	_pr.append(radius)
	_ph.append(level)
	_ids.append(id)


# THE PAD'S LEVEL — the mean of the terrain over the pad's own footprint, not the height at the
# single point in the middle.
#
# The centre sample is the obvious choice and it is the wrong one. A pin sitting on a local bump
# or in a dip takes its level from that bump, so the pad stands proud of (or sunk into) everything
# around it, and the ENTIRE offset has to be paid back across the feather — which is what makes
# the ramp steep in the first place. Averaging the disc puts the pad at the height the ground
# already has there, so the feather has roughly half as much work to do and the pad reads as a
# terrace cut into the slope rather than a plate dropped onto it.
#
# Sampled on two rings plus the centre rather than a full disc integral: the pads are placed once
# at load, but this runs per pad and the exact mean is not the point — halving the offset is.
# Deterministic and pure, like everything else here, so the cache stamp stays honest.
func _level_for(cx: float, cz: float, radius: float, height_at: Callable) -> float:
	if not height_at.is_valid():
		return 0.0
	var total := float(height_at.call(cx, cz))
	var count := 1.0
	if radius <= 0.0:
		return total
	for ring in [radius * 0.5, radius]:
		for s in _RING_SAMPLES:
			var a := TAU * float(s) / float(_RING_SAMPLES)
			total += float(height_at.call(cx + cos(a) * ring, cz + sin(a) * ring))
			count += 1.0
	return total / count


# Second pass over the placed pads, resolving every feather width. SEPARATE FROM PLACEMENT on
# purpose: a pad's band is capped by its NEAREST NEIGHBOUR (see `_neighbour_cap`), which cannot
# be known until every pad has been placed.
#
# THREE PHASES, and the split is about DETERMINISM, not tidiness. `_shrink_to_fit` mutates a pad's
# radius, and `_neighbour_cap` reads every pad's radius — so resolving pads one at a time would
# let pad 5's cap see pad 2's already-shrunk radius while pad 2's cap saw pad 5's authored one.
# The result would depend on roster ORDER, and the chunk cache's stamp (which folds these widths
# in) would be keyed on something that could change without any input changing. So: cap every pad
# against the authored radii, shrink each pad against only its own cap, then re-cap against the
# final radii. Every phase is a pure function of the phase before it.
func _resolve_feathers(height_at: Callable) -> void:
	_pf.resize(_px.size())
	var caps := PackedFloat32Array()
	caps.resize(_px.size())
	for i in _px.size():
		caps[i] = _neighbour_cap(i)
	for i in _px.size():
		_shrink_to_fit(i, caps[i], height_at)
	for i in _px.size():
		# Re-capped against the FINAL radii: a shrunk pad has left room its neighbours may use.
		var cap := _neighbour_cap(i)
		var f: float = minf(_feather_for(_px[i], _pz[i], _pr[i], _ph[i], height_at), cap)
		_pf[i] = f
		_widest_feather_m = maxf(_widest_feather_m, f)


# WHEN THE BAND CANNOT BE WIDENED, SHRINK THE DISC INSTEAD.
#
# The ramp out of a pad is about `1.5 * dh / f`, where `dh` is how far the pad's level sits from
# the ground at the band's outer edge. `_feather_for` solves that for `f` — but `_neighbour_cap`
# can refuse the width it asks for, and then the ramp is whatever it is. Measured on the shipped
# map, that is exactly what happened: crowded pins left bands at the 14 m floor paying a ~7 m
# offset, i.e. a 0.7 grade, and the road out of those pads was the wall the player hit.
#
# `dh` is roughly the terrain's slope times the pad's RADIUS — a flat disc cut into sloping ground
# differs from that ground by about that much at its rim. So when the run is fixed, the lever left
# is the radius: a smaller disc has less to give back. This walks the radius down until the ramp
# fits the run it can actually have.
#
# THE AUTHORED RADIUS IS A WISH, like the garage's road offset. It is honoured wherever there is
# room, and `_MIN_RADIUS_SHARE` bounds how much of it can ever be given up so a pad still covers
# what stands on it.
#
# THE GARAGE PAD IS EXEMPT. Its radius is not decoration: `overworld_garage.gd` clamps the
# building's placement against the CONFIGURED radius, so shrinking the pad here would leave the
# building hanging off ground the pad no longer flattens. A crowded garage keeps its disc and
# accepts its ramp; the map's pin fit is what would have to change.
func _shrink_to_fit(index: int, cap: float, height_at: Callable) -> void:
	if _ids[index] == HQ_PAD_ID or not height_at.is_valid() or cap <= 0.0:
		return
	var full := _pr[index]
	var floor_r := full * _MIN_RADIUS_SHARE
	var r := full
	while r > floor_r:
		var level := _level_for(_px[index], _pz[index], r, height_at)
		var offset := _worst_offset(_px[index], _pz[index], r + cap, level, height_at)
		if 1.5 * offset / cap <= _max_grade:
			break
		r -= full * _SHRINK_STEP_SHARE
	r = maxf(r, floor_r)
	if r < full:
		_pr[index] = r
		# The level is a function of the disc, so a shrunk pad re-levels against its own footprint.
		_ph[index] = _level_for(_px[index], _pz[index], r, height_at)


# THE NEIGHBOUR CAP — the limit that stops the widening above from eating the map.
#
# MEASURED, not theorised (tools/analyse_road_grades.gd, shipped 1 km map, 39 pads): with the
# grade-driven widening alone, feathers ran to a mean of 58 m against a 60 m cap, so on a map
# whose pads sit ~150 m apart EVERY band overlapped its neighbours deeply. The ground between two
# pads was then never raw terrain — it was driven to a BLEND of two pad levels the whole way
# across, so the entire height difference between two pads had to be paid inside the narrow strip
# where the blend hands over. That is a ramp far steeper than the hill it replaced: roads that
# ran at worst 0.28 over open ground hit 0.67 once pads were on, and the drops (the thing that
# launches a car) were the worst of it. The widening was making the exact defect it exists to fix.
#
# So a pad may claim at most HALF the clear gap to its nearest neighbour. Two adjacent bands then
# meet at the midpoint at zero weight instead of overlapping, which leaves the ground between them
# as the terrain's own — smooth by construction, and the surface the roads were fine on before
# pads existed.
#
# The authored `_feather_m` is the floor: pads closer together than that cannot be separated, and
# a pad must keep some band or it becomes the mesa the feather exists to prevent. Pads whose
# FOOTPRINTS overlap (closer than r_i + r_j) fall to that floor and are accepted as-is — the
# roster would have to place two pins nearly on top of each other, and no feather width can fix
# two flat circles at different levels intersecting.
#
# TRIED AND REJECTED: exempting neighbours whose LEVELS are close (the thought being that two pads
# at the same height have no difference to hand over, so they could overlap freely). Measured, it
# made the map WORSE — samples over the climb limit went 4.8% -> 5.4%, over the drop limit
# 1.6% -> 1.7% — because the wider bands it granted reached PAST the compatible neighbour into a
# third pad that was not compatible. The cap stays unconditional; do not re-add the exception
# without re-running tools/analyse_road_grades.gd.
func _neighbour_cap(index: int) -> float:
	var best := _max_feather_m
	for j in _px.size():
		if j == index:
			continue
		var dx := _px[index] - _px[j]
		var dz := _pz[index] - _pz[j]
		var clear := sqrt(dx * dx + dz * dz) - _pr[index] - _pr[j]
		best = minf(best, clear * 0.5)
	return maxf(best, _feather_m)


# THE ADAPTIVE FEATHER — why a pad's band is not simply `_feather_m`.
#
# The flatten ramps from the pad level back to the raw terrain across the feather band, and the
# steepest grade a smoothstep can produce is 1.5 * (height difference) / (band width). With a
# FIXED band that grade is whatever the site happens to hand you: on a flat plain it is nothing,
# but where a pad's level sits well above or below the ground just outside it, the ramp becomes
# a wall — and because a road leaves the pad THROUGH that ramp (terrain_manager's road carve
# pulls the roadbed onto the pad level at the junction), the player ends up unable to drive out
# of the pad on the very road that leads to it. That is the bug this exists to kill.
#
# So the band WIDENS to hold the grade under `_max_grade` instead: sample a ring of the terrain's
# own generated height around the pad, take the worst |level - h|, and demand
# `1.5 * drop / max_grade` of run for it. The ring sits at the CURRENT candidate band's outer
# edge, so the estimate is re-taken a couple of times as the band grows (widening moves the ring
# outward, which can find rougher ground, which widens it again). It only ever grows, converges
# in two or three passes, and is capped by `_max_feather_m` so a pad on a cliff cannot swallow
# the map.
#
# Pure and deterministic: same pad centre, same radius, same terrain generator -> same width, so
# the chunk cache's stamp (which folds the widths in) stays honest.
func _feather_for(cx: float, cz: float, radius: float, level: float,
		height_at: Callable) -> float:
	if not height_at.is_valid() or _feather_m <= 0.0:
		return _feather_m
	var f := _feather_m
	for _pass in _WIDEN_PASSES:
		var worst := _worst_offset(cx, cz, radius + f, level, height_at)
		var needed: float = clampf(1.5 * worst / _max_grade, _feather_m, _max_feather_m)
		if needed <= f + 0.01:
			break
		f = needed
	return f


# The worst |terrain - level| anywhere on the ring of radius `ring_r` — the height the ramp has
# to give back, and therefore the input to every grade estimate here. Shared by the widening and
# the shrink so the two can never disagree about what "the offset at the band edge" means.
func _worst_offset(cx: float, cz: float, ring_r: float, level: float,
		height_at: Callable) -> float:
	var worst := 0.0
	for s in _RING_SAMPLES:
		var a := TAU * float(s) / float(_RING_SAMPLES)
		var h := float(height_at.call(cx + cos(a) * ring_r, cz + sin(a) * ring_r))
		worst = maxf(worst, absf(h - level))
	return worst


func is_built() -> bool:
	return _built


func size_m() -> float:
	return _size_m


func pad_count() -> int:
	return _px.size()


## World XZ centre of pad `index`.
func pad_centre(index: int) -> Vector2:
	return Vector2(_px[index], _pz[index])


## Full-flatten radius of pad `index`, metres.
func pad_radius(index: int) -> float:
	return _pr[index]


## The level pad `index` holds its ground at, in metres.
func pad_level(index: int) -> float:
	return _ph[index]


## The AUTHORED (minimum) feather band width outside a pad's radius, metres. An individual pad
## may run wider — ask `pad_feather` for the width that pad actually uses.
func feather_m() -> float:
	return _feather_m


## Feather band width of pad `index`, metres — `feather_m()` or wider (see `_feather_for`).
func pad_feather(index: int) -> float:
	return _pf[index]


## The steepest grade (rise / run) a feather ramp is allowed to reach.
func max_grade() -> float:
	return _max_grade


## The ceiling a widened feather band is clamped to, metres.
func max_feather_m() -> float:
	return _max_feather_m


## How far a pad can affect the ground beyond its own centre — the largest radius plus the
## feather. Same contract as OverworldRoads.influence_m: callers inflate a query rect by it.
## `_widest_feather_m`, not `_feather_m`: pads widen their own band on rough ground, and a
## caller that inflated by the authored width would miss the outer skirt of a widened pad.
func influence_m() -> float:
	return maxf(_zone_radius_m, _garage_radius_m) + _widest_feather_m


## Indices of the pads that could touch `rect` (world XZ), for a cheap per-chunk reject:
## an empty array means "this chunk has no pad in it", which is the answer for the vast
## majority of the ~1,600 chunks. The rect is inflated by the feather internally, so pass
## the raw chunk rect.
##
## Linear over the pad list on purpose — there is one pad per rally plus one, i.e. a few
## dozen, so the SpatialGrid binning OverworldRoads needs for its thousands of polyline
## segments would cost more than it saves here.
func pads_in_rect(rect: Rect2) -> Array:
	var out: Array = []
	for i in _px.size():
		var grown := rect.grow(_pr[i] + _pf[i])
		if grown.has_point(Vector2(_px[i], _pz[i])):
			out.append(i)
	return out


## The pad influence at world (x, z), as a VECTOR2 — see the "COST" note in the header:
##   .x  flatten weight, 1 inside a pad, smoothstepping to 0 across the feather band, 0 away
##       from every pad;
##   .y  the target HEIGHT the ground is driven toward at that weight (the level of the
##       dominant pad; meaningless when the weight is 0).
## Pure function of position, allocation-free and thread-safe (no shared scratch state).
##
## OVERLAPPING PADS. The two returned numbers are computed differently on purpose.
##
## The WEIGHT is the strongest pad's, taken outright: a pad's own footprint must read as fully
## flat no matter who else reaches into it.
##
## The TARGET is a blend of every overlapping pad's level, each weighted by `w / (1 - w)` (see
## the note in the loop for why that curve and not a high power). Taking the strongest pad's
## level outright instead puts a STEP where two influences cross — `w * (levelA - levelB)`, metres
## tall on rough ground: the exact cliff the feather exists to prevent, and, because this pass
## runs after the road carve and overwrites it, a road that jumps mid-span. It used to be rare
## (two pads had to sit within a 14 m band); with bands that widen up to `_max_feather_m` it is
## common.
##
## `w / (1 - w)` diverges as w -> 1, so a sample inside a pad outvotes every neighbour by orders
## of magnitude and the interior stays flat — this is NOT the naive average, which would tilt both
## pads. Where two feathers meet at comparable weights it is finite and varies gently, so the
## target slides between the levels instead of snapping.
##
## KNOWN LIMIT: the interior is flat to within a neighbour's residual pull (~1% of the level
## difference at w_neighbour = 0.9999), not exactly flat. Immaterial for realistic geometry, but
## two pins closer than `r_a + r_b` would hold BOTH interiors at the average of their levels and
## neither at its own. Pads that overlap at full weight are outside what this can express.
func pad_at(x: float, z: float) -> Vector2:
	var best_w := 0.0
	var num := 0.0
	var den := 0.0
	for i in _px.size():
		var dx := x - _px[i]
		var dz := z - _pz[i]
		var d := sqrt(dx * dx + dz * dz)
		var r := _pr[i]
		var f := _pf[i]
		var w := 0.0
		if d <= r:
			w = 1.0
		elif f > 0.0 and d < r + f:
			# Smoothstep across the band so the pad meets the surrounding noise with no
			# crease — the same shaping the coastline taper uses.
			var t := (d - r) / f
			w = 1.0 - t * t * (3.0 - 2.0 * t)
		if w <= 0.0:
			continue
		best_w = maxf(best_w, w)
		# WHY w/(1-w) AND NOT w^8.
		#
		# Two quantities come out of this loop and they need different things. `best_w` decides
		# HOW MUCH to flatten and is smooth by construction. The blended level decides WHAT
		# HEIGHT to flatten towards, and it is the one that used to break.
		#
		# The old weight was pow(w, 8), chosen so a pad's interior would not be dragged by a
		# neighbour. It did that, but at the locus EQUIDISTANT from two pads w1 ~= w2, and the
		# contribution ratio there is (w1/w2)^8 — so a fractional step in position swings the
		# target almost entirely from one pad's level to the other's. The result was a near
		# discontinuity in the target height exactly HALFWAY BETWEEN TWO PADS, scaled by the
		# two pads' height difference: a visible step in the ground, and — because the pad pass
		# runs AFTER the road carve and overwrites it — a road that jumped mid-span. Nothing in
		# `best_w` hinted at it, which is why it read as a road bug rather than a pad bug.
		#
		# w/(1-w) keeps the property that motivated the exponent while staying smooth. It grows
		# without bound as w -> 1, so an interior sample outvotes every neighbour and the pad
		# stays exactly flat; but where two feathers meet at comparable w it is finite and
		# varies gently, so the target slides between the two levels instead of snapping.
		var bias := w / maxf(1.0 - w, _BLEND_EPSILON)
		num += bias * _ph[i]
		den += bias
	if den <= 0.0:
		return Vector2.ZERO
	return Vector2(best_w, num / den)


## A stable hash of everything the flattened ground derives from: the radii, the feather,
## `size_m`, and every pad's quantised centre and level. The overworld chunk cache folds this
## into its invalidation key (Overworld._open_chunk_cache) exactly as it folds in
## OverworldRoads.network_hash, so moving a pin or retuning a radius invalidates the cached
## heights instead of leaving the player driving yesterday's ground. Order-independent: the
## per-pad parts are sorted.
func stamp() -> int:
	var parts := PackedStringArray()
	parts.append("v=2")
	parts.append("size=%.4f" % _size_m)
	parts.append("r=%.4f,%.4f,%.4f" % [_zone_radius_m, _garage_radius_m, _feather_m])
	parts.append("g=%.4f,%.4f" % [_max_grade, _max_feather_m])
	var pad_parts := PackedStringArray()
	for i in _px.size():
		pad_parts.append("p=%s,%.4f,%.4f,%.4f,%.4f,%.4f" % [_ids[i], _px[i], _pz[i], _pr[i],
			_ph[i], _pf[i]])
	pad_parts.sort()
	for p in pad_parts:
		parts.append(p)
	return hash("|".join(parts))
