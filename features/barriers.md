# Corner Barriers

Solid crash barriers along the **outside of the stage's sharp corners** — run wide
and you hit something. Built from 2 m modules stitched end to end, procedurally
like [finish-arch.md](finish-arch.md) / [signs.md](signs.md), in the PS1
flat-shaded look. Three rules decide what a corner gets:

- **Only where the land falls away.** A barrier guards a DROP. Where the corner is
  cut into a bank the hillside already stops the car, so nothing is built.
- **The barrier matches the road surface:** steel armco guardrail on gravel,
  precast concrete jersey rail on tarmac.
- **The run follows the terrain**, each module pitched onto the slope and spaced
  along the sloping ground, so a barrier climbing a hill stays joined up.

| Thing | File |
|-------|------|
| The 2 m module (both looks) | `scripts/barrier_section.gd` (`BarrierSection`) |
| Planner (pure, scene-free) | `scripts/barrier_layout.gd` (`BarrierLayout`) |
| Builder (`Node3D`) | `scripts/barrier_field.gd` (`BarrierField`) |
| Placed by | `scripts/world.gd._build_barriers` |
| Tunables | `GameConfig` › *Corner Barriers*, bundled by `barrier_render_params()` |
| Render harness | `tools/render_barriers.gd` + `.sh` → `docs/barriers/*.png` |
| Tests | `tests/headless/test_barrier_section.gd` (the module), `test_barrier_layout.gd` (planning rules), `test_barrier_field.gd` (poses, slope, batching), `test_smoke.gd` (the world wiring) |

## The two looks

| `BarrierSection.Style` | What it is | Height | Used on |
|------------------------|------------|--------|---------|
| `ARMCO` | Galvanised steel W-beam on one post per module, with a spacer block and a splice bolt in the corrugation valley | ~0.76 m | **Gravel** |
| `JERSEY` | Precast concrete jersey/K-rail — the symmetric profile extruded along the run, a cast seam at one end (so a stitched joint shows a single line, not a doubled band that reads as a gap), a red-over-white reflector plate on the road face | ~0.81 m | **Tarmac** |

`style_for_tarmac(tarmac_weight, threshold)` is the whole selection rule: at or
above the threshold it's the jersey rail, below it the armco. The weight is the
0..1 tarmac-ness `TerrainManager.surface_at().y` reports, so a stage whose
gravel↔tarmac switch ([track.md](track.md), `TrackSurface`) falls **inside** a
corner gets a barrier that changes type at the seam.

Each style's palette is a `const` block at the top of `barrier_section.gd`, so
re-tinting one (say a region's weathered concrete) is a one-line change.

## The module contract

Both styles obey one local frame, so placement is style-agnostic:

```
+Z / -Z   the run direction (length axis), the module centred on z = 0
+Y        up, ground at y = 0
+X        the ROAD side — the face the driver sees; mass sits behind it
```

`BarrierField._module_transform` builds that frame: local +Z is the run direction
lifted onto the ground's slope, local +X is the horizontal inward (road-facing) normal
orthogonalised against it, and +Y falls out of the cross product. On level ground it
reduces to `Basis.looking_at(Vector3(n.y, 0, -n.x), UP)` for an inward normal `n` in
XZ, which is what the render harness's simpler `_place` uses for its flat shots.

**Stitching.** Modules are laid at `barrier_section_length_m` pitch **along the
barrier line** (see the planner below — this is the thing that has to be right, not
the module). The continuous parts (the armco beam, the jersey extrusion) then overrun
each module end by `joint_overlap` to swallow the two small residuals: the
chord-vs-arc shortfall on a curve (under 2 mm at a 12 m radius) and the few
centimetres the builder adds for the per-style face reach, which the planner does not
model. The 6 cm default covers both with room to spare — the overlap only ever shows
as harmless interpenetration between two opaque flat-shaded modules.

**No per-module jitter, on purpose.** Both barriers are manufactured, identical
units in real life, and identical modules are what let `BarrierField` draw a whole
run from one MultiMesh per part. `test_barrier_section.gd` guards this
(`test_modules_of_a_style_are_identical`) so jitter can't creep back in and silently
break the batching.

**Double-sided surfaces.** The swept/extruded surfaces (`_sweep_open`,
`_extrude_closed`) emit every triangle **both ways** with per-side flat normals via
`_tri2`. On a module this small the extra triangles are noise, and it removes all
front-face winding ambiguity — a barrier is never see-through from the angle the
camera happens to be at. (Contrast `FinishArch`, which hand-winds its caps and had
to reason about Godot treating CW-as-seen as front-facing.)

**Material.** One `ShaderMaterial` per colour, cached per module, on
`shaders/ps1_models_lit.gdshader` — the same flat fake-lit shader as the car and the
arches. No textures.

`local_aabb()` is the union of the child meshes' transformed boxes: the module's
footprint (`size.z`), height (`size.y`) and thickness (`size.x`). `BarrierField`
uses it for the collision box and for the road gap (see below). It is conservative
(box union, not silhouette), which is what a hitbox wants.

## Planning a run (`BarrierLayout`, pure)

`plan(centerline, pieces, params, tarmac_at, ground_at)` returns one dict per module —
`{pos, tangent, side, style, run}` — using the same `side` convention as
`SignLayout`/`SignField` (`edge = pos + side * Vector2(-tangent.y, tangent.x) * d`).
Static, scene-free and unit-tested without a scene, like `TrackGenerator` /
`SignLayout` / `TreeScatter`. `tarmac_at` is an injected
`func(pos: Vector2) -> float` (the world passes `TerrainManager.surface_at().y`);
with no sampler every module falls back to armco. `ground_at` is the terrain-height
sampler both terrain rules read — see *Reading the terrain*; with no sampler the
hill-or-drop filter is skipped and every module is kept, which is what a flat harness
or unit test wants.

- **Which corners** — `BARRIER_CORNERS` = `{1, 2, Square, Hairpin}`: the *sharp*
  ones. Deliberately a tighter set than `SignLayout.TURN_CORNERS` (which signs "4 or
  sharper") — a grade 3/4 sweeper needs no armco.
- **Drop, not bank** (`_land_falls_away`) — see *Reading the terrain* below. Judged
  per module, so half a corner can be barriered and half left bare.
- **The arc** — a piece is a connecting straight then the corner, so the corner runs
  from `entry_pos + entry_heading * straight` to the **next** piece's `entry_pos`
  (the last piece runs to the end of the centerline). `barrier_lead_m` extends the
  run before the entry and past the exit, so the barrier is already there when the
  car arrives rather than starting on the apex.
- **Spaced along the BARRIER LINE, in 3D.** This one matters, and it bit twice. A
  module is a rigid `pitch`-long bar, so its centres have to be spaced a pitch apart
  *along the line it actually stands on*, not along any shadow of that line:
    - **Laterally**, the barrier stands `track_width/2 + barrier_road_gap_m` off the
      centerline on the OUTSIDE of the bend — the **longer** arc. At a 12 m corner
      with a 4.2 m offset it is 35% longer, so centerline-spaced modules fan out to
      2.7 m apart where they stand: a 0.7 m hole at every joint.
    - **Vertically**, a module laid on a climb covers only `pitch × cos(slope)` of
      ground, so horizontal spacing leaves a gap that grows with the gradient (2 cm
      at 15%, past the joint overlap by 25%).
  So `_barrier_walk` walks the offset line over the run — lifted onto the terrain when
  a `ground_at` sampler is available — accumulating true 3D distance against
  centerline arc offset, and `_offset_at_distance` inverts that mapping. The run is
  then continuous at any curvature and any gradient. `test_barrier_layout.gd` guards
  every direction of it: barrier-line spacing equals the pitch, mid-corner centerline
  spacing is provably *shorter*, a climb tightens horizontal spacing by exactly the
  cosine, and level ground collapses back to the plain pitch.
- **Whole modules, centred** — the run holds `floor(barrier-line length / pitch)`
  modules, centred in the available arc so the barrier is symmetric about the corner.
- **Which side is the outside** — measured **from the curve**, not from the piece's
  `flip` flag: the 2D cross product of the tangents `CURVE_EPS_M` either side of the
  corner's mid-point says which way the road bends, and the outside is the opposite
  edge. This can't drift from whatever handedness `TrackGenerator.mirror_points`
  uses, and it was worth doing — the 2D generator frame calls
  `Vector2(fwd.y, -fwd.x)` "right", which is the *opposite* of the driver's right
  once mapped into Godot's 3D axes.
- **No stacking** — runs are planned in track order and each start is clamped to the
  previous run's end, so two adjacent sharp corners can't lay two barriers over the
  same stretch of verge.

## Reading the terrain

Both terrain rules read the same injected `ground_at` sampler —
`TerrainManager.height_at`, i.e. the carved terrain the player actually drives on and
collides with, road flatten and cliff offsets included. The planner uses it to decide
*whether* to build; the builder to decide *how* each module sits.

### Drop, not bank (`BarrierLayout._land_falls_away`)

Two separate conditions, both sampled outboard of the barrier and compared with the
road surface at the module:

1. **No hill.** Neither the near nor the far sample may sit more than
   `barrier_hill_tolerance_m` above the road. Any real rise on that side means the
   corner is cut into a slope — the near sample matters here because a bank usually
   starts climbing right at the road edge. The tolerance is small but non-zero because
   terrain noise lifts a verge a few centimetres above road level even where the land
   genuinely falls away further out; at zero the rule would coin-flip on those.
2. **A committed drop.** The FAR sample must sit at least `barrier_drop_min_m` below
   the road. Judged on the far sample alone, because the drop RAMPS IN: the carve
   pass's cliff band only reaches full depth about 2 m past the flatten band, so the
   near sample is still partway down the slope and would veto perfectly good cliffs.
   This is also the flat-ground cutoff — level verge is not a drop, so it gets nothing.

The probes MUST reach beyond the road's flatten band (`track_transition_cells`, 3 m
outside the road edge by default): inside it the carve pass has blended the ground to
road height, so every corner would read as flat. That is why `barrier_slope_probe_m`
is measured out from the road EDGE, and why its default clears the flatten band plus
the cliff pass's rise.

The test is per module, so a corner banked for half its length is barriered over the
falling half only. The surviving stretches are then filtered by
`barrier_min_run_modules` and each becomes its own run — a one- or two-module stub
reads as debris dropped on the verge rather than as a barrier.

### Following the slope (`BarrierField._module_transform`)

Each module's pitch comes from sampling the ground under its two ENDS, not its centre.
Both ends then sit ON the terrain, so a module's far end and its neighbour's near end
— the same point on the ground — arrive at the same height and the rail is continuous
over a climb or a crest. A single centre height with the module left level is exactly
what makes a run up a hill a staircase with a gap at every joint.

It leans **along the run only**: the road-facing axis stays horizontal, so the posts
stand up rather than the whole barrier tipping toward the road. On the shipped
geometry the barrier line lies inside the road's flatten band, so the heights it reads
are the carved road's own smooth gradient rather than raw verge noise — the pitch
follows the road up the hill and cannot jitter module to module.

## Building it (`BarrierField`)

`build(layout, params, ground_at)` takes the height sampler rather than a
`TerrainManager`, so the whole builder is unit-testable against a synthetic slope with
no scene, terrain or world in play (`test_barrier_field.gd`), and the render harness
can lay a run on its own flat stage by passing nothing.

### The frame — pin two axes, derive the third

Both placement paths must produce a basis with **`+Y` world up**, because a module's geometry
occupies `+Y` only: `local_aabb().position.y` is `0` and it rises from there. `BarrierField.
_module_transform` gets this right by construction (it derives its middle axis from the pair it
pinned), and the overworld's roadblocks originally did **not**: they picked `+X` (the road-facing
axis) and `+Z` (the run axis) independently, which for a run laid *across* a road yields a
right-handed basis whose Y column points **down**. Determinant `+1`, so nothing looked wrong — and
every barrier in the hub stood upside down, 0.81 m below the road surface. The player reported it
as "all concrete barriers are sunk into the ground", and it was not a terrain-height bug at all.

If you write a third placement path: pin the two axes that carry meaning and take the third from a
cross product, then assert `basis.y ≈ Vector3.UP` in its test.

`build_modules(style, xforms, params)` is the **other** entry point: it takes module
centre poses the caller already worked out (obeying the local frame above) and skips
the roadside layout entirely, sharing everything below the transforms — prototype
reuse, batching, culling and collision. Its one client is the overworld's
**roadblocks** (`OverworldBlocks`, [overworld.md](overworld.md) → "Roadblocks"), a
short jersey-rail run laid **across** a carriageway to signal a road the player
cannot take yet — the opposite orientation to a roadside run, which is why it computes
its own poses rather than going through `BarrierLayout`. `module_aabb(style, params)`
exposes the prototype's silhouette so such a caller spaces and aligns its run against
the real model instead of a guessed size.

**Rendering: one MultiMesh per part, per run.** A run's modules are identical, so
each part of the prototype (beam, post, bolt, …) becomes one `MultiMeshInstance3D`
holding one instance per module. The prototype `BarrierSection` is built off-tree,
its `parts()` and `local_aabb()` harvested, and the node freed — nothing of it stays
in the scene.

Batches are anchored at their **run's centroid**, not the world origin, because the
shared world-prop render cull measures camera→node origin: one whole-track batch at
the origin would test the wrong distance and pop every barrier in at once. This is
the same trap `SignField` documents. Cull distance is the shared world-prop range
(`cfg.tree_render_distance_m` / `tree_render_fade_m`, via
`MeshUtil.apply_visibility_range`), so barriers appear with the rest of the roadside
dressing — see [rendering.md](rendering.md) → "Shared render distance".

**Collision: solid, and it costs HP.** Unlike the signs — cosmetic clutter the car
ploughs straight through ([signs.md](signs.md)) — a barrier stops you. Each
(run, style) group gets one `StaticBody3D` carrying a box per module, all sharing a
single `BoxShape3D` via the physics server (`ObstacleBody.build_oriented`), in the
damage `OBSTACLE_GROUP` so clipping one costs HP like a tree
([damage.md](damage.md)). `build_oriented` was added for this: the tree fields only
needed upright boxes at ground points, while a barrier box must be **turned** to
follow the road.

Each box is the model's full silhouette but exactly `pitch` long, so neighbours tile
along the run instead of overlapping into wedges that could catch a wheel. It is
full height even where the model is open underneath (under the armco beam) — a car
should be stopped by a guardrail, not slide under it.

Two details worth knowing:

- **Ground height is sampled AT THE BARRIER**, not at the centerline. The signs and
  arches stand on the flattened road band so they can use the centerline height; a
  barrier sits outside it, where that height would float or bury it on a cambered
  verge. Each module is then sunk by `barrier_sink_m` so small unevenness under a
  rigid 2 m module buries its foot rather than showing daylight under it.
- **The collision box inherits the pitch**, since the shapes are placed with the
  module's own transform — a barrier on a slope collides where it is drawn.
- **The road gap is measured to the model's face.** `barrier_road_gap_m` is the clear
  gap from the visible road edge to the barrier's nearest face, and the offset adds
  the prototype's `local_aabb().end.x` — so the armco beam and the wider-footed
  jersey rail leave the *same* gap instead of the jersey's foot creeping onto the
  road.

Static bodies never fall, so — unlike the signs, which spawn frozen because terrain
collision is only streamed in a ring around the car — there is nothing to freeze
here. Nothing to reset between the run and the replay either
(`world._reset_props_for_replay` only touches props that move).

## Keeping trees out of the barrier

`TreeScatter` rejects trees on the road footprint inflated by `tree_road_margin_m`
(`world._build_foliage`), and it knows nothing about barriers — the barriers are built
after the foliage. So the barrier has to fit inside the band the trees already avoid,
or a trunk grows straight through the guardrail (with its own obstacle hitbox, no
less).

That is one inequality, in metres from the centerline:

```
track_width/2 + barrier_road_gap_m + barrier depth  <=  track_width/2 + tree_road_margin_m
```

The jersey rail is the deeper of the two (0.6 m at the foot), so with the shipped
1.0 m tree margin the gap has to stay at or under 0.4 m — which is what it defaults
to. Widen `barrier_road_gap_m` and `tree_road_margin_m` needs to follow, or trees
start appearing inside the barrier.

## Config (`GameConfig` › *Corner Barriers*)

`barriers_enabled` (master switch — the benchmark's barriers toggle drives it, see
[benchmark.md](benchmark.md)), `barrier_section_length_m` (the stitch pitch),
`barrier_road_gap_m`, `barrier_lead_m`, `barrier_tarmac_threshold`,
`barrier_sink_m`, plus the terrain rule: `barrier_slope_probe_m` (how far out from the
road edge the hill-or-drop probe reads), `barrier_drop_min_m` (how far the ground must
fall before a stretch is worth guarding — also the flat-ground cutoff) and
`barrier_hill_tolerance_m` (how much rise still counts as level) and
`barrier_min_run_modules` (shortest barrier worth building). Bundled for both layers by
`barrier_render_params()`, which also carries `track_width` and the shared render
distance.

## Cost

Per module, after the double-siding: armco ~250 triangles, jersey ~200. A run of ~10
modules draws in 4–5 calls (one per part) plus one collision body, so a stage with
three or four barriered corners costs a handful of draw calls — cheap enough for
mobile ([mobile-web-performance](../todo/mobile-web-performance.md)).

## Visual iteration (`tools/render_barriers.sh`)

The headless dummy renderer can't read back pixels, so the barriers are eyeballed by
rendering real GL frames offscreen under `xvfb`:

```sh
tools/render_barriers.sh        # writes docs/barriers/*.png
```

It loads the real `config/game_config.tres` (falling back to a hand dict if that
can't load standalone) so the renders show the shipped pitch and gap. Outputs:

| Output | View |
|--------|------|
| `<style>_module.png`, `sheet_module.png` | the single 2 m module alone, close up |
| `<style>_straight.png`, `sheet_straight.png` | modules stitched down a straight, with a car-sized proxy for scale |
| `corner_gravel/tarmac/mixed.png`, `sheet_corner.png` | the **real pipeline** — `BarrierLayout` planning a sharp corner and `BarrierField` building it, for an all-gravel stage, an all-tarmac stage, and one whose surface switch falls mid-corner |
| `corner_slope_drop/bank.png`, `sheet_slope.png` | the pipeline over a synthetic HEIGHT FIELD: the same corner climbing a hill with the land falling away outboard (a run pitched onto the slope) and cut into a bank (nothing built) |

The corner shots pick no side, no style, and no stretch by hand — that is the point of
them. They are how the "outside of the bend" solve, the surface-driven style swap, the
slope pitching and the drop-not-bank rule get checked by eye, not just by unit test.
The slope shots' height field climbs by ANGLE around the corner rather than along a
world axis: a hillside climbing along +Z also lifts the outboard probes, which cancels
the drop and makes the demo lie about the rule.

## Tests

- `tests/headless/test_barrier_section.gd` — the module contract: both styles build
  real geometry on the PS1 shader, stand on the ground, span their own pitch (so
  stitched neighbours meet), stay thin enough to line a road edge, rebuild rather
  than accumulate, are **identical between builds** (the batching precondition),
  expose `parts()` for instancing, follow `length`, and `style_for_tarmac` picks
  concrete above the threshold and steel below.
- `tests/headless/test_barrier_layout.gd` — the planning rules against a hand-built
  bend: only sharp corners get a run, modules are stitched at the configured pitch,
  the run lands on the **outside** of the bend (checked geometrically against the
  arc's centre, not against a sign convention), the style follows the injected
  surface sampler (including a switch mid-corner), the lead extends the run,
  adjacent runs don't stack, degenerate input plans nothing, and the plan is
  deterministic. Plus the terrain rules: a drop is barriered, a bank and flat ground
  are not, only the falling stretch of a part-banked corner is built, a stub shorter
  than the minimum is dropped, separated stretches get their own runs, a caller with
  no sampler still gets a full run, and spacing tightens by exactly the cosine on a
  climb while collapsing back to the pitch on the level.
- `tests/headless/test_barrier_field.gd` — the builder, scene-free against a synthetic
  ground: modules stand outside the road facing it, stay level on level ground, pitch
  onto a slope without rolling sideways or skewing, put both ends ON the terrain, meet
  their neighbours' end heights over a slope, render batched with one shared-shape
  obstacle body per style, and build nothing from an empty layout.
- `tests/headless/test_smoke.gd` — the wiring only (it needs the real scene and baked
  terrain): `world._build_barriers` reads the live config, plans off the track pieces,
  samples the baked surface and terrain, and drops one `BarrierField` into the scene.

## Possible next steps

- **Region flavour** — a region look override for the barrier palette (Greek concrete
  runs paler than home's), alongside `tarmac_color` in
  [regions.md](regions.md).
- **Damage feedback** — barriers are in `OBSTACLE_GROUP`, so they cost HP, but they
  don't deform, scatter debris or scrape sparks. A scrape reaction would sell them.
- **Cross-slope camber** — modules pitch along the run but never roll, so on a
  strongly cambered verge a module's outboard foot can lift. Rolling to the ground
  normal would fix it, at the cost of the posts leaning; worth doing only if it shows
  in play.
