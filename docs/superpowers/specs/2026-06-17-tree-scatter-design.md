# Tree scatter around track turns — design

## Goal

After track generation, scatter a configurable number of billboard tree
sprites (`textures/tree.png`) randomly in a radius around each turn of the
generated track. Reject candidate positions that are too close to the road or
too close to an already-placed tree, retrying up to a configurable limit before
giving up on that tree.

## Components

### 1. `scripts/tree_scatter.gd` (`class_name TreeScatter`) — placement logic

Pure, headless, seeded — mirrors `TrackGenerator`'s style (static funcs, no
scene nodes, deterministic via a seeded `RandomNumberGenerator`). Operates in
the same 2D world-XZ plane as the track (`x → world x`, `y → world z`).

```
static func scatter(
    pieces: Array,            # TrackGenerator result["pieces"]
    occupied: Dictionary,     # TrackGenerator result["cells"] (Vector2i, 0.5 m grid)
    params: Dictionary,       # per-knob values pulled from GameConfig (see Config)
    seed: int
) -> PackedVector2Array       # accepted tree positions (world XZ)
```

Algorithm:

1. Build a seeded `RandomNumberGenerator` (`seed`). Reusing `track_seed` from
   config is fine; offset it (e.g. `seed + 0x7EE`) so trees don't correlate
   visually with corner choices.
2. For each piece, compute the **turn anchor** = centroid of that piece's
   `cells` (average of cell centres, converted to world XZ). A piece always has
   ≥ 1 cell.
3. For each piece, attempt `trees_per_turn` placements. Each attempt:
   - Pick a random point within `spawn_radius_m` of the anchor: uniform-in-disc
     (`r = radius * sqrt(rand)`, `theta = rand * TAU`).
   - **Too close to road:** convert candidate to the 0.5 m cell grid
     (`TrackGenerator.CELL_M`); scan the box of cells within
     `ceil(min_road_dist_m / CELL_M) + 1` of it. Reject if any scanned cell is
     in `occupied` AND its cell-centre is within `min_road_dist_m` of the
     candidate.
   - **Too close to another tree:** reject if within `min_tree_dist_m` of any
     already-accepted position.
   - On rejection retry, up to `max_retries` attempts for that tree. If all
     retries fail, skip the tree (do not place it).
4. Return all accepted positions.

The function never raises and never hangs: total work is bounded by
`turns × trees_per_turn × (1 + max_retries)`.

### 2. `shaders/billboard.gdshader` — cylindrical billboard

A spatial shader that orients each quad to face the camera while staying upright
(rotate around world Y only — cylindrical billboard). Cancels the view basis'
X/Z rotation in the vertex stage; world up stays up. Samples `tree.png`; uses
alpha scissor (`ALPHA_SCISSOR_THRESHOLD`) for a crisp cutout edge (no blending
sort issues). Unshaded/flat look to match the PS1 aesthetic.

### 3. `scripts/tree_field.gd` (`class_name TreeField`, extends `MultiMeshInstance3D`)

Builds the renderable field from accepted positions:

- One `MultiMesh` (transform format 3D) over a single `QuadMesh` sized
  `tree_size_m` (width × height), pivot at the bottom edge so the trunk sits on
  the ground.
- One instance per position, translated to `(x, Floor.height_at(x,z), z)`.
- Uses `shaders/billboard.gdshader` with `tree.png` bound. Whole field renders
  in one draw call.

`build(positions: PackedVector2Array, floor: TerrainManager, size: Vector2)`.

### 4. Integration — `scripts/world.gd._generate_track()`

After `$Floor.set_track(...)` and `$Floor.build_initial()`:

```
var trees := TreeScatter.scatter(result["pieces"], result["cells"], cfg.tree_params(), cfg.track_seed)
var field := TreeField.new()
add_child(field)
field.build(trees, $Floor as TerrainManager, cfg.tree_size_m)
```

(`height_at` requires the terrain noise cache, which `build_initial()` warms.)

## Configuration — new `Trees` group in `GameConfig` / `config/game_config.tres`

| Knob | Type | Meaning | Default |
|------|------|---------|---------|
| `trees_per_turn` | int | placement attempts (max trees) per turn | 12 |
| `tree_spawn_radius_m` | float | scatter radius around the turn anchor | 25.0 |
| `tree_min_road_dist_m` | float | min distance from any track cell | 6.0 |
| `tree_min_tree_dist_m` | float | min spacing between trees | 4.0 |
| `tree_max_retries` | int | retries per tree before skipping | 8 |
| `tree_size_m` | Vector2 | billboard width × height (m) | (4, 6) |

A `GameConfig.tree_params()` helper packs the scalar knobs into the Dictionary
`TreeScatter.scatter` expects.

## Tests — `tests/headless/test_tree_scatter.gd`

- **Determinism:** same seed → identical positions; different seed → different.
- **Road clearance:** every accepted tree is ≥ `min_road_dist_m` from every
  occupied track cell centre.
- **Tree spacing:** every pair of accepted trees is ≥ `min_tree_dist_m` apart.
- **Within radius:** every accepted tree is within `spawn_radius_m` of at least
  one turn anchor.
- **Count bound:** accepted count ≤ `trees_per_turn × pieces.size()`.
- **No-hang / skip:** with impossible constraints (tiny radius, huge min dists)
  scatter returns quickly with few/zero trees.

Smoke (`tests/headless/test_smoke.gd`): a built `TreeField` has
`multimesh.instance_count == positions.size()`.

## Docs

- New `features/trees.md` describing the scatter logic, billboard rendering, and
  config knobs.
- Index entry in `features/README.md`.
