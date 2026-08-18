class_name OverworldScatter
extends RefCounted
# CHUNK-LOCAL foliage placement for the open-world overworld hub (see
# docs/superpowers/specs/2026-08-17-overworld-hq-design.md, "Slice 4 — surfaces, trees,
# skyboxes"). Pure + headless + seeded, working in the world-XZ plane (x -> world x,
# y -> world z). No scene tree, no node spawning: the caller feeds the returned points to
# Foliage.spawn_trees / spawn_bushes / spawn_rocks.
#
# WHY THIS EXISTS — TreeScatter.scatter cannot be reused here. Its jittered grid is
# per-cell order-independent only GIVEN A GLOBAL SET OF TURN PIECES: a cell emits a point
# only when its jittered position falls inside a `turn_anchor` disc, and a shared `used`
# dict makes overlapping discs share cells. With no track there are no discs, so it
# returns an empty array. What DOES carry over is the pure hashing — ScatterMath.hash01
# is a pure, order-independent hash of (cell, seed, salt), and the jitter / grid-phase /
# species salts work identically without a track. This file keeps the hashes and the
# jittered lattice, and replaces the disc gating with a low-frequency density FIELD.
#
# THE CONTRACT
#
# * `scatter_chunk` returns the points for exactly ONE chunk, derived only from
#   (chunk_coord, chunk_m, params, seed_value, density args). No global state, no track,
#   no shared `used` dict, no cross-chunk bookkeeping — so chunks can be built in any
#   order, on demand, and re-built after eviction with identical results.
# * SEAMLESSNESS. The lattice is derived from ABSOLUTE world coordinates (cell index
#   cx = a world-space cell, never restarted per chunk), so it is continuous across chunk
#   borders — no seam row, no doubled row. Chunk OWNERSHIP is decided by the cell's
#   un-jittered lattice CENTRE against the chunk's half-open bounds [lo, hi): every cell
#   in the infinite lattice therefore belongs to exactly one chunk, so a point can be
#   neither duplicated nor dropped at a boundary. The jitter (and, for rocks, the cluster
#   fan-out) may place the final point slightly OUTSIDE the owning chunk; that is correct
#   and intended — the alternative (clamping or re-testing the jittered point) is what
#   creates visible grid seams along chunk edges.
# * DETERMINISM. Every random decision is a `ScatterMath.hash01` of the cell index, the
#   seed and a salt — never a running RNG, never iteration-order dependent. The density
#   field is a FastNoiseLite seeded from `seed_value`. Two calls for the same chunk return
#   identical results; so does a call after the chunk was evicted and rebuilt.
#
# COST PER CHUNK (rough). O(cells in chunk) = (chunk_m / cell)^2, where
# cell = TreeScatter.grid_cell_size(params). Per cell: 2 hash01 calls for the jitter, one
# noise sample when the density gate is active, and one `keep` Callable call for a point
# that survives. At the stage-tree density (~cell 8-12 m) a 64 m chunk is ~30-60 cells,
# i.e. a few hundred hashes and well under 0.1 ms — comfortably inside a per-frame chunk
# build budget. Allocation is one PackedVector2Array (grown in place) per pass plus the
# cached noise object; the noise is built once per (seed, wavelength) and reused for every
# chunk, which is the whole reason this is a RefCounted instance rather than static-only.

# Per-pass seed offsets, so the three lattices interleave instead of stacking on the same
# jittered grid points (see TreeScatter._grid_phase). Mirrors world.gd's BUSH_SEED_OFFSET
# / ROCK_SEED_OFFSET so the overworld and the stage world decorrelate the same way; the
# values are arbitrary, only their difference matters.
const BUSH_SEED_OFFSET := 1013
const ROCK_SEED_OFFSET := 2027

# The jitter / grid-phase salts are read straight off TreeScatter (referenced inline below
# rather than re-declared here) so the two drivers cannot drift apart and a given seed puts
# the two lattices in the same relationship on a stage and in the overworld.

# Cached density noise, keyed by (seed, wavelength) — one build per field, reused across
# every chunk for the world's lifetime.
var _noise: FastNoiseLite = null
var _noise_seed := 0
var _noise_wavelength := 0.0


# The chunk containing world-XZ point `p`, for a chunk edge of `chunk_m` metres. The
# inverse of the bounds `scatter_chunk` uses, so callers can bucket a position the same
# way this file does.
static func chunk_of(p: Vector2, chunk_m: float) -> Vector2i:
	if chunk_m <= 0.0:
		return Vector2i.ZERO
	return Vector2i(floori(p.x / chunk_m), floori(p.y / chunk_m))


# The whole-lattice offset for a seed, in [0, cell) per axis — same construction as
# TreeScatter._grid_phase, so different seeds (trees vs bushes vs rocks) land on
# interleaved grids rather than in the same cells. Constant across chunks (it depends on
# the seed only), which is what keeps the lattice continuous world-wide.
static func grid_phase(cell: float, seed_value: int) -> Vector2:
	return Vector2(
		ScatterMath.hash01(0, 0, seed_value, TreeScatter._PHASE_SALT_X) * cell,
		ScatterMath.hash01(0, 0, seed_value, TreeScatter._PHASE_SALT_Z) * cell)


# The un-jittered lattice centre of absolute cell (cx, cz). This — NOT the jittered
# point — decides which chunk owns the cell.
static func cell_centre(cx: int, cz: int, cell: float, phase: Vector2) -> Vector2:
	return Vector2((cx + 0.5) * cell, (cz + 0.5) * cell) + phase


# The world-XZ point for absolute cell (cx, cz): its centre plus a seeded jitter of up to
# ±jitter/2 of a cell per axis. Identical maths to TreeScatter._cell_point, so spacing is
# still guaranteed by construction — two points are never closer than (1 - jitter) * cell
# in the axis-adjacent worst case.
static func cell_point(cx: int, cz: int, cell: float, jitter: float, seed_value: int,
		phase: Vector2) -> Vector2:
	var jx := (ScatterMath.hash01(cx, cz, seed_value, 0) - 0.5) * jitter
	var jz := (ScatterMath.hash01(cx, cz, seed_value, TreeScatter._JITTER_SALT) - 0.5) * jitter
	return Vector2((cx + 0.5 + jx) * cell, (cz + 0.5 + jz) * cell) + phase


# Split scattered positions into one group per species by WEIGHT — the region's authored
# `tree_mix` weights still decide what grows. Delegates to TreeScatter.partition_by_weight
# so the overworld and the stage world assign species by the exact same pure hash
# (_SPECIES_SALT off the 0.5 m cell of the point), and a point's species is independent of
# which chunk it was built in or when.
#
# The MIX IS A PARAMETER on purpose: this file never resolves a region itself (that is
# OverworldRegion's job), so the two stay decoupled.
static func species_groups(positions: PackedVector2Array, weights: Array,
		seed_value: int) -> Array:
	return TreeScatter.partition_by_weight(positions, weights, seed_value)


# The density field: a low-frequency Perlin field over world XZ that breaks an otherwise
# uniform scatter into stands of forest and clearings — the same intent (and the same
# construction, via TreeScatter.make_forest_noise / forest_density) that `forestiness` has
# in TreeScatter.scatter, which is the closest thing the stage world has to this.
#
# MIND THE RANGE. `forestiness` is NOT linear in the coverage it produces, and the useful
# band is much narrower than [0, 1] — see TreeScatter.forest_density for the measured
# mapping (below ~0.35 is not "sparse", it is "none"; author sparse-but-present at
# 0.38..0.48). Authored regional values therefore mean here exactly what they mean on a
# stage, which is the point of keeping the semantics.
func density_at(p: Vector2, seed_value: int, wavelength: float) -> float:
	_ensure_noise(seed_value, wavelength)
	return TreeScatter.forest_density(_noise, p)


func _ensure_noise(seed_value: int, wavelength: float) -> void:
	if _noise != null and _noise_seed == seed_value and is_equal_approx(
			_noise_wavelength, wavelength):
		return
	_noise = TreeScatter.make_forest_noise(seed_value, wavelength)
	_noise_seed = seed_value
	_noise_wavelength = wavelength


# ---------------------------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------------------------

# Scatter one chunk's worth of points.
#
# `chunk_coord` — the chunk's integer coordinate; it covers world XZ
#   [chunk_coord * chunk_m, (chunk_coord + 1) * chunk_m) (half-open, hence seamless).
# `params` — the same packing TreeScatter uses: {points_per_turn, spawn_radius_m, jitter}
#   (GameConfig.tree_params() / rock_params()). Only the derived CELL SIZE is used, via
#   TreeScatter.grid_cell_size, so an authored count/radius keeps its areal density
#   (points_per_turn per PI * spawn_radius_m^2 of ground) rather than meaning something
#   new out here.
# `forestiness` — density gate in [0, 1]: a cell is kept only where the field exceeds
#   1 - forestiness, so 1.0 skips the field entirely (bushes, rocks) and 0.0 places
#   nothing. NOT linear in coverage — see density_at.
# `keep_point` — optional Callable(Vector2) -> bool the caller uses to cull points, most
#   importantly SUBMERGED ones. The caller owns the terrain and the waterline, so it
#   decides (mirroring world.gd::_drop_submerged, which the stage world runs as its own
#   pass); this file never queries terrain. This matters at the map edge, where the
#   spec's coastline taper (D9) drops the ground below the waterline: without the
#   predicate, foliage would grow in the sea. An invalid Callable keeps everything.
func scatter_chunk(chunk_coord: Vector2i, chunk_m: float, params: Dictionary,
		seed_value: int, forestiness := 1.0, forest_wavelength := 300.0,
		keep_point := Callable()) -> PackedVector2Array:
	var out := PackedVector2Array()
	if chunk_m <= 0.0:
		return out
	var cell := TreeScatter.grid_cell_size(params)
	if cell <= 0.0:
		return out  # points_per_turn or radius is 0 -> nothing to place
	var clamped_forestiness := clampf(forestiness, 0.0, 1.0)
	if clamped_forestiness <= 0.0:
		return out
	var jitter := clampf(float(params.get("jitter", 0.6)), 0.0, 1.0)
	var phase := grid_phase(cell, seed_value)
	# Only build/sample the field when it can actually exclude something.
	var gated := clamped_forestiness < 1.0
	var threshold := 1.0 - clamped_forestiness
	if gated:
		_ensure_noise(seed_value, forest_wavelength)
	var has_keep := keep_point.is_valid()
	# Absolute cell range whose UN-JITTERED CENTRE lands in this chunk's half-open bounds.
	# centre.x = (cx + 0.5) * cell + phase.x, so cx >= (lo - phase.x)/cell - 0.5 and
	# cx < (hi - phase.x)/cell - 0.5. Deriving the range from world coordinates (rather
	# than restarting the grid at the chunk origin) is what makes the lattice continuous
	# across borders; the half-open test is what makes ownership exactly-once.
	var lo := Vector2(float(chunk_coord.x) * chunk_m, float(chunk_coord.y) * chunk_m)
	var min_cx := ceili((lo.x - phase.x) / cell - 0.5)
	var max_cx := ceili((lo.x + chunk_m - phase.x) / cell - 0.5) - 1
	var min_cz := ceili((lo.y - phase.y) / cell - 0.5)
	var max_cz := ceili((lo.y + chunk_m - phase.y) / cell - 0.5) - 1
	for cx in range(min_cx, max_cx + 1):
		for cz in range(min_cz, max_cz + 1):
			var p := cell_point(cx, cz, cell, jitter, seed_value, phase)
			if gated and TreeScatter.forest_density(_noise, p) <= threshold:
				continue
			if has_keep and not bool(keep_point.call(p)):
				continue
			out.append(p)
	return out


# Trees for one chunk: the density-gated pass, on the base seed.
func trees_in_chunk(chunk_coord: Vector2i, chunk_m: float, params: Dictionary,
		seed_value: int, forestiness := 1.0, forest_wavelength := 300.0,
		keep_point := Callable()) -> PackedVector2Array:
	return scatter_chunk(chunk_coord, chunk_m, params, seed_value, forestiness,
		forest_wavelength, keep_point)


# Bushes for one chunk. NOT density-gated (forestiness 1.0), exactly as the stage world's
# bush pass isn't: undergrowth covers everything. Offset seed so the bush lattice
# interleaves with the trees' instead of stacking on it.
func bushes_in_chunk(chunk_coord: Vector2i, chunk_m: float, params: Dictionary,
		seed_value: int, keep_point := Callable()) -> PackedVector2Array:
	return scatter_chunk(chunk_coord, chunk_m, params, seed_value + BUSH_SEED_OFFSET,
		1.0, 300.0, keep_point)


# Rocks for one chunk. Like the stage world (features/rocks.md): the scatter places GROUP
# ANCHORS and each one is fanned out into a small cluster, so boulders read as outcrops
# that shed a few stones together rather than as evenly-spaced individuals.
#
# NOT density-gated — stone is not vegetation, and gating it on the tree field would put
# boulders only where the trees are.
#
# The cluster fan-out can push a companion up to `group_radius_m` outside the owning
# chunk. That is deliberate and still exactly-once: the companion belongs to its anchor's
# chunk and is produced only by that chunk's build, so nothing is duplicated. Callers that
# bin by chunk should bin by the ANCHOR's chunk, not by the companion's position, and size
# their build ring so a neighbouring chunk's spill is already loaded.
func rocks_in_chunk(chunk_coord: Vector2i, chunk_m: float, params: Dictionary,
		seed_value: int, group_min: int, group_max: int, group_radius_m: float,
		keep_point := Callable()) -> PackedVector2Array:
	var rock_seed := seed_value + ROCK_SEED_OFFSET
	# The keep predicate is applied AFTER clustering, not to the anchors: a companion can
	# land in the sea even when its anchor is on dry land, and culling anchors first would
	# also delete their (perfectly fine) companions.
	var anchors := scatter_chunk(chunk_coord, chunk_m, params, rock_seed, 1.0, 300.0)
	if anchors.is_empty():
		return anchors
	# `{}` for road_cells: there is no carriageway out here to reject against.
	var rocks := TreeScatter.cluster(anchors, group_min, group_max, group_radius_m,
		rock_seed)
	if not keep_point.is_valid():
		return rocks
	var out := PackedVector2Array()
	for p in rocks:
		if bool(keep_point.call(p)):
			out.append(p)
	return out
