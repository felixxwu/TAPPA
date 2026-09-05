# Menu background showcase (`MenuShowcase` / `MenuShowcaseCamera`)

All six phases of `todo/menu-background-showcase.md`'s build are implemented. Read
that file for the design decisions behind each choice; this file describes what's
actually shipped.

**Sources:** `scripts/menu_showcase.gd` (`class_name MenuShowcase`), `scripts/menu_showcase_camera.gd`
(`class_name MenuShowcaseCamera`), `menu_showcase.tscn`, the spawn in
`scripts/hub_shell.gd::_ready`.

**Tests:** `tests/headless/test_menu_showcase.gd` (integration — builds the full
six-segment scene once in `before_all`), `tests/headless/test_menu_showcase_geometry.gd`
(pure segment/border-safety/weather-eligibility maths, no terrain built),
`tests/headless/test_menu_showcase_camera.gd`.

## What it is

A live 3D scene behind `HubShell`'s flat 2D pages: one fixed-seed track sliced into
six arc-length SEGMENTS, one per `RegionLibrary` region, each wearing that region's
ground look. A `MenuShowcaseCamera` cuts between fixed shots in every segment, never
closer than a fixed margin to a segment boundary, and each segment independently
cycles through weather conditions eligible for its own region. No car, no run, no
player input — pure scenery.

## Hosting: no `SubViewport` needed

`hub.tscn`'s root (`HubShell`) is a `Control`. `MenuShowcase` is added as a plain
child of it in `hub_shell.gd::_ready` (`_showcase = load("res://menu_showcase.tscn").instantiate();
add_child(_showcase)`), NOT via the `SubViewport`/`Sprite3D` compositing trick
`WorldPanel` uses ([world-panel.md](world-panel.md)) — that mechanism is for
embedding 2D UI *into* a 3D scene at an angle, the opposite problem. `Node3D` and
`CanvasItem` content coexist natively in one `Viewport`, with 2D always compositing
over 3D, so the hub's existing pages need no changes at all to draw on top of it.

**Skipped under headless** (`Platform.is_headless()` gate in `hub_shell.gd`): it
costs a real (if small) multi-segment track generation, which every hub test would
otherwise pay for zero visual benefit. `test_menu_showcase.gd` is the dedicated
coverage of the scene itself, built directly rather than through the hub.

## One track, six segments (`MenuShowcase._build`)

Builds a track from a hardcoded seed (`SHOWCASE_SEED`, `TURN_COUNT`, `STRAIGHTNESS`
— authored/tunable by eye, not asserted in tests) using `TrackGenerator.generate()`
directly — no lockfile, no `RunSession`, no car. `segment_bounds(total_length,
segment_count)` (a pure, tested static function) splits the generated centerline
into `segment_count` evenly-spaced arc-length ranges, one per
`RegionLibrary.ordered()` entry **in that array order** — a deliberate, feature-local
reuse of an ordering `regions.md` otherwise says carries no meaning; here it's purely
a display convenience for which segment gets which region.

**Why six separate `TerrainManager` instances, and why that's NOT six times the
terrain cost:** each segment gets its own `TerrainManager` (segment 0 reuses the
scene's own authored `$Floor` node; segments 1-5 are `TerrainManager.new()`), each
carrying its own duplicated `chunk_material` so texturing one segment can never
bleed into another. All six instances bake the **same centerline** with the **same
`noise_seed`** and the same `cfg.apply_cliffs`/`bake_args`, so the underlying height
field is byte-identical across every segment boundary — only the *surface material*
differs, which is what keeps the ground seamless where two regions meet despite
being six separate objects. The total resident geometry is the same either way (one
instance blending six looks over N chunks vs. six instances each owning a disjoint
1/6th of the same N chunks) — see `todo/menu-background-showcase.md`'s decision 4
correction for the reasoning this avoided repeating.

**Splitting one shared corridor, not six independent ones**
(`MenuShowcase._coords_in_range`): `corridor_coords()` is computed ONCE over the
whole track, then each segment's `TerrainManager` gets only the coords whose chunk
centre's arc-length position — via `Curve2D.get_closest_offset`, the same
"nearest point on the curve" query the road-surface code uses elsewhere — falls in
that segment's `[lo, hi]` range (inclusive on both ends, so a chunk exactly on a
shared boundary gets built into both neighbours rather than neither — a harmless
duplicate, not a gap).

**Why chunks are spawned directly (`_spawn_segment`) instead of
`build_initial()`/`_reconcile`:** those build only a RING (`target_coords`, radius
`load_radius`) around ONE focus point, meant for a focus that keeps moving and
streams the rest in over time (a real stage's car). Nothing here ever moves, and a
segment's corridor is a curving BAND along its stretch of road, not a disc around
one point — a single ring left real, camera-visible holes (`"terrain cache miss …
corridor region invariant broke"`) everywhere the road bent away from
`build_initial()`'s default focus (world-origin, since no `focus_path` was wired).
The fix: call `TerrainManager._spawn_one(coord)` — the same shared "read from
`_chunk_cache`, else …" ladder `_reconcile` itself calls per coord — directly for
every coord in the segment's own corridor slice, then `flush_detail_queue()`. No
focus, no eviction, no streaming: the correct one-shot equivalent for a scene that
never moves.

**Why `menu_showcase.tscn` duplicates `main.tscn`'s `WorldEnvironment`/`Floor`
sub-resources instead of loading `main.tscn` itself:** `main.tscn`'s root script is
`world.gd`, whose `_ready()` immediately drives the full run-boot pipeline
(`LoadingScreen`, `RunSession`, the car, damage, coins, …) — instantiating it as a
shortcut to "borrow its Floor node" would run all of that unintentionally.
Duplicating the two node blocks (same shader, same textures, same terrain-layer
resources, same `Environment` params) gets byte-identical rendering with none of
that. There's no `DirectionalLight3D` to duplicate either — a stage's terrain
lighting is baked per-vertex by `TerrainManager` itself (`_bake_light`/
`vertex_colors`), not a scene light.

**Per-segment ground look** (`_apply_region_ground_look`) mirrors
`world.gd::_apply_region_look`'s ground/tarmac handling exactly (apply only the keys
the region actually overrides — `grass_texture` → `albedo_texture`, `gravel_texture`
→ `road_texture`, `tarmac_color` falling back to `cfg.tarmac_color`) — but
deliberately NOT the sky/fog half of that function, which one shared
`WorldEnvironment` can't represent for six regions simultaneously; see the weather
section below for how that's actually handled.

**A material is ALWAYS duplicated, even for a region (home) that authors no
override today**, and even for segment 0's already-in-the-scene `$Floor` node:
`menu_showcase.tscn` embeds `chunk_material` as a plain sub-resource with no
`resource_local_to_scene`, so — exactly like `main.tscn`'s `PanoramaSkyMaterial` (see
[regions.md](regions.md) → "The sky no longer leaks between stages") — it is the
SAME object across every instantiation of this scene in one process. Mutating it in
place would leak whichever region/weather happened to occupy segment 0 into every
later hub open.

**Known limitation, not guarded automatically:** the border-safety rule only guards
ADJACENT segments along the road's own arc length. It does not check whether the
generated track loops back SPATIALLY close to a distant, non-adjacent segment. A
pathological seed could route two arc-far segments close enough in world space for a
wide shot in one to see the other's ground. `SHOWCASE_SEED` is eyeballed for this
the way any authored look is eyeballed.

## `MenuShowcaseCamera` and border safety

Modelled on `ReplayCamera`'s shape ([event-replay.md](event-replay.md)) — a
deterministic, testable `_tick(delta)`, a fixed per-shot dwell (`SHOT_DWELL`),
`look_at` per shot — but with **no followed target**: shots are fixed
`{"pos": Vector3, "look_at": Vector3}` points authored by the caller, not a car
being tracked. A small circular drift (`DRIFT_RADIUS_M`/`DRIFT_SPEED`) is added
around each shot's own position so a held shot reads as a slow crane move rather
than a locked-off photograph.

**Border safety** (`safe_shot_arcs(lo, hi, margin_m, ahead_m, count)`, a pure,
tested static function): a shot's arc-length position AND its look-ahead point
(`s + ahead_m`) must both stay at least `_BORDER_MARGIN_M` clear of both segment
boundaries. A segment too short for the margin/ahead/count combination gets NO
shots rather than an unsafe one — `_build_segment_shots` skips it silently. On the
shipped `SHOWCASE_SEED`/`TURN_COUNT`, every segment clears it
(`test_camera_rotation_covers_every_region_segment` asserts the full rotation
includes all six).

## Per-segment weather cycle

Each segment independently cycles, every 20-45 seconds (`_WEATHER_REROLL_MIN_S`/
`_MAX_S`, cosmetic timing — non-deterministic `randf_range` is fine here, the same
allowance `world.gd`'s lightning-flash scheduler documents), through weather ids
ELIGIBLE FOR ITS OWN REGION — snapping to a new `WeatherLibrary` condition, never
blending. `_REGION_WEATHER_IDS` is the showcase's own eligibility table, the
equivalent of `RallyLibrary` authoring `"sandstorm"` only onto `region == "greece"`
events and `"snow"` only onto `region == "snow"` ones
(`test_menu_showcase_geometry.gd` mirrors `test_rally_library.gd`'s
`test_sandstorm_only_authored_on_greece_events` shape for it): home/home_coast/taiga
cycle dry/rain/fog/storm/night; greece/greece_coast cycle dry/sandstorm/night; snow
cycles dry/snow/night. Never rain in the snow segment, never snow outside it.

**Split into two halves, for a reason found while implementing it:**

- **The GROUND half** (`_apply_segment_road_tint`) is a live shader uniform change
  on the segment's own (never-shared) material — cheap, and applied continuously to
  EVERY segment regardless of which one the camera is looking at. It's the exact
  read-modify-write `world.gd::_tint_road` does (re-seed `albedo_color`/
  `tarmac_color` to the segment's own baseline, then multiply-darken or lerp toward
  a named colour per the condition's `road_tint` entry), just against a segment's
  own material instead of the one `$Floor.chunk_material` a real stage repaints in
  place.
- **The ENVIRONMENT half** (`_apply_segment_environment`) is NOT applied
  continuously, and deliberately drops one piece `world.gd::_apply_overcast_look`
  does: it also writes `TerrainManager.sun_color`/`sky_color`, which only take
  effect on the terrain's next BAKE. Chunks already spawned keep their baked-in
  vertex lighting forever — six already-built, never-rebuilt segments can't cheaply
  re-light the way a real stage does by rebaking before the player ever sees it. So
  only the shared `WorldEnvironment`'s sky/fog/background is swapped (there is
  exactly one `WorldEnvironment` for the whole scene, so it couldn't show six skies
  at once regardless), and only for whichever segment the camera CURRENTLY frames —
  applied exactly at the moment of a camera CUT (`_process` compares
  `_camera.current_shot()` against `_viewed_shot` each frame and re-applies on
  change), so the swap is never seen happening. `MenuShowcase._shot_segments` maps
  each shot index back to the segment it was built from, so this works regardless of
  how many shots any one segment ended up contributing.
- **Not built at all**: particles (rain/sand/snow quads), the lightning flash, wind,
  and headlights. All of `WeatherLibrary`'s per-condition blocks beyond `look` and
  `road_tint` are skipped — deliberately, as excessive for a decorative background
  that has no chase camera or car to hang them off, not an oversight.

## What's still not built

Per `todo/menu-background-showcase.md`'s phased plan: per-segment foliage (trees/
bushes matching each region's `tree_mix`) and the mobile LOD-tier cap (feeding every
`TerrainManager` instance the lowest in-run quality tier's LOD bands regardless of
device). Both are scoped in the spec but not yet implemented.

## Tests

`tests/headless/test_menu_showcase.gd` — built ONCE in `before_all` (six
`TerrainManager` bakes over a real track is not cheap) and shared read-only across
its tests: the build completes and the camera is live; one `TerrainManager` per
region with at least one built chunk each; the camera rotation covers every
segment; no two segments ever share a material instance; road-tint application/
reversion; the environment swap on a forced cut. `tests/headless/test_menu_showcase_geometry.gd`
— pure maths with no terrain: segment-boundary splitting, `safe_shot_arcs`'
border-clearance and too-short-segment cases, and the weather-eligibility table's
compatibility invariants (every id real, sandstorm/snow/rain restricted to the
right regions). `tests/headless/test_menu_showcase_camera.gd` — mirrors
`test_replay_camera.gd`'s deterministic-tick coverage for the fixed-shot case:
faces the current shot's `look_at`, advances on the fixed dwell, wraps around,
doesn't crash on an empty shot list.
