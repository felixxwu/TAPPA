# Night weather + fake headlight cone — implementation spec

> Status: **NOT STARTED — spec only, design settled.** All five open questions
> were decided on 2026-08-16 (see § Decisions); nothing is left to agree before
> implementation. Grounded in the code as of 2026-08-16.
> Includes a dead-code removal (`shaders/billboard.gdshader` and the
> `BillboardField` quad path) that is independent of the night feature and can
> land first on its own.

## Goal

A `night` weather condition: the world darkens, and the terrain / trees / props
in a cone in front of the player's car light up, faking headlights — **without
adding a single light node**, without touching geometry per frame, and without
rebaking terrain vertex colours.

## Why the obvious approach is wrong

Terrain shading is deliberately **baked into vertex colours on the CPU**:
`TerrainManager.vertex_colors()` writes `ARRAY_COLOR` per chunk (RGB = baked
light, ALPHA = road blend weight), consumed by `shaders/ps1_models.gdshader`'s
`ALBEDO = mix(ground, road, COLOR.a) * albedo_color.rgb * COLOR.rgb`.

Driving a moving light by **rebaking those colours** would mean regenerating
`ARRAY_COLOR` for ~49 loaded chunks at 51×51 = 2601 verts each (`CHUNK_M = 50.0`,
`SAMPLES = 51`, `RADIUS = 3`) — ~127k verts at LOD0 — every frame. That is a
chunk-*generation* cost, not a per-frame cost. It is the one approach this spec
exists to rule out.

The renderer also has **no lights at all** to fall back on: there is no
`DirectionalLight3D` in `main.tscn` and no light on `car.tscn`; every shader is
`render_mode unshaded`. `features/rendering.md` states this as a design
principle, and `world.gd::_start_lightning` is explicitly commented as *not*
using a light node. A `SpotLight3D` would therefore have zero effect on any
existing material.

## Approach

An **analytic cone evaluated in the shaders**, fed by three values updated once
per frame. No geometry, no draw calls, no CPU per-frame work beyond the update.

```glsl
vec3 v     = world_pos - headlight_pos;
float d    = length(v);
float cone = smoothstep(hl_cos_outer, hl_cos_inner, dot(v / max(d, 0.001), hl_dir));
float att  = 1.0 - smoothstep(0.0, hl_range, d);
float lit  = cone * att;
// darken to night, then re-light inside the cone
tint *= mix(1.0, mix(night_darkness, 1.0, lit), night_amount);
```

`night_amount` at 0 makes every shader below a bit-for-bit no-op, matching the
existing `light_amount = 0` convention in `billboard_opaque.gdshader`.

### Per-fragment vs per-vertex

| Surface | Stage | Why |
|---|---|---|
| Terrain (`ps1_models`, `ps1_terrain_snow`) | **fragment** | Cells reach 25 m wide at the coarsest LOD (`LOD_STRIDES = [1,2,5,10,25]`); per-vertex would snap the cone edge to triangles. |
| Cars / barriers / arch (`ps1_models_lit`) | **vertex** | Already has `varying vec3 v_light`; fold `lit` into it. |
| Trees (`billboard_opaque`) | **vertex** | Already has `varying vec3 v_tint`; cards are small, per-vertex is visually identical. |
| Bushes (`tree_canopy`) | **vertex** | Needs a *new* varying — it has no lighting term today. |

Fragment cost lands only on terrain, which is the one surface with near-total
screen coverage. Everything else folds into an existing vertex computation.

**Overdraw is not a concern.** Trees are opaque mesh-baked silhouettes: the
cutout is baked into `TreeSilhouette`'s geometry, both fades are geometry
shrink-outs in `vertex()`, and a standing tree collapses plane 1 to a point so it
presents a single card. `billboard_opaque.gdshader`'s header spells out that this
is deliberate — no `discard` anywhere, so early-Z / HSR stays on for the draw.
`tree_canopy.gdshader` was migrated off its per-fragment dither `discard` for the
same reason.

### Transport: shader globals

Add a `[shader_globals]` section to `project.godot` (the project has none today)
declaring `hl_pos` (vec3), `hl_dir` (vec3), `night_amount` (float), and set them
with `RenderingServer.global_shader_parameter_set`.

Rationale is **correctness under streaming**, not speed. Materials are already
shared per batch — `sign_field.gd::_materials` is keyed by texture, each
`BillboardField` builds one material for its whole MultiMesh, `foliage.gd::bush_mesh`
bakes one material onto the shared mesh, and terrain uses the single
`chunk_material` sub-resource of `main.tscn` — so a per-material push would only
be ~10–30 calls per frame. But those materials are built in five scripts with no
common registry, and terrain chunks stream continuously, so a per-material push
needs re-registration bookkeeping on every chunk load. Globals have none.

**Scene-leak trap:** global shader parameters persist across scene changes. The
podium and HQ share these shaders (`podium.gd:215`, `hq_environment.gd:132` both
call `Foliage.spawn_trees`), so `night_amount` **must be reset to 0
unconditionally** on entering any non-stage scene — exactly the reasoning behind
`_apply_deep_snow_ground` being called unconditionally each stage boot.

### Per-frame driver

`world.gd` has **no `_process` or `_physics_process`** today. Add a `_process`
that early-outs when `night_amount == 0`, reading `$Car.global_transform`
(forward is `-basis.z`, per the `world.gd:461` camera precedent) and offsetting
the origin forward/up to the bonnet line.

## Weather-table integration

`WeatherLibrary.CONDITIONS` is an authored table of 6 entries; the active one is
chosen by event data (`RallyLibrary.event_weather` → `cfg.weather` at
`rally_session.gd:1050`), not rolled. Night is a 7th entry plus a
`RallyLibrary.WEATHER_NIGHT` constant.

A `look` block must author **all five** `LOOK_KEYS` or none (`world.gd` reads
them unguarded as a set), so night needs `night_background_color`,
`night_sky_color`, `night_sun_energy_mult`, `night_fog_density_mult`,
`night_fog_sky_affect` in `GameConfig`'s `@export_group("World")`, following the
existing `rain_` / `sand_` / `mist_` / `storm_` / `snowfall_` prefix convention,
each with a `##` doc comment. Values go in `config/game_config.tres`.

Plus new fields for the cone itself: `night_amount`, `night_darkness`,
`headlight_range_m`, `headlight_inner_deg`, `headlight_outer_deg`,
`headlight_color`, `headlight_offset_m`.

### Bug this exposes

`_apply_overcast_look` scales the sun into `tm.sun_color` (TerrainManager) and
the environment **only** — it never touches car materials. `apply_car_light`
pushes `cfg.sun_color` raw. So today, *any* condition with a low
`sun_energy_mult` (rain at 0.6, storm at 0.45) already leaves cars lit at full
brightness against a dimmed world. At night this becomes glaring: a fully lit car
floating in the dark.

Fix: give `apply_car_light` the same multiplier the terrain gets. This is a
pre-existing bug that night merely makes obvious — worth fixing regardless, and
it will subtly change how cars look in rain/storm.

## Test constraints (read before touching a shader)

`tests/headless/test_render_smoke.gd` pins the flat-terrain design hard:

- **`test_terrain_shader_has_no_vertex_stage`** — `ps1_models.gdshader` must not
  contain `void vertex()` **nor the string `light_amount`**.
- **`test_car_meshes_are_lit_but_terrain_is_flat`** — the terrain material's
  `light_amount` parameter must read back `null`.

The fragment-only, differently-named design above threads this needle
deliberately: no vertex stage on `ps1_models`, and no uniform named
`light_amount`. **Do not rename the night uniforms into `light_amount`** — these
tests encode agreed behaviour and should not be weakened to accommodate a
shortcut.

- `test_all_shaders_sample_textures_with_nearest_filter` scans every
  `.gdshader`: any new `sampler2D` line needs `filter_nearest`. (This design adds
  no samplers.)
- **Uniform-set parity is load-bearing.** `_apply_deep_snow_ground`
  (`world.gd:2224`) swaps `ps1_models` ⇄ `ps1_terrain_snow` and re-applies only
  `snow_depth`, relying on `ShaderMaterial` keeping its by-name parameter map
  across the swap. That works only because the two declare identical uniform
  sets. **Any night uniform added to one must be added to the other**, or its
  value silently drops on a snow stage.

New tests to add: `night_amount = 0` leaves shader output unchanged; the cone
factor is 1 straight ahead at zero distance and 0 behind / beyond range (test the
math, not the authored angles — per `CLAUDE.md`, never pin tunable values); the
global uniform resets to 0 on entering HQ/podium.

## Dead code removal: `billboard.gdshader` + the quad path

**Independent of the night work — can land first.**

`shaders/billboard.gdshader` (the `alpha_scissor` + `discard` cutout billboard)
is **unreachable in production**. `BillboardField.build()` takes `mesh` and
`opaque` params and computes `var use_opaque := mesh != null and opaque`
(`billboard_field.gd:94`). The only production construction site is
`foliage.gd:74`, which always passes `tree_silhouette_mesh(tex)` and `true`. All
three callers of `Foliage.spawn_trees` (`world.gd:919`, `podium.gd:215`,
`hq_environment.gd:132`) route through it, and no `.tscn` constructs a
`BillboardField` at all. `foliage.gd:6` already asserts the invariant in a
comment: "Trees are ALWAYS opaque billboard cutouts."

Delete: the shader + its `.uid` (UID `uid://b6484oijq47xf` appears nowhere else —
the preload is by path), the `BILLBOARD_SHADER` const, the QuadMesh branch
(`billboard_field.gd:105-111`), the `_use_opaque` field and its guards in
`knock_down` (:269) and `_upright_basis` (:251), the `mm.use_custom_data`
conditional (:148), and the `if use_opaque` guards on the light/near-fade
uniforms (:121-131). **Keep** `size_jitter_min` / `aspect_jitter` — `foliage.gd`
passes real config values into both.

Tests to update (they exercise the quad path deliberately, so this is a genuine
behaviour change, not a weakening):

- `test_smoke.gd:372 test_billboard_field_builds_instances_and_collision`
- `test_smoke.gd:500 test_billboard_field_knock_down_safe_without_collision_or_quad_path`
- `test_smoke.gd:621 test_billboard_field_without_collision_has_no_body`
- `test_smoke.gd:302 test_shaders_load_with_code` — pins the
  `billboard.gdshader` **path**; drop that entry.

Docs referencing it, to re-check (some may point at
`billboard_particle.gdshader`, a different live file — verify each before
editing): `features/README.md:109,140`, `features/rendering.md:258,620`,
`features/trees.md:98`, `features/wheel-dust.md:77`,
`todo/performance-optimisations.md:177,434,447,465`.

Also stale and worth correcting in the same sweep: `todo/backlog.md` claims
"bushes are still cutout billboards and need their own low-poly mesh", but
`foliage.gd::bush_mesh` builds from `GROUNDCOVER_SCENE` (a GLB) with
`TREE_CANOPY_SHADER` and no discard. That item appears done.

## Docs to update in the same piece of work

`features/weather.md` (the new condition + the `apply_car_light` fix),
`features/rendering.md` (the cone, and the shader-globals section — the
"no lights" principle now has a named exception mechanism),
`features/trees.md` + `features/README.md` (billboard removal),
`features/terrain.md` (terrain is no longer purely flat-shaded at night).

## Decisions (settled 2026-08-16)

1. **Night is a weather type** — a 7th `WeatherLibrary.CONDITIONS` entry, not an
   orthogonal axis. Accepted consequence: **night-and-raining is not possible**,
   because `cfg.weather` is single-valued. If that combination is ever wanted,
   night gets promoted to its own flag with a composed look-blend in
   `world.gd::_apply_weather_look` — a materially bigger change, deliberately
   deferred rather than designed for now.
2. **One cone**, not two headlights. Cheaper, and in keeping with the PS1 look.
   Splitting it into two offset cones later is a localised change to the cone
   math, so nothing here forecloses it.
3. **Player car only** — no cones on opponent or ghost cars. The global uniforms
   therefore carry exactly one cone, and the shaders need no array uniform or
   loop, keeping the cost fixed rather than scaling with field size.
4. **Purely a look** — night carries no `grip_mult` and does not shorten
   `render_distance`. Lap times and the benchmark model are unaffected, so no
   rebalancing and no opponent-cache invalidation (night contributes nothing to
   `WeatherLibrary.physics_fields`).
5. **No mobile gate.** The terrain cone stays per-fragment on all platforms. A
   per-vertex fallback would visibly facet on the coarse LOD rings, and the cost
   should be measured on device before any concession is designed. Revisit only
   if a real measurement justifies it.
