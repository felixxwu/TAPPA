# Architecture & Project Layout

**Tests:** `tests/headless/test_smoke.gd`, `tests/headless/test_world_isolation.gd`

## Directory layout

```
.                          # repository root = Godot project root
├── title.tscn             # Boot scene (set in project.godot): hands straight over to free_roam.tscn
├── free_roam.tscn         # The game: one persistent island (see free-roam.md)
├── main.tscn              # The dev stage and physics test harness (world.gd)
├── car.tscn               # VehicleBody3D car, instanced into both world scenes
├── project.godot          # Engine config: autoloads, input map, rendering
├── run_tests.sh           # Test runner (headless + visual passes)
├── config/
│   └── game_config.tres   # GameConfig resource — all tuning values
├── scripts/               # All GDScript (see file map below)
├── shaders/               # ps1_models.gdshader, ps1_post_process.gdshader
├── textures/              # terrain, sky, sign and car textures
├── tests/                 # GUT tests (headless/, fixtures/)
├── addons/gut/            # Vendored GUT unit-test framework
└── features/              # ← this documentation folder
```

## Scene routing (`Scenes`)

`scripts/scenes.gd` (`class_name Scenes`, a static-only `RefCounted`) is the single
source of truth for scene paths and for **which scene is "the hub"**:

- `Scenes.TITLE` / `FREE_ROAM` / `MAIN` / `CAR` — the canonical paths.
- `Scenes.hub_path()` — the destination for every "return to the front door" transition (the
  title). One indirection, so the front door can change without touching the transition sites.
- `Scenes.is_hub_scene(path)` — the hub predicate, used where the hub is detected from a
  live scene path rather than chosen (see [music.md](music.md) → "The hub-scene
  predicate").
- `Scenes.change_to(tree, path)` — **the single enforced scene-change point**, with a
  run-scoped kill switch the test pre-run hook arms so no production transition can park a
  live scene under `/root` mid-run. It records the blocked destination, so a test can
  assert where a transition was headed without performing it.

Tests should compare captured paths against `Scenes.hub_path()`, not a literal.

## Free-roam scene tree (`free_roam.tscn`)

```
FreeRoam [Node3D]                   script: free_roam/free_roam.gd
├── WorldEnvironment
├── Terrain [Node3D]                TerrainStreamer — streamed chunks, foliage, sites
├── Car                             instance of car.tscn (+ BonnetCamera)
├── ChaseCamera / CameraManager
├── PostProcess / SpeedLines / HUD / MobileControls / PauseMenu
├── RoadRecovery / BiomeDirector / RestStops / LootDirector
└── RestStopPage / WorldPages / MiniMapLayer
```

See [free-roam.md](free-roam.md) for how they fit together.

## Dev stage scene tree (`main.tscn`)

```
Main [Node3D]                       script: world.gd
├── WorldEnvironment                fog + background color from config
├── Floor [Node3D]                  script: terrain_manager.gd (chunk manager)
│   └── (TerrainChunk children)     spawned at runtime, 3×3 around the car
├── Car [VehicleBody3D]             instance of car.tscn, at (0,1,0)
├── ChaseCamera [Camera3D]          script: chase_camera.gd, targets Car
├── PostProcess [SubViewportContainer] script: post_process_view.gd; material: ps1_post_process.gdshader (colour grade + dither)
│   └── View [SubViewport]          shares the main World3D; renders the 3D frame
│       └── ViewCamera [Camera3D]   mirror of the active gameplay camera
└── HUD [CanvasLayer]               script: hud.gd, layer 2
    └── SpeedLabel / GearLabel / RPMLabel
```

## Car scene tree (`car.tscn`)

```
Car [VehicleBody3D]                 script: car.gd, mass 120
├── Chassis [MeshInstance3D]        red box
├── EngineAudio [AudioStreamPlayer] script: engine_audio.gd
├── Cabin [MeshInstance3D]          dark-blue box
├── CollisionShape3D                BoxShape3D
├── WheelFL / WheelFR [VehicleWheel3D]  use_as_steering = true
└── WheelRL / WheelRR [VehicleWheel3D]  use_as_traction = true
        └── Visual/Tire + Spoke1 + Spoke2 (per wheel)
```

## Autoloads / singletons

Declared in `project.godot` `[autoload]`:

- **`Config`** → `scripts/config.gd`. Loads `config/game_config.tres` at startup
  into `Config.data` (a `GameConfig`). Every gameplay system reads from it.
  ⚠️ It is a **single shared instance that `car.gd`'s `apply_car()`/`apply_owned()`
  MUTATE in place** to reshape the live car (gearbox, mass, grip, engine, …) —
  it is NOT read-only. Because it is global, the **last car applied wins**: if a
  second car instance is fielded after the player, its spec overwrites the
  player's. A car whose shift table / drivetrain was already built then keeps
  reading the clobbered values — snapshot + restore `Config.data` around any
  secondary `apply_car()`. See [configuration.md](configuration.md).
- **`Save`** → `scripts/save_manager.gd`. Loads the player profile (owned cars, settings,
  lifetime stats, the world block) from `user://profile.json` at boot and autosaves on every meaningful change. Per-player *mutable progress*, kept
  distinct from `Config`'s authored baseline. See
  [save-persistence.md](save-persistence.md).
- **`Cloud`** → `scripts/cloud/cloud_manager.gd`. Optional Firebase account +
  Firestore profile sync. Inert until the player signs in, and the dependency
  runs ONE WAY (`Cloud` subscribes to `Save`'s `profile_changed`/`flushed`;
  `Save` knows nothing about it), so the game behaves identically with cloud
  save unused. It owns the project's only `HTTPRequest`, behind `RestClient` —
  which is also the seam the headless tests fake. See
  [cloud-save.md](cloud-save.md).
- **`WorldSession`** → `scripts/world_session.gd`. The persistent free-roam world in the
  profile (seed, car, pose, lit rest stops, map) — the only writer of the world block. See
  [world-session.md](world-session.md).
- **`InputRemap`**, **`Benchmark`**, **`DisplayStretch`**, **`WebFullscreen`**,
  **`PerfLog`**, **`CarPreviewCache`** — the remaining autoloads; see [controls.md](controls.md),
  [benchmark.md](benchmark.md), [mobile-controls.md](mobile-controls.md),
  [testing.md](testing.md) and [card-carousel.md](card-carousel.md) respectively.
- **`Music`** → `scripts/music_director.gd`. The interactive music loop; also
  creates the **Music** and **Engine** mix buses at boot. See [music.md](music.md).
- **`Audio`** → `scripts/audio.gd` (`class_name AudioManager`). One-shot sound
  effects, and the **SFX** bus. **Any "play a sound when X happens" work goes
  through `Audio.play_beep(...)` — never a hand-rolled `AudioStreamGenerator` at
  the call site.** It owns the headless guard, the
  `play()`→`get_stream_playback()` ordering and the reused player. See
  [sfx.md](sfx.md).

## Data flow

1. `Config` autoload loads `game_config.tres` before any scene runs.
2. In the dev stage, `world.gd._ready()` pushes config values into scene-owned resources
   (environment fog/color, terrain layers, material colors, post-process res —
   `_apply_scene_config`), fields the player's car (`_field_player_car`), then
   generates the world. `_ready` and `_generate_track` are both phase sequences
   over private per-phase coroutines; see [loading.md](loading.md). Behaviour the
   world host shares with any future one lives in `scripts/world_runtime.gd`
   (`WorldRuntime`, all statics). It first puts up a full-screen `LoadingScreen`
   (`scripts/loading_screen.gd`, created in code) and advances its step label
   across generation stages (track → carve road into terrain → precompute
   terrain → trees → bushes), yielding a frame between each so the message paints
   before the blocking work. The road-carving bake (`TerrainManager.set_track`,
   the heaviest single step) additionally yields frames *within* itself on the
   interactive path (`should_yield`), so the overlay keeps painting instead of
   freezing under the "generating track" label as it used to. Godot's
   boot bar only covers engine + `.pck` load; this overlay covers the heavy
   world-gen that runs afterwards. Under headless the per-step `await`s are
   no-ops, so generation stays synchronous (tests see a fully-built world right
   after instantiating `main.tscn`). The overlay is freed once the world is up.
   Before generation begins, `_ready` also sets `$Car.controls_locked = true` so
   the player can't press W and drive off behind the overlay during those awaited
   frames (the car is already in the tree and physics-processing); every
   end-of-generation spawn path resets `controls_locked` (`StageManager.setup`,
   `BenchmarkRunner.setup`), so the lock only governs the loading window.
   During the track stage the overlay also shows a growing line of the track
   above the loading text, driven by real generation progress via
   `LoadingScreen.update_track_preview` (see [track.md](track.md)) and held once
   generation completes. That line is drawn **grey**; during "Carving road into
   terrain…" it fills **white** from the start as the bake walks the centerline
   (`bake_track`'s `on_progress` → `LoadingScreen.set_carve_progress`), a spatial
   progress indicator that ends fully white. During the "Precomputing chunks…" stage the preview
   additionally draws each cached chunk as a dark square behind the track line
   (`LoadingScreen.set_chunk_size` once, then `update_loaded_chunks` per yield
   batch, fed from `world.gd`). The view stays framed on the track, so the outer
   band of the corridor clips at the panel edge.
3. Per-system scripts (`car.gd`, `drivetrain.gd`, `engine.gd`, `chase_camera.gd`,
   `terrain_manager.gd`, `hud.gd`, `engine_audio.gd`) read `Config.data` directly for
   their own tunables.
4. Gameplay loop runs in `_physics_process` (car/drivetrain/engine/camera) and
   `_process` (HUD, audio buffering).

### Principle: push heavy one-time work behind a loading screen

There is one opaque loading cover in the game — the **stage / world-gen** one
(`world.gd._ready`, above, via `scripts/loading_screen.gd`). **Anything expensive that can be done up front should be
done behind whichever cover is already up, rather than lazily on a button press or the
first frame it's needed** — especially work that would otherwise cause a visible lag spike
or stutter mid-interaction. The player already expects to wait at a loading screen; a beat
added there is invisible, whereas the same beat during play is a hitch.

Concretely, prefer moving into a loading screen: scene/prop instantiation for things the
player will reach soon, mesh / material / texture duplication, shader pre-warm compiles (see
[rendering.md](rendering.md) → "Shader pre-warm"), and any first-use resource `load()` that
would otherwise fire on a transition. When you add a feature whose first use is heavy, ask
whether the cost can be paid at boot behind a cover instead — if so, move it there and warm
into a session-lived cache. (The one caveat: don't blindly move UNBOUNDED work behind the
cover — if the cost scales with, say, a 300-car collection, warm only what's imminently
needed and keep the rest lazy, so the loading screen itself doesn't grow without limit.)

## Async results: key staleness off a counter, never off displayed text

Async work (an `await`, a progressive spawn, a generated search) whose result may no longer
be wanted is guarded by a per-file generation counter (`settings_menu.gd::_sl_gen` is the
live example): bump it when the state is rebuilt, capture it before the async work, and
compare after. **Never key that decision off a Control's displayed text:** `UITheme.enforce`
uppercases every Label and Button after a page is built, so a guard comparing a label to a
literal like `"Top 50%"` silently never matches once it reads `"TOP 50%"`.

## Key conventions

- **Config-first:** never hardcode tuning in scripts/scenes; add a `GameConfig`
  field and read it. Literals in scenes/scripts are fallback only.
- **Custom tire physics:** Godot's built-in `VehicleWheel3D` friction is disabled
  (friction slip set to 0); all contact forces come from `drivetrain.gd`.
