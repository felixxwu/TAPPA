# Menu background showcase (`MenuShowcase` / `MenuShowcaseCamera`)

> **PHASE 1 PROTOTYPE.** This is step 1 of the phased build in
> `todo/menu-background-showcase.md` — read that file for the full multi-region
> design and the decisions behind it. What's described here is only what's actually
> shipped: one fixed-seed track, one region's look, a camera cutting between a
> handful of fixed shots. Multi-region segments, the border-safety camera rule, the
> per-region weather cycle, and foliage are **not built yet**.

**Sources:** `scripts/menu_showcase.gd` (`class_name MenuShowcase`), `scripts/menu_showcase_camera.gd`
(`class_name MenuShowcaseCamera`), `menu_showcase.tscn`, the spawn in
`scripts/hub_shell.gd::_ready`.

**Tests:** `tests/headless/test_menu_showcase.gd`, `tests/headless/test_menu_showcase_camera.gd`.

## What it is

A live 3D scene behind `HubShell`'s flat 2D pages: a small, fixed-seed procedural
track and terrain the camera flies around, cutting between a handful of fixed shots
on a timer. No car, no run, no player input — pure scenery.

## Hosting: no `SubViewport` needed

`hub.tscn`'s root (`HubShell`) is a `Control`. `MenuShowcase` is added as a plain
child of it in `hub_shell.gd::_ready` (`_showcase = load("res://menu_showcase.tscn").instantiate();
add_child(_showcase)`), NOT via the `SubViewport`/`Sprite3D` compositing trick
`WorldPanel` uses ([world-panel.md](world-panel.md)) — that mechanism is for
embedding 2D UI *into* a 3D scene at an angle, the opposite problem. `Node3D` and
`CanvasItem` content coexist natively in one `Viewport`, with 2D always compositing
over 3D, so the hub's existing pages need no changes at all to draw on top of it.

**Skipped under headless** (`Platform.is_headless()` gate in `hub_shell.gd`): it
costs a real (if small) track generation, which every hub test would otherwise pay
for zero visual benefit. `test_menu_showcase.gd` is the dedicated coverage of the
scene itself, built directly rather than through the hub.

## `MenuShowcase` (`scripts/menu_showcase.gd`)

Builds a track from a hardcoded seed (`SHOWCASE_SEED`, `TURN_COUNT`,
`STRAIGHTNESS` — authored/tunable by eye, not asserted in tests, same rule as any
other look value) using `TrackGenerator.generate()` directly — no lockfile, no
`RunSession`, no car. The recipe is the same one `world.gd::_generate_track` uses,
stripped of everything run/session-specific:

1. `TrackGenerator.generate(params)` → a `Curve2D` centerline.
2. `_floor.set_track(centerline, ...bake_args)` — bakes the road into the terrain
   (`TerrainManager.bake_args(cfg)` is the same shared arg-deriver every baker in the
   game uses, so this can't drift from how a real stage bakes).
3. `_floor.set_corridor(_floor.corridor_coords(centerline, _CORRIDOR_LEASH_M))` then
   `cache_chunk` every corridor coord — precomputes every chunk any shot could see
   BEFORE the camera moves, so nothing streams in lazily once it's on screen (the
   same "resident before it's needed" rule the full multi-region design leans on,
   applied here to one region's chunks).
4. `_floor.build_initial()` — builds the ring from the now-fully-cached corridor.
5. Builds a `MenuShowcaseCamera`, hands it a handful of fixed shots
   (`_build_shots`) sampled at evenly spaced arc-length points around the loop, and
   sets `current = true`.

**Why `menu_showcase.tscn` duplicates `main.tscn`'s `WorldEnvironment`/`Floor`
sub-resources instead of loading `main.tscn` itself:** `main.tscn`'s root script is
`world.gd`, whose `_ready()` immediately drives the full run-boot pipeline
(`LoadingScreen`, `RunSession`, the car, damage, coins, …) — instantiating it as a
shortcut to "borrow its Floor node" would run all of that unintentionally.
Duplicating the two node blocks (same shader, same textures, same terrain-layer
resources, same `Environment` params) gets byte-identical rendering with none of
that — this is the exact reuse CLAUDE.md's "never invent an asset filename" rule
allows: every path in `menu_showcase.tscn` is one already used in `main.tscn`,
copied, not fabricated. There's no `DirectionalLight3D` to duplicate either — a
stage's terrain lighting is baked per-vertex by `TerrainManager` itself
(`_bake_light`/`vertex_colors`), not a scene light.

`RegionLibrary.look_of("home")` is never actually called in this prototype: home
authors no ground override at all (see [regions.md](regions.md)), so the scene's
own baseline shader values ARE home's look already, with nothing to apply. This
stops being free the moment a second region's segment is added — see the spec.

## `MenuShowcaseCamera` (`scripts/menu_showcase_camera.gd`)

Modelled on `ReplayCamera`'s shape ([event-replay.md](event-replay.md)) — a
deterministic, testable `_tick(delta)`, a fixed per-shot dwell (`SHOT_DWELL`),
`look_at` per shot — but with **no followed target**: shots are fixed
`{"pos": Vector3, "look_at": Vector3}` points authored by the caller, not a car
being tracked. A small circular drift (`DRIFT_RADIUS_M`/`DRIFT_SPEED`) is added
around each shot's own position so a held shot reads as a slow crane move rather
than a locked-off photograph.

`MenuShowcase._build_shots` samples `_SHOT_COUNT` evenly-spaced points around the
generated loop, each framed from a fixed elevated offset (`_SHOT_OFFSET`) looking a
little way further down the road (`_SHOT_AHEAD_M`). **The border-safety rule from
the spec doesn't apply yet** — there's only one region, so every shot is
automatically "safe."

## What's deliberately not here yet

See `todo/menu-background-showcase.md`'s phased build for the rest: slicing into
six arc-length segments (one per `RegionLibrary` region) with the border-margin
camera rule, per-segment foliage, the per-region eligible-weather cycle, and the
mobile LOD-tier cap. Nothing here should be treated as the finished mechanism.

## Tests

`tests/headless/test_menu_showcase.gd` — instantiates `menu_showcase.tscn`
(mirroring `test_smoke.gd`'s `main.tscn` pattern: instantiate, `await
get_tree().physics_frame`, assert), checks the build completes and the camera is
live with at least one shot. `tests/headless/test_menu_showcase_camera.gd` —
mirrors `test_replay_camera.gd`'s deterministic-tick coverage for the fixed-shot
case: faces the current shot's `look_at`, advances on the fixed dwell, wraps
around, and doesn't crash on an empty shot list.
