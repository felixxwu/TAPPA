# Corner Barriers

**Sources:** `scripts/barrier_section.gd` (`BarrierSection`, a self-building
`Node3D`). Iterated visually with `tools/render_barriers.gd` + `.sh`; reference
renders in `docs/barriers/`. Tests: `tests/headless/test_barrier_section.gd`.

A **2 m module of roadside crash barrier**, meant to be **stitched end to end**
into a continuous run along the **outside of a sharp corner**. Built entirely
from code, like [finish-arch.md](finish-arch.md) / [signs.md](signs.md), so it
matches the procedural-asset style and the PS1 flat-shaded look — no imported
mesh, every proportion a constant in one file.

> **Status: a menu of candidate looks, not yet placed in the world.**
> Six styles are implemented behind the `style` enum so one can be chosen by
> eye; nothing calls `BarrierSection` from `world.gd` yet. See *Not done yet*
> below for what wiring it up needs.

## The six candidates

| `Style` | What it is | Height | Reads as |
|---------|------------|--------|----------|
| `ARMCO` | Galvanised steel W-beam on one post per module | ~0.76 m | Mountain / tarmac stage, the most "motorsport-official" |
| `TYRE_WALL` | Worn tyres stood **on edge**, faces to the road, two staggered courses on driven stakes | ~1.1 m | Club-level rally, service park, cheapest-looking |
| `HAY_BALES` | Straw bales in two staggered courses, twine showing | ~0.8 m | Iconic rally corner protection, warm and soft |
| `TIMBER_RAIL` | Log post-and-rail fence, two round rails | ~1.0 m | Forest stage; the airiest (you see through it) |
| `JERSEY` | Precast concrete jersey/K-rail with cast seams + a reflector plate | ~0.81 m | Hard, permanent, Greek-tarmac / Dakar |
| `STONE_WALL` | Dry-stone rubble wall — solid core dressed with jittered stones and a coping course | ~0.63 m | Greek terraces, lanes; the most "landscape" |

Each style's palette is a `const` block at the top of the script (`_STEEL`,
`_STRAW`, `_CONCRETE`, …), so re-tinting one for a region is a one-line change.

## The module contract

Every style obeys the same local frame, so placement code can be
style-agnostic:

```
+Z / -Z   the run direction (length axis), module centred on z = 0
+Y        up, ground at y = 0
+X        the ROAD side — the face the driver sees; mass sits behind it
```

A section is therefore placed with its **Z axis along the road tangent** and its
**+X turned in toward the racing line**. Given the inward (road-facing) normal
`n` in XZ, the basis is `Basis.looking_at(Vector3(n.y, 0, -n.x), UP)` — see
`_place` in `tools/render_barriers.gd`, which is the reference implementation for
whatever eventually places these in the world.

Key `@export`s: `style`, `length` (the stitch pitch, 2 m), `joint_overlap` (how
far continuous parts overrun each module end), `variant_seed`, `sun_direction`.

**Stitching.** Modules are laid at `length` arc pitch. Two things keep a run
looking continuous rather than repetitive:

- **Continuous parts overrun the ends** by `joint_overlap` (the armco beam, the
  jersey extrusion, the stone core, the timber rails), so the tiny chord-vs-arc
  shortfall on a curve never opens a visible gap. Around a 12 m-radius corner
  that shortfall is under 2 mm, so the default 3 cm overlap is ample.
- **Courses straddle the joints.** The hay-bale top course is half-length at
  each end, and the tyre wall's staggered course owns the tyre landing *on* its
  far end and none at its near end — so two neighbours combine into one
  unbroken staggered pattern instead of butting up as identical blocks.
- **Per-module jitter** (`variant_seed`) varies bale angles, stone sizes and
  tyre slop, so a run reads hand-built. It is **reproducible**: the same seed
  always rebuilds the same module, so a regenerated stage looks identical.

`local_aabb()` returns the union of the child meshes' AABBs in local space — the
module's footprint (`size.z`), height (`size.y`) and thickness (`size.x`). It is
conservative (each part contributes its *transformed box*), which is what a
future collision box wants.

**Double-sided surfaces.** The custom swept/extruded surfaces (`_sweep_open`,
`_extrude_closed`) emit every triangle **both ways** with per-side flat normals,
via `_tri2`. On a module this small the extra triangles are noise, and it removes
all front-face winding ambiguity — a barrier is never see-through from the angle
the camera happens to be at. (Contrast `FinishArch`, which hand-winds its caps
and had to reason about Godot treating CW-as-seen as front-facing.)

**Material.** One `ShaderMaterial` per colour, cached per module, on
`shaders/ps1_models_lit.gdshader` — the same flat fake-lit shader as the car and
the arches, so barriers catch the same hemisphere+sun shading. No textures.

**Rough cost per module** (triangles, after the double-siding): `TIMBER_RAIL` and
`ARMCO` are the cheapest (~150–250), `JERSEY` ~200, `HAY_BALES` ~300,
`STONE_WALL` ~450, `TYRE_WALL` the most expensive (~1000 — six faceted tori).
A long run will want the same treatment `SignField` gives its signs: one
**MultiMesh per part material** instead of a node per part. Worth weighing when
picking a style, especially for mobile
([mobile-web-performance](../todo/mobile-web-performance.md)).

## Choosing a look (`tools/render_barriers.sh`)

The headless dummy renderer can't read back pixels, so the candidates are
eyeballed by rendering real GL frames offscreen under `xvfb`:

```sh
tools/render_barriers.sh        # writes docs/barriers/*.png
```

For every style it renders three views and saves them per style plus as three
**contact sheets** (3x2 grids) for side-by-side comparison:

| Output | View |
|--------|------|
| `<style>_module.png`, `sheet_module.png` | the single 2 m module alone, close up |
| `<style>_straight.png`, `sheet_straight.png` | modules stitched down a straight, with a car-sized proxy for scale |
| `<style>_corner.png`, `sheet_corner.png` | the real use case — a run around the outside of a 12 m-radius corner |

The harness stages its own ground, road strip, road ring and blocky car proxy
(4.1 x 1.35 x 1.8 m, so barrier heights can be judged against the player's car)
and is autoload-free, like `tools/render_garage.gd`.

## Not done yet

Wiring a chosen style into the driven world still needs:

1. **A planner** — which corners get a barrier and over what arc. The natural
   input is the same piece list `SignLayout.plan` reads (see [signs.md](signs.md)):
   the sharp corners are already identified there as
   `SignLayout.TURN_CORNERS` (`{1, 2, 3, 4, Square, Hairpin}`), and the run wants
   the **outside** edge, i.e. the opposite side to the corner's handedness.
2. **A builder** placing modules at `length` arc pitch off the centerline curve,
   at `terrain.height_at` for the road surface — mirroring `SignField.build`.
   Uneven terrain will need per-module ground height (and probably a small
   downward skirt so a module never floats on a crest).
3. **Collision + damage.** Unlike signs (which are deliberately decoupled from
   the car), a barrier should be **solid** — a `StaticBody3D` box per module from
   `local_aabb()`, on the world layer, and in the damage obstacle group so a
   clip costs HP ([damage.md](damage.md)).
4. **Batching** — a MultiMesh per part material, as above.
5. **Render cull** — `MeshUtil.apply_visibility_range` at the shared world-prop
   distance (`cfg.tree_render_distance_m` / `tree_render_fade_m`), like the signs
   and arches ([rendering.md](rendering.md) → "Shared render distance").
6. **Config** — a `Barriers` group in `GameConfig` (`barriers_enabled`, the
   chosen style, edge inset, minimum corner sharpness) rather than script
   literals, plus a benchmark toggle ([benchmark.md](benchmark.md)).
