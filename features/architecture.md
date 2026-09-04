# Architecture & Project Layout

**Tests:** `tests/headless/test_smoke.gd`, `tests/headless/test_world_isolation.gd`, `tests/headless/test_stale_guard.gd`

## Directory layout

```
.                          # repository root = Godot project root
├── hub.tscn               # Boot scene — the flat shell (set in project.godot); see hub-shell.md
├── main.tscn              # The run scene (one stage / dev free-roam)
├── car.tscn               # VehicleBody3D car, instanced into main.tscn
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

- `Scenes.HUB` / `MAIN` / `CAR` — the canonical paths. (`PODIUM` and `STANDINGS` were
  deleted with their scenes, decisions 19 and 30; the run summary is a `HubShell` page and
  the between-stage beat is `RunPickPanel`, so neither is a scene any more.)
- `Scenes.hub_path()` — the destination for every "return to the hub" transition. One
  shell today; the indirection is what let the hub be swapped out (diegetic 3D HQ → flat
  `hub.tscn`) without touching the transition sites.
- `Scenes.is_hub_scene(path)` — the hub predicate, used where the hub is detected from a
  live scene path rather than chosen (see [music.md](music.md) → "The hub-scene
  predicate").
- `Scenes.change_to(tree, path)` — **the single enforced scene-change point**, with a
  run-scoped kill switch the test pre-run hook arms so no production transition can park a
  live scene under `/root` mid-run. It records the blocked destination, so a test can
  assert where a transition was headed without performing it.

**Why the seam.** The boot scene is also the "back to the hub" destination, and that path
was hardcoded at seven transition sites. All of them call `hub_path()` instead:
`pause_menu.gd::quit_to_hq`, `benchmark_mode.gd::exit_to_hq`, and the `world.gd`
transitions (through its `_change_scene` / `scene_change_hook` test seam). Tests should
compare captured paths against `Scenes.hub_path()`, not a literal. The swap from `hq.tscn`
to `hub.tscn` is what this seam bought.

## Main scene tree (`main.tscn`)

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
  second car instance is fielded after the player (e.g. the start-line queue
  props in `start_line.gd._spawn_queue`), its spec overwrites
  the player's. A car whose shift table / drivetrain was already built then keeps
  reading the clobbered values — snapshot + restore `Config.data` around any
  secondary `apply_car()` (as `_spawn_queue` does). See [configuration.md](configuration.md).
- **`Save`** → `scripts/save_manager.gd`. Loads the player profile (owned cars, HP, money,
  boost levels, perks, lifetime stats, the paused-run slot) from `user://profile.json` at
  boot and
  autosaves on every meaningful change. Per-player *mutable progress*, kept
  distinct from `Config`'s authored baseline. See
  [save-persistence.md](save-persistence.md).
- **`Cloud`** → `scripts/cloud/cloud_manager.gd`. Optional Firebase account +
  Firestore profile sync. Inert until the player signs in, and the dependency
  runs ONE WAY (`Cloud` subscribes to `Save`'s `profile_changed`/`flushed`;
  `Save` knows nothing about it), so the game behaves identically with cloud
  save unused. It owns the project's only `HTTPRequest`, behind `RestClient` —
  which is also the seam the headless tests fake. See
  [cloud-save.md](cloud-save.md).
- **`RunSession`** → `scripts/run_session.gd`. The run-level stage-flow orchestrator —
  idle until a run starts, then survives the per-stage scene reloads while it sequences
  stages, the timer, money and the between-stage pick. Which KIND of run is live is a
  `RunMode` question (a region run or the Daily/Weekly/Monthly challenge), not a second
  autoload. See [region-runs.md](region-runs.md). It replaced `RallySession`, deleted with
  the career loop (decision 5).
- **`InputRemap`**, **`Benchmark`**, **`DisplayStretch`**, **`WebFullscreen`**,
  **`PerfLog`** — the remaining autoloads; see [controls.md](controls.md),
  [benchmark.md](benchmark.md), [mobile-controls.md](mobile-controls.md) and
  [testing.md](testing.md) respectively.
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
2. `world.gd._ready()` pushes config values into scene-owned resources
   (environment fog/color, terrain layers, material colors, post-process res —
   `_apply_scene_config`), fields the player's car (`_field_player_car`), then
   generates the world. `_ready` and `_generate_track` are both phase sequences
   over private per-phase coroutines; see [loading.md](loading.md). Behaviour the
   world host shares with any future one lives in `scripts/world_runtime.gd`
   (`WorldRuntime`, all statics — it had a second caller, `overworld.gd`, now deleted). It first puts up a full-screen `LoadingScreen`
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
(`world.gd._ready`, above, via `scripts/loading_screen.gd`). The HQ had a second; it is
deleted, and the flat shell needs none. **Anything expensive that can be done up front should be
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

## `StaleGuard` — the "is this async result still wanted?" idiom

Several scripts run async work (an `await`, a per-frame progressive spawn, a
generated search) whose result must be discarded if the underlying state was
rebuilt while it was in flight — a stale coroutine writing into freed rows, or
an old preview request clobbering a newer one. `scripts/stale_guard.gd`
(`class_name StaleGuard`) names and generalises this: `bump()` a counter when
the state is rebuilt, `token()` to capture the current generation before the
async work starts, `is_current(t)` to check after the `await` returns before
acting on the result.

It generalised five hand-rolled instances, each invented under its own private name with
no shared vocabulary — four of them (`hq.gd::_settle_generation`,
`hq.gd::_challenge_refresh_generation`, `standings.gd::_reveal_gen`,
`podium.gd::_reveal_gen`) are deleted with their hosts. The one that remains is
`settings_menu.gd::_sl_gen` (the seed-lab preview, which also threads an `abort: Callable`
closure into `TrackGenerator.generate`), and it has **not** been migrated onto `StaleGuard`
either. So the class currently has no callers at all: it is the named home for the idiom,
and adopting it is still open work. The reasoning below is why the idiom exists.

**The rule that motivated it:** a Control's DISPLAYED TEXT is never a valid
key for deciding whether an async result still applies. `UITheme.enforce`
(`scripts/ui_theme.gd`) uppercases every Label's and Button's text after a
page is built — a blanket styling pass that runs after the page's own code
set that text. A bug traced to exactly this: an async handler guarded its
write by comparing a Label's live text back to a literal like `"Top 50%"`,
which `UITheme.enforce` had since rewritten to `"TOP 50%"`, so the comparison
never matched and the answer was silently discarded every time. It reads as
equivalent to a generation check — "compare something captured earlier to
something read now" — but text is a presentation-layer value subject to
later, unrelated rewrites (styling, localization, truncation) that a
`StaleGuard` token is not: nothing else ever touches the token, so it stays a
faithful stand-in for "was there a rebuild since I started". Use `StaleGuard`
(or the existing per-file `_gen`/`_generation` counters) instead of ever
keying a decision off a Control's text.

## Key conventions

- **Config-first:** never hardcode tuning in scripts/scenes; add a `GameConfig`
  field and read it. Literals in scenes/scripts are fallback only.
- **Custom tire physics:** Godot's built-in `VehicleWheel3D` friction is disabled
  (friction slip set to 0); all contact forces come from `drivetrain.gd`.
