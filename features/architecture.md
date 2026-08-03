# Architecture & Project Layout

## Directory layout

```
.                          # repository root = Godot project root
├── hq.tscn                # Boot scene — the HQ hub (set in project.godot); see menus.md
├── podium.tscn            # End-of-rally result scene
├── main.tscn              # The run scene (a rally event / dev free-roam)
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

## Main scene tree (`main.tscn`)

```
Main [Node3D]                       script: world.gd
├── WorldEnvironment                fog + background color from config
├── Floor [Node3D]                  script: terrain_manager.gd (chunk manager)
│   └── (TerrainChunk children)     spawned at runtime, 3×3 around the car
├── Car [VehicleBody3D]             instance of car.tscn, at (0,1,0)
├── ChaseCamera [Camera3D]          script: chase_camera.gd, targets Car
├── PostProcess [SubViewportContainer] script: post_process_view.gd; material: ps1_post_process.gdshader (colour grade + dither); hq.tscn hosts the same subtree
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
  props in `start_line.gd._spawn_queue`, or the HQ lineup), its spec overwrites
  the player's. A car whose shift table / drivetrain was already built then keeps
  reading the clobbered values — snapshot + restore `Config.data` around any
  secondary `apply_car()` (as `_spawn_queue` does). See [configuration.md](configuration.md).
- **`Save`** → `scripts/save_manager.gd`. Loads the player profile (owned cars,
  HP, inventory, rally completion) from `user://profile.json` at boot and
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
- **`RallySession`** → `scripts/rally_session.gd`. The rally-level event-flow
  orchestrator — idle until a rally starts, then survives the per-event scene
  reloads while it sequences events, placement and rewards. See
  [rally-session.md](rally-session.md).

## Data flow

1. `Config` autoload loads `game_config.tres` before any scene runs.
2. `world.gd._ready()` pushes config values into scene-owned resources
   (environment fog/color, terrain layers, material colors, post-process res),
   then generates the world. It first puts up a full-screen `LoadingScreen`
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

There are two opaque loading covers in the game — the **event / world-gen** one
(`world.gd._ready`, above) and the **HQ** one (`hq.gd._ready` →
`scripts/loading_screen.gd`). **Anything expensive that can be done up front should be
done behind whichever cover is already up, rather than lazily on a button press or the
first frame it's needed** — especially work that would otherwise cause a visible lag spike
or stutter mid-interaction. The player already expects to wait at a loading screen; a beat
added there is invisible, whereas the same beat during play is a hitch.

Concretely, prefer moving into a loading screen: scene/prop instantiation for things the
player will reach soon (e.g. the Free Roam catalogue pre-warm — `hq.gd`, kept in memory,
see [menus.md](menus.md); it is the one case where the cover was the *wrong* place —
it dominated boot, so it now trickles in one prop per frame just AFTER the cover lifts via
`_prewarm_free_roam_deferred`), mesh /
material / texture duplication, shader pre-warm compiles (see
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

It generalises five hand-rolled instances, each previously invented under its
own private name with no shared vocabulary: `hq.gd::_settle_generation`
(car-park prop spawning), `hq.gd::_challenge_refresh_generation` (challenge
overlay board queries), `settings_menu.gd::_sl_gen` (seed-lab preview — this
one also threads an `abort: Callable` closure into `TrackGenerator.generate`),
`standings.gd::_reveal_gen`, and `podium.gd::_reveal_gen` (leaderboard reveal
coroutines). None of these five have been migrated onto `StaleGuard` yet —
the class exists as the shared home for the idiom; adopting it at each call
site is separate follow-up work.

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
