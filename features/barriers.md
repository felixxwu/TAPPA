# Corner Barriers

Solid crash barriers along the **outside of the stage's sharp corners** — run wide
and you hit something. Built from 2 m modules stitched end to end, procedurally
like [finish-arch.md](finish-arch.md) / [signs.md](signs.md), in the PS1
flat-shaded look. The barrier **matches the road surface** under it: steel armco
guardrail on gravel, precast concrete jersey rail on tarmac.

| Thing | File |
|-------|------|
| The 2 m module (both looks) | `scripts/barrier_section.gd` (`BarrierSection`) |
| Planner (pure, scene-free) | `scripts/barrier_layout.gd` (`BarrierLayout`) |
| Builder (`Node3D`) | `scripts/barrier_field.gd` (`BarrierField`) |
| Placed by | `scripts/world.gd._build_barriers` |
| Tunables | `GameConfig` › *Corner Barriers*, bundled by `barrier_render_params()` |
| Render harness | `tools/render_barriers.gd` + `.sh` → `docs/barriers/*.png` |
| Tests | `tests/headless/test_barrier_section.gd`, `test_barrier_layout.gd`, `test_smoke.gd` |

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

Given the inward (road-facing) normal `n` in XZ, the basis is
`Basis.looking_at(Vector3(n.y, 0, -n.x), UP)` — derived once in
`BarrierField._module_transform` and mirrored by the render harness's `_place`.

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

`plan(centerline, pieces, params, tarmac_at)` returns one dict per module —
`{pos, tangent, side, style, run}` — using the same `side` convention as
`SignLayout`/`SignField` (`edge = pos + side * Vector2(-tangent.y, tangent.x) * d`).
Static, scene-free and unit-tested without a scene, like `TrackGenerator` /
`SignLayout` / `TreeScatter`. `tarmac_at` is an injected
`func(pos: Vector2) -> float` (the world passes `TerrainManager.surface_at().y`);
with no sampler every module falls back to armco.

- **Which corners** — `BARRIER_CORNERS` = `{1, 2, Square, Hairpin}`: the *sharp*
  ones. Deliberately a tighter set than `SignLayout.TURN_CORNERS` (which signs "4 or
  sharper") — a grade 3/4 sweeper needs no armco.
- **The arc** — a piece is a connecting straight then the corner, so the corner runs
  from `entry_pos + entry_heading * straight` to the **next** piece's `entry_pos`
  (the last piece runs to the end of the centerline). `barrier_lead_m` extends the
  run before the entry and past the exit, so the barrier is already there when the
  car arrives rather than starting on the apex.
- **Pitched along the BARRIER LINE, not the centerline.** This one matters. The
  barrier stands `track_width/2 + barrier_road_gap_m` off the centerline on the
  OUTSIDE of the bend, which is the **longer** arc: at a 12 m corner with a 4.2 m
  offset it is 35% longer, so modules spaced 2 m apart *along the centerline* fan out
  to 2.7 m apart where they actually stand — a 0.7 m hole at every joint. So
  `_barrier_walk` walks the offset line over the run, recording cumulative distance
  along it against centerline arc offset, and `_offset_at_distance` inverts that
  mapping. Modules are then spaced by true barrier-line distance and the run is
  continuous at any curvature. `test_barrier_layout.gd` guards it from both sides —
  spacing measured on the barrier line equals the pitch, and mid-corner centerline
  spacing is provably *shorter* than the pitch.
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

## Building it (`BarrierField`)

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
`barrier_sink_m`. Bundled for both layers by `barrier_render_params()`, which also
carries `track_width` and the shared render distance.

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

The corner shots pick no side and no style by hand — that is the point of them. They
are how the "outside of the bend" solve and the surface-driven style swap get
checked by eye, not just by unit test.

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
  deterministic.
- `tests/headless/test_smoke.gd` — the build + wiring: a run lands outside the road
  edge with each module's +X turned back toward the centerline; the geometry is
  batched into MultiMeshes with **no** per-module mesh nodes and the collision is one
  shared-shape body in `OBSTACLE_GROUP` with one box per module; and
  `world._build_barriers` reads the live config, plans off the track pieces and drops
  a `BarrierField` into the scene.

## Possible next steps

- **Region flavour** — a region look override for the barrier palette (Greek concrete
  runs paler than home's), alongside `tarmac_color` in
  [regions.md](regions.md).
- **Damage feedback** — barriers are in `OBSTACLE_GROUP`, so they cost HP, but they
  don't deform, scatter debris or scrape sparks. A scrape reaction would sell them.
- **Terrain following** — a module is rigid; on a strongly cambered verge a run steps
  rather than flows. Per-module roll from the ground normal (or a skirt) would fix it
  if it shows in play.
