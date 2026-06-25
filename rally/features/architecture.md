# Architecture & Project Layout

## Directory layout

```
rally/
├── main.tscn              # Entry-point scene (set in project.godot)
├── car.tscn               # VehicleBody3D car, instanced into main.tscn
├── project.godot          # Engine config: autoloads, input map, rendering
├── run_tests.sh           # Test runner (headless + visual passes)
├── config/
│   └── game_config.tres   # GameConfig resource — all tuning values
├── scripts/               # All GDScript (see file map below)
├── shaders/               # ps1_models.gdshader, ps1_post_process.gdshader
├── textures/              # checker.png
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
├── PostProcess [CanvasLayer]
│   └── ColorRect                   shader: ps1_post_process.gdshader (dither)
└── HUD [CanvasLayer]               script: hud.gd, layer 2
    ├── SpeedLabel / GearLabel / RPMLabel
    └── ModeButton / DriveButton
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
  into `Config.data` (a `GameConfig`). Read-only at runtime; every gameplay
  system reads from it. See [configuration.md](configuration.md).
- **`Save`** → `scripts/save_manager.gd`. Loads the player profile (owned cars,
  HP, inventory, rally completion) from `user://profile.json` at boot and
  autosaves on every meaningful change. Per-player *mutable progress*, kept
  distinct from `Config`'s authored baseline. See
  [save-persistence.md](save-persistence.md).

## Data flow

1. `Config` autoload loads `game_config.tres` before any scene runs.
2. `world.gd._ready()` pushes config values into scene-owned resources
   (environment fog/color, terrain layers, material colors, post-process res),
   then generates the world. It first puts up a full-screen `LoadingScreen`
   (`scripts/loading_screen.gd`, created in code) and advances its step label
   across generation stages (track → terrain → trees → bushes), yielding a
   frame between each so the message paints before the blocking work. Godot's
   boot bar only covers engine + `.pck` load; this overlay covers the heavy
   world-gen that runs afterwards. Under headless the per-step `await`s are
   no-ops, so generation stays synchronous (tests see a fully-built world right
   after instantiating `main.tscn`). The overlay is freed once the world is up.
3. Per-system scripts (`car.gd`, `drivetrain.gd`, `engine.gd`, `chase_camera.gd`,
   `terrain_manager.gd`, `hud.gd`, `engine_audio.gd`) read `Config.data` directly for
   their own tunables.
4. Gameplay loop runs in `_physics_process` (car/drivetrain/engine/camera) and
   `_process` (HUD, audio buffering).

## Key conventions

- **Config-first:** never hardcode tuning in scripts/scenes; add a `GameConfig`
  field and read it. Literals in scenes/scripts are fallback only.
- **Custom tire physics:** Godot's built-in `VehicleWheel3D` friction is disabled
  (friction slip set to 0); all contact forces come from `drivetrain.gd`.
