# Rocks

Roadside boulders: low-poly meshes scattered along the stage verges as **collidable**
obstacles, at a density the region chooses. Companion to [trees.md](trees.md) (the
billboard scenery) and [regions.md](regions.md) (what a region varies).

**Tests:** `tests/headless/test_rocks.gd`

## The shape of it

| Concern | Where |
| --- | --- |
| Models + licence | `models/rocks/` (`README.md` there) |
| Mesh merge, sizing, spawn | `scripts/foliage.gd` → `rock_mesh`, `rock_height`, `spawn_rocks` |
| Rendering + collision field | `scripts/tree_mesh_field.gd` (shared with bushes) |
| Scatter + placement | `scripts/world.gd` → `_build_rocks` |
| Size / colour / hitbox tuning | `GameConfig`, `@export_group("Rocks")` |
| Per-region density | `scripts/region_library.gd` → `rock_density` |
| Shader | `shaders/ps1_models_lit.gdshader` (shared with the car, barriers, finish arch) |
| Tests | `tests/headless/test_rocks.gd` |

## Meshes, not billboards

Rocks are the one piece of scattered nature in this game that is **real geometry**.
Trees and the region shrubs are camera-facing cutouts (`BillboardField`); rocks use
`TreeMeshField`, the same path the ground-cover bushes take.

The reason is viewing distance and proportion. A tree card is tall, thin and normally
seen far away, so a camera-facing quad never gives itself away. A boulder is squat and
you drive within a metre of it — at that range a billboard reads as cardboard, and it
spins to face the camera in a way a rock visibly should not. Geometry also gives the
collision box an honest silhouette to be derived from.

Rocks take the bush path but invert its two defining choices:

| | Bushes | Rocks |
| --- | --- | --- |
| Collision | none (proximity `BushField` instead) | **yes** — real `StaticBody3D` boxes |
| Lighting | per-instance BAKED terrain light | **live per-vertex fake sun** |

## Lighting

Rocks use `ps1_models_lit.gdshader` — `render_mode unshaded` with the sun computed
per-vertex in the shader:

```glsl
float hemi = wn.y * 0.5 + 0.5;                 // hemisphere ambient
vec3 ambient = mix(ground_color, sky_color, hemi);
float ndl = max(dot(wn, normalize(light_dir)), 0.0);
vec3 lit = ambient + sun_color * ndl;
```

This game has **no light nodes at all** — everything is unshaded, and the terrain's
"sunlight" is baked into vertex colours on the CPU at chunk-generation time
(`TerrainManager._light_from_neighbours`, the same formula). Rocks can't use that bake:
it is per-instance, and rocks have real normals worth shading per-vertex. They can't
use the billboards' version either, which substitutes the card's to-camera vector for a
normal because a flat card has none worth having.

Uniforms come from `GameConfig.apply_car_light(mat)`, so rocks dim with the weather
(`weather_sun_mult`), go dark at night, and pick up the headlight cone — the shader
`#include`s `headlight_cone.gdshaderinc`, whose globals every material gets for free.

> Do **not** copy the pattern in `barrier_section.gd` / `finish_arch.gd`, which hardcode
> their own `light_dir` / `sun_color` literals. Those props do not dim with the weather.
> Rocks go through the config applier on purpose.

## The mesh merge

Kenney ships each rock as 2–3 primitives (a `dirt` body, a `grass` cap, sometimes a
`_defaultMat`) carrying colour as a material `baseColorFactor` — no texture, and no
vertex-colour array. `Foliage.rock_mesh` welds them into **one surface** and writes the
colour into **vertex colours** instead.

Two things come out of that:

- **One draw call per bin.** A MultiMesh draws every surface of its mesh separately, so
  as-authored a 16-triangle rock would cost three draw calls per bin.
- **The palette becomes config.** Kenney's orange body and turquoise cap are built for
  their own kit; `rock_body_color` / `rock_cap_color` replace them with a neutral stone
  and a muted lichen. Retuning is a config edit, never a re-export.

The body/cap split survives as vertex data that the shader multiplies in (`* COLOR.rgb`).
Matching is by material **name**, not surface index — the order differs between models.

MultiMesh instance colours are deliberately left **off** for rocks (`bake_terrain_light`
false), so `COLOR` is unambiguously the vertex colour and nothing competes for it.

## Sizing

`GameConfig.rock_height_m` is the single size knob. Each species multiplies it by its own
entry in `Foliage.ROCK_HEIGHT_SCALES`.

The per-species multiple is not decoration: `TreeMeshField` scales **uniformly from the
target height** (`uniform_scale_for = height / aabb.size.y`), and the three models have
very different aspect ratios. `rock_largeA` is a flat slab (0.79 × 0.26 × 1.02 source
units) while `rock_largeD` is a rounder lump (1.07 × 0.57 × 1.03). Scaling both to one
height would inflate the slab far wider than the lump just to match it. The multiples
are chosen so all three land at a sensible **footprint** relative to each other rather
than at a matching height.

This is the same trap `tree_mix`'s `size_scale` exists to solve, for the same reason.

Because the footprint follows the height knob, raising `rock_height_m` widens rocks too
— and the road-rejection margin in `_build_rocks` is derived from the mesh, so it
re-inflates to match automatically. Big rocks push themselves further from the road
without anyone having to remember to widen the margin.

### Sinking

`rock_sink_frac` buries each rock by that fraction of its own height. Without it the
models sit exactly on the surface, which reads as boulders dropped onto the terrain
rather than embedded in it — the tell being a visible ground seam right around the base.

It is applied as a single offset on the **field node**, not per instance:
`TreeMeshField` parents both the per-bin `MultiMeshInstance3D`s and the collision body
under itself, so one offset sinks the meshes and their hitboxes together and the two
cannot drift apart. It also keeps `TreeMeshField` — shared with the bushes — untouched.
A fraction rather than a metre value so it survives resizing, exactly like
`rock_collision_radius_frac`.

## Collision

One `StaticBody3D` per field carrying N box shapes that all share a single `BoxShape3D`
(`ObstacleBody.build`) — cheap, and already how tree collision works. The body joins
`DamageModel.OBSTACLE_GROUP`, so hitting a rock costs HP like hitting a tree.

The box is **derived from the mesh**, not authored: the species' scaled horizontal
half-extent times `rock_collision_radius_frac`. Resizing rocks therefore resizes their
hitboxes, and the two cannot drift apart. The fraction is below 1.0 so the box is
inscribed in the silhouette rather than boxing its corners — clipping a rock's visible
edge is much less jarring than hitting a wall of air beside it. Box height is the full
rock height, so a low slab does not present a boulder-height wall.

## Density is the only thing a region varies

`RegionLibrary`'s `rock_density` is a multiplier on `GameConfig.rock_groups_per_turn`,
defaulting to `1.0` so a region that authors nothing still gets rocks. It is whitelisted
in `LOOK_KEYS` — without that, `look_of()` drops it silently and every region renders at
the default.

As shipped: **Greece** is stoniest, **the Alps** sparsest, everything else the middle
(and `greece_coast` inherits Greece's value through `look_from`). The reasoning is in the
region entries — Greece is the one region with no ground cover at all, so rocks are what
fill a verge that is otherwise bare; deep snow buries loose stone, so the Alps keep only
the few boulders too big to cover, rather than dropping to zero.

Models, colours and hitboxes are shared everywhere on purpose: a boulder should read the
same wherever you meet it, so only how MANY changes.

## Scatter placement

Rocks scatter in **groups**, not as individuals. `TreeScatter.scatter` places group
ANCHORS, and `TreeScatter.cluster` fans each one into `rock_group_min`–`rock_group_max`
boulders (4–7 as shipped). Boulders in the world come from outcrops that shed several
stones together; evenly-spaced single rocks read as placed props.

A cluster is the anchor itself plus `count - 1` companions on a **jittered ring** around
it — evenly-spaced base angles with per-companion jitter, at a distance in the outer half
of `rock_group_radius_m`. Deliberately not a uniform disc sample: uniform sampling
cheerfully puts two rocks in the same spot, which reads as a bug when the models are
metres wide, whereas a jittered ring keeps them apart while still looking random.

Because the companions share a ring, their spacing is roughly its circumference over the
count — so **`rock_group_radius_m` has to move with the group size**. Raising
`rock_group_max` alone packs more boulders onto the same ring until they intersect.

Note the count knob is `rock_groups_per_turn` — **clusters** per turn, not rocks. Total
rocks are roughly that times the mean group size, so it sits proportionally lower than
you might expect.

> **The road must be re-rejected after clustering.** `TreeScatter.scatter` rejects at
> ANCHOR positions; fanning out by up to `rock_group_radius_m` can push a companion back
> onto the carriageway. For a collidable, half-buried boulder that means an invisible
> wall mid-corner, so `_build_rocks` filters the clustered points against the same road
> cells before spawning.

`world.gd::_build_rocks` mirrors the bush pass, with three deliberate differences:

- **Its own seed** (`ROCK_SEED_OFFSET`), so the rock lattice interleaves with the tree
  and bush ones instead of landing on the same jittered grid points.
- **Its own params** (`cfg.rock_params(density)`, not `tree_params()`). Trees are dense
  scenery, rocks are sparse obstacles you drive into — turning the forest up must not
  turn the hazard field up with it.
- **Not forest-gated.** Trees pass `cfg.track_forestiness` so they only appear in forest
  patches. Stone is not vegetation; gating it the same way would put boulders only where
  the trees are.

The road-rejection footprint is inflated by the **widest** species' radius (on top of
`tree_road_margin_m`), so one rejection pass covers all three and no rock can spill onto
the carriageway at any per-instance yaw. Submerged points are dropped, keeping rocks out
of the lakes.

> **Ordering trap.** The rock pass runs **before** the `spawn_bush_mesh` early return in
> `_build_foliage`. The two regions that switch bushes off (Greece, the Alps) are exactly
> the two with a non-default rock density, and Greece wants the most rocks in the game —
> folding rocks in below that return would silently give both of them none.

## Performance

- **Three fields, so three draw calls per bin** rather than the trees' one. Affordable
  only because `rock_groups_per_turn` is a fraction of `trees_per_turn` — rocks are meant to
  read as occasional hazards, and a dense collidable field would turn the verge into a
  wall besides.
- **No texture is sampled at all** — colour is vertex data, so the rock material binds
  nothing.
- Binning, LOD, distance cull and fade are inherited wholesale from `TreeMeshField`, at
  the shared `tree_bin_size_m` / `tree_render_distance_m` / `tree_render_fade_m`, so
  rocks pop in at the same range as everything else roadside.
- The merged meshes are cached process-wide by species index, built once per run.
- `rocks_enabled` removes the meshes **and** their hitboxes, mirroring
  `vegetation_enabled`.
