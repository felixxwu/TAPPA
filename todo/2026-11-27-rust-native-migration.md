# Leave Godot: one Rust + wgpu codebase for web, Android, iOS and desktop

**Status:** planned 2026-11-27, not started. See "Progress" below for what's done. The decisions are recorded in "Settled decisions" and at
the bottom. Phases 0 and 1 start only when the migration does.

**Goal:** replace Godot with a thin engine of our own, in Rust on wgpu, running natively
(Vulkan / Metal / DX12) and on the web (WebAssembly + WebGPU) from one codebase. Targets: web,
Android, Windows and **iOS** (new; there is no iOS build today, and the Apple Developer Program
membership is in place). Speed is the reason: the web build is draw-call bound (`CLAUDE.md` → "Draw
calls"), GDScript is slow at tight numeric loops, and Godot gives us no path to the GPU deciding what to
draw itself.

## Progress

**How to mark progress.** When a step is done and its tests pass, tick its box in the commit that
finishes the step, with the date: `- [x] 0.1 Web build on Cloudflare Pages (2026-12-03)`. That commit is then what
`git blame` shows for the line, so no hash is needed. Tick a phase's **Exit** box only when every step above it is
ticked and the exit check in that phase's section passes. A step that's started but not finished stays
unticked, with `(in progress)` after it. Never delete a ticked step or the text under it: the spec
stays the record of how each step was done. The `CLAUDE.md` rule to ask before removing completed
spec items still applies.

**Prerequisite**
- [x] The Hafren-only cleanup is finished (2026-11-28; spec deleted, see git history)

**Phase 0 — Godot feature set**
- [ ] 0.1 Web build on Cloudflare Pages
- [x] 0.2 Remove Google and password sign-in (2026-11-28)
- [ ] 0.3 Email link sign-in
- [ ] 0.4 Account deletion
- [ ] 0.5 Cloud tests against the Firebase emulators
- [ ] 0.6 iOS export
- [ ] **Exit:** live on the App Store and Cloudflare Pages; sign-in and deletion work everywhere

**Phase 1 — Yardsticks**
- [ ] 1.1 Deterministic replays
- [ ] 1.2 Car step golden
- [ ] 1.3 Car drift report
- [ ] 1.4 Game-state trace
- [ ] 1.5 Menu-flow, layout and touch replays
- [ ] 1.6 Scene counts
- [ ] 1.7 Save round-trip
- [ ] 1.8 Device targets
- [ ] 1.9 Re-bless rule for Godot changes during Phases 1–3
- [ ] 1.10 Parity checklist written
- [ ] **Exit:** every golden in CI and blessed; numbers recorded for every device class

**Phase 2 — Neutral data format**
- [ ] 2.1 Level bake in a neutral binary
- [ ] 2.2 Publish and fetch it like the current bake
- [ ] 2.3 Every other imported asset, plus the built level geometry
- [ ] **Exit:** Rust loads every asset; checksums and decoded data match Godot

**Phase 3 — Renderer, build spike, go/no-go**
- [ ] 3.1 Viewer draws what the Godot frame draws
- [ ] 3.2 Build spike (Jolt binding, WebAssembly, threads, determinism)
- [ ] 3.3 Runs on every browser and native target
- [ ] 3.4 Rust replay benchmark
- [ ] 3.5 Like-for-like comparison
- [ ] 3.6 Check the Architecture's assumptions
- [ ] **Gate:** build spike works and at least 2× headroom on phone web (go / no-go, with your call)

**Phase 4 — Simulation core in Rust**
- [ ] 4.1 Engine audio synthesis
- [ ] 4.2 Terrain chunk building and level decode
- [ ] 4.3 Engine and drivetrain
- [ ] 4.4 The car
- [ ] **Exit:** every crate matches Godot's recorded output; the car passes the car step golden

**Phase 5 — The new shell**
- [ ] 5.1 Game loop, input, cameras, streaming
- [ ] 5.2 Physics world
- [ ] 5.3 Replay benchmark running the whole game
- [ ] 5.4 HUD, minimap and map
- [ ] 5.5 Menus
- [ ] 5.6 Save and cloud, with links that open the app
- [ ] 5.7 Input actions and bindings
- [ ] 5.8 Everything else
- [ ] **Exit:** every comparison matches Godot; frame-time targets met; visual review signed off; parity checklist done

**Phase 6 — Platforms and switch-over**
- [ ] 6.1 CI builds for every platform
- [ ] 6.2 iOS release
- [ ] 6.3 Tool ports
- [ ] 6.4 Asset importer
- [ ] 6.5 Device checklist
- [ ] 6.6 Switch over and delete Godot

## What the speed gain comes from (measured 2026-11-27)

A throwaway spike (`spikes/webgpu/index.html`, on an Apple M5 Pro in Chrome) drew Hafren's real terrain
and 183k real tree positions three ways, against a full Hafren replay of the current web build:

| | Main-thread CPU per frame, avg / p95 |
|---|---|
| Godot web build, whole frame (`busy_ms`) | 8.21 / 11.62 ms (p99 19.07) |
| Godot web build, draw phase only (`draw_phase`) | 3.25 / 3.93 ms, ~420 draws |
| Spike, WebGL2, one draw per object, ~1000 draws | 0.89 / 1.2 ms |
| Spike, WebGPU, one draw per object, ~1000 draws | 1.27 / 1.6 ms |
| Spike, WebGPU, GPU culling + indirect draws, 250–3000 draw-equivalents | 0.26 / 0.4 ms, flat |

What it means for the plan:

- **WebGPU by itself is not faster.** Drawing one object per call, it was 1.3–1.5× slower than WebGL2
  on CPU. The gain comes only from the GPU culling and issuing its own draws, which WebGPU allows and
  WebGL2 doesn't. That design is mandatory, not an optimisation.
- **Godot's draw phase costs ~7.7 µs per draw, against ~0.6 µs for a raw WebGL call.** Most of it is
  Godot's own renderer work in WebAssembly. The GPU-driven renderer removes nearly all of the ~3.25 ms.
- **The other ~5 ms of the frame is scripts and physics, and the p99 spikes are streaming.** The
  renderer doesn't touch those. Only the Rust port of the game code (Phases 4–5) and streaming on
  worker threads do, so the payoff on web depends on them as much as on the renderer.
- **This was one fast Mac.** The case should be stronger on phone CPUs. The Phase 3 gate measures there.

A second spike (`spikes/rust_port/`) ported two hot paths line for line and checked the output matched
GDScript's. It used C as a stand-in for Rust, since Rust isn't installed (same LLVM backend):

| Hot path, ms per call | GDScript, web build | Ported, WebAssembly | Speedup |
|---|---|---|---|
| Near terrain tile build | 2.68 | 0.012 | ~220× |
| Mid terrain chunk build | 2.38 | 0.009 | ~260× |
| Engine audio, 1 s of samples | 22.96 | 0.45 | ~50× |

- **Pure maths becomes effectively free.** But both of these already run off the main thread on web
  (chunk builds on worker threads, audio on the audio feed thread), so porting them saves worker CPU
  and makes tiles arrive sooner, not main-thread frame time.
- **The streaming spikes are mostly not script time.** In the 19–31 ms frames, tracked scripts add up
  to 4–8 ms; the other 10–17 ms is untracked, probably Godot creating meshes, collision shapes and
  nodes. In our own engine that's a buffer upload and a Jolt shape, under our control, but nothing has
  measured it yet. Phase 3 step 6 attributes it.
- **Of the ~5 ms of non-draw main-thread time**, maths-heavy scripts should become nearly free, while
  scripts that mostly call the engine gain less. A rough guess is a 2.5–3.5 ms saving; splitting the
  `scripts_ms` keys into maths and engine calls would pin it down.

## Prerequisite: the Hafren-only cleanup

The Hafren-only cleanup (done 2026-11-28; spec in git history) ran first, in Godot. It deletes the legacy procedural
island, the `main.tscn` dev stage, the island benchmark, the first-run intro and outlines, makes
`LevelStreamer` stand on its own, and moves the car-physics tests onto a flat-ground fixture. After it,
everything left in the repo is the game being ported, so this plan has no "not ported" list.

## The parity contract

The Rust version must be a replacement players can't tell apart from the Godot version, except that it's
faster. Every phase is judged against this table. A difference that isn't allowed here is a bug in the
Rust version, never a reason to bless a new golden.

| Category | Must match | Checked by |
|---|---|---|
| Car physics and drivetrain, one tick at a time | Within a small float tolerance (wider on ticks with contacts) | Car step golden (hard gate) |
| Car physics over seconds of free driving | Close, within a tolerance that widens over time; whole-run figures match | Car drift report (reviewed, not a gate) |
| Game events: money, loot drops, purchases, rally starts, finishes and times, weather changes, discoveries | Exactly, on the same tick | Game-state trace |
| Damage (HP) and temperatures | Within a stated tolerance; events derived from them stay exact (see below) | Game-state trace |
| Save files and cloud data | Same values, same JSON schema | Save round-trip tests |
| Menu flow: which page, which item focused, what each button does | Exactly | Menu-flow replays |
| What's in the world: trees, buildings, fences, spectators, log piles, by type and position | Same items, positions within 1 cm | Scene counts |
| Engine sound | Within a tolerance on the samples | Audio synth comparison |
| Sound effects | Same sounds triggered on the same ticks | Game-state trace (sound events) |
| Visuals | Reviewed by eye, loose perceptual diff | Side-by-side visual review |
| Performance, load time | Allowed to differ, and expected to be better | Device targets (Phase 1) |

Why car physics has two rows: a car on gravel is chaotic, so two physics engines driven by the same
inputs drift apart within seconds even when both are correct. Comparing one tick at a time, starting
each tick from the same state, can't drift, so that is the gate. The game-state trace runs with the car
fed its recorded poses (as `level_replay.gd` already does), so events tied to the car's position, such
as rally times, land on the same tick in both versions. Damage and temperature still come from the
physics (contact impulses, RPM), so they get a tolerance. Events derived from them (repair costs,
breakdowns, overheating, broken parts) would then flip near a threshold, so when the Rust version runs
the trace, it takes HP and temperatures from the Godot log at each tick and compares its own values
separately. That keeps everything downstream of them exact.

Rules for keeping the two versions comparable:

- **The parity checklist.** One row per feature file in `features/` (73 today, plus `README.md`). Each
  row names its parity test or a written reason the feature may differ. Switch-over requires every
  row to be done.
- **Allowed differences so far:** on iOS and the Play Store Android build, the Rust version opens the
  sign-in email link straight in the app; the Godot version has the player paste a code (Phase 0.3).
- **The Godot version is frozen for new features from Phase 4 onwards.** Bug fixes still land in Godot,
  and in Rust in the same piece of work, with a trace or golden covering the fix. A new feature waits
  until after switch-over, or is built in both versions at once.
- **A difference found in Godot during the port is fixed in Godot first.** If the Rust port turns up
  a Godot bug, fix it in Godot, re-bless the Godot goldens with the user's go-ahead, and then match
  it in Rust. The two versions never knowingly differ.

### Numeric parity

"Exactly" for game state and the world only holds if the Rust version computes the same numbers:

- Port Godot's random number generator exactly (PCG32, its `randf` / `randi_range` conversions and
  seeding), and call it in the same order.
- Port Godot's `Variant` hash for each type the callers pass. It differs by type: ints use
  `hash_one_uint64`, floats murmur3 of the double, Strings a djb2-style hash, Arrays combine their
  elements' hashes with murmur3. World placement depends on it: `scatter_math.gd` → `hash01` is
  `hash([cx, cz, seed_value, salt])`, and other callers include `level_rallies.gd`, `level_view.gd`
  (cargo pick) and `exhaust_flames.gd`.
- Mirror Godot's number types: GDScript `float` is 64-bit, but `Vector3` and `Transform3D` are 32-bit.
- Use the `libm` crate for maths functions everywhere, so native and WebAssembly agree with each other.
  That doesn't make them agree with the system maths library Godot used on the CI runner, so
  "exactly" comparisons get a 1-ulp tolerance unless the path only uses correctly rounded operations
  (`sqrt`, `+`, `−`, `×`, `÷`).
- Bless and check the Godot goldens on the same CI runner image, and record the platform in each
  golden. Godot's Jolt may not be built for cross-platform determinism, so a Mac and a Linux runner
  can produce different results.

## Settled decisions

- **One codebase, not separate web and native builds.** Rust is the fastest practical language on both
  targets, and wgpu covers every graphics API we need.
- **WebGPU only, no WebGL2 fallback** (confirmed 2026-11-27: players without WebGPU are simply not
  served). Every platform gets the same feature level: compute shaders and indirect draws. The renderer
  has one path, designed to WebGPU's default limits. The same decision applies to Android: phones
  without Vulkan 1.1 aren't supported, because wgpu's OpenGL ES backend has WebGL2's limits.
- **The renderer is GPU-driven from the start.** The spike showed WebGPU is only faster when the GPU
  culls and issues its own draws (see "What the speed gain comes from").
- **Unsupported devices are turned away clearly.** At boot, check `navigator.gpu` / `requestAdapter()`
  on web or adapter creation on native, and show a plain "this device isn't supported" page rather
  than a blank screen.
- **Our own thin engine, not Bevy.** We'd fight Bevy's renderer to get the GPU deciding what to draw,
  and its API changes every release.
- **Sign-in is by email link only** (2026-11-27). No Google, no email + password, so no Sign in with
  Apple: App Store guideline 4.8 only applies to third-party logins.
- **The web build moves to Cloudflare Pages** (2026-11-27): free, with no bandwidth cap, unlike
  Firebase Hosting's free plan (about 360 MB a day, a few dozen game loads). Firebase stays on its free
  plan for sign-in and Firestore. Only the web build leaves itch: the
  Android APK and Windows `.exe` stay there, and `UpdateCheck.ITCH_URL` still sends native players
  there. Cloudflare Pages rejects files over 25 MiB, so the large files live in R2 (see Phase 0.1).
- **iPhone version is free, with no real-money purchases** (2026-11-27), so no Paid Apps Agreement or
  in-app purchase work.
- **No local save import.** Nobody plays yet, so saves carry over between the versions only through
  cloud sync. The Rust version doesn't read Godot's local `user://` files (IndexedDB on web, the app
  container on iOS and Android). It still keeps the same app IDs, signing keys and rising version
  numbers, so it installs as an update over the Godot build.

## Stack

| Concern | Pick | Notes |
|---|---|---|
| Language | Rust | WebAssembly with SIMD on web; `cargo test` replaces GUT |
| GPU | wgpu, WGSL shaders | The GPU culls and picks LODs in compute shaders and fills indirect draw buffers. WebGPU core has no multi-draw indirect (wgpu turns it into one indirect draw per batch), no bindless textures (keep the shared atlas and texture-array approach), and a non-zero `firstInstance` in indirect draws needs the optional `indirect-first-instance` feature, so the culling pass hands instance offsets over in a storage buffer instead. wgpu's WebGPU objects can't be used from worker threads on web, so drawing stays on the main thread |
| Physics | Jolt through Rust bindings | Rigid bodies and collision. Pin the same Jolt commit and solver settings Godot ships (Godot pins Jolt by commit in `thirdparty/`); see "The car" below. Jolt's cross-platform determinism option makes the Rust version match itself on native and WebAssembly. Check whether Godot builds Jolt with it (`JPH_CROSS_PLATFORM_DETERMINISTIC`); if not, turning it on changes the float results slightly, and the car tolerances have to absorb that. Jolt is C++. wgpu's WebGPU backend needs the `wasm32-unknown-unknown` target with wasm-bindgen, so Jolt is built with clang and the wasi-sdk sysroot (libc++) and linked into it, compiled with `-matomics -mbulk-memory` (the wasi-sdk threads sysroot) so it links into a shared-memory module. Jolt runs single-threaded (`JobSystemSingleThreaded`): it simulates one car, and its determinism doesn't depend on thread count. The Phase 3 build spike proves this |
| Window and input | winit; gilrs for gamepads on desktop and web | gilrs doesn't cover iOS or Android: there, gamepads come from Apple's GameController framework and Android's input events through android-activity, behind one input layer. Touch controls are ported from `features/mobile-controls.md`. Tilt steering (`tilt_input.gd`) needs CoreMotion on iOS, Android's sensors, and `deviceorientation` on web (with iOS Safari's permission request on a tap) |
| Audio | cpal natively (CoreAudio on iOS), an AudioWorklet on web | `engine_audio_synth.gd` moves onto the audio thread. Also: music (`MusicDirector`), sound effects (`Audio`), decoding the `.ogg` files, and the bus volumes (`audio_buses.gd`). On iOS, set the audio session category so the game respects the silent switch as players expect |
| UI | Small custom page-based UI | Same rules as today: Jersey 10 at multiples of 18 px, whole-pixel positions, every page navigable by keyboard and gamepad |
| Tuning | `GameConfig` → one TOML file embedded in the build (`include_str!`), optionally reloaded while the game runs | `scripts/game_config.gd` (~3.4k lines of defaults) becomes a struct read from that file; the defaults live only in the TOML, not also in the struct. It also needs get and set by field name, because upgrades write config fields by name (`upgrade_library.gd` → `cfg.set(field, value)`, `Config.authored_value`); generate a field table with a derive macro |
| Web threads | WebAssembly threads (SharedArrayBuffer) | The web export already uses threads (`variant/thread_support=true`). From Phase 0 the COOP/COEP headers come from Cloudflare Pages' `_headers` file. Rust WebAssembly threads currently need nightly Rust and `-Z build-std`; the Phase 3 build spike proves it. Rust workers on web are Web Workers, through a `wasm_thread` or `wasm-bindgen-rayon` style crate (`std::thread::spawn` doesn't work on `wasm32-unknown-unknown`) |

### The car is not just Jolt

`scripts/car.gd` extends Godot's `VehicleBody3D`. Its wheels, suspension and tyre friction are Godot's
own raycast-vehicle code (`scene/3d/physics/vehicle_body_3d.cpp`, MIT-licensed, derived from Bullet),
with our forces layered on top (`apply_force` / `apply_central_force` for drag, rolling resistance,
water, downforce, wind). Godot's Jolt layer also shapes every tick: how it damps bodies, applies
gravity, works out mass, inertia and centre of mass from shapes, its solver settings (the project's
`jolt_physics_3d/*` settings plus Godot's defaults) and the Jolt version it bundles. The car's damage
reads per-contact impulses in `_integrate_forces`, so those must match too. All of this has to be
ported exactly, in its update order, and checked against recordings (Phase 4).

### What Godot draws that we don't write

The renderer has to reproduce these project settings and built-in behaviours, not just our shaders:

- `shading/overrides/force_vertex_shading=true`: every built-in material is lit per vertex.
- `[shader_globals]`: the headlight uniforms (`hl_*`, `fl_*`), `world_light` and wind.
- The anamorphic stretch: `DisplayStretch` sets the content scale aspect to ignore and drives
  `content_scale_size` itself, so the whole frame, UI included, is stretched horizontally by
  `Config.data.horizontal_stretch`.
- `limits/opengl/max_lights_per_object=4`.
- Built-in materials, fog, shadows, the sky, and mesh LODs.
- Our own shaders: the `.gdshader` files left after the cleanup (`benchmark/vtf_probe.gdshader` isn't
  shipped), the `.gdshaderinc` includes left, and one shader `ground_cover.gd` builds inline.

## Architecture

The shape of the Rust codebase. It's a design, not code: Phase 3 builds the renderer half of it,
Phase 4 the simulation crates, Phase 5 the rest. Where there's a real choice, the options are listed
with a recommendation; the settled decisions are listed at the end of the section.

The guiding rule is the same one the plan already follows: the simplest thing that keeps parity and
the speed gain. Today's game is one level, one player car and a few thousand repeated things (trees,
spectators, particles) that are already drawn as arrays. The design doesn't need a general engine.

### Crates

One Cargo workspace. Each crate is a folder under `crates/`:

| Crate | What it holds | GPU / window? |
|---|---|---|
| `gdcompat` | Godot-compatible numbers: the PCG32 generator and its `randf` / `randi_range` conversions, the `Variant` hash per type, 32-bit `Vector3` / `Basis` / `Transform3D`, `libm` wrappers | No |
| `config` | `GameConfig` read from TOML, the live and authored copies, the by-name field table | No |
| `config_derive` | The derive macro that generates the field table (Rust needs macros in their own crate) | No |
| `assets` | Readers for Phase 2's neutral formats: the level bake, `hafren_5km.json`, `.buildings.bin`, meshes, textures, fonts, the UI theme. Produces plain CPU data (`Vec`s of bytes and structs) | No |
| `level` | `LevelData`: the road graph and routes, teleports, shops, deliveries, rallies, and the placement lists (trees, buildings, fences, spectators, log piles) | No |
| `terrain` | Chunk building as pure functions (`_compute_heights`, `_compute_arrays`, stitching, skirts), heightfields for collision, and the streaming planner (which chunks and tiles are wanted, in what order) | No |
| `engine_sim` | `engine.gd` and `drivetrain.gd`: torque, gearbox, clutch, turbo, nitrous | No |
| `synth` | `engine_audio_synth.gd`, music scheduling maths. Sample generation only, no audio device | No |
| `physics` | The Jolt binding (a `-sys` module over the C++), Godot's `VehicleBody3D` wheel model, `car.gd`'s forces, `DamageModel` (`damage_model.gd`) and the contact impulses it reads | No |
| `ui` | The page UI toolkit: layout, widgets, focus and `MenuNav`'s rules, text measurement from the font's metrics. Produces a list of quads, not pixels | No |
| `game` | The whole game: state, systems, events, the profile and its JSON, cloud sync logic, every menu page, the input action map, replays and snapshots | No |
| `parity` | The golden runners and the `bless` command (see "Where the parity harness hooks in") | No |
| `render` | The wgpu renderer | Yes |
| `platform` | Everything that differs per platform: window and events (winit), gamepads, touch, tilt, audio output (cpal / AudioWorklet), file storage, HTTP, threads, text input and clipboard (a hidden DOM input on web; the native soft keyboard and clipboard on iOS and Android), app lifecycle (pause, tab hidden) | Yes |
| `app` | The program itself: wires `game`, `render` and `platform` together, runs the frame loop, the replay benchmark. Builds as the native binary, the WebAssembly module, and the iOS / Android library | Yes |

Each crate depends only on rows above it. `render` is narrower still: it depends only on `gdcompat`
and `assets` (it never sees game state). `app` depends on everything. So:

- `cargo test` on every crate above `render` (that includes `parity`) runs headless, with no GPU, no window and no audio device.
  The car step golden, game-state trace, menu-flow replays, scene counts and save round-trip all live
  there.
- A CI check fails if `cargo tree -p game` or `cargo tree -p parity` (or any crate above them) pulls in `wgpu`, `winit`, `cpal` or
  `web-sys`, so the line can't erode quietly.
- `platform` is the only crate with `#[cfg(target_arch = "wasm32")]` or per-OS code, apart from small
  build tweaks. The game never asks which platform it's on except through the same "is this a touch
  device" style questions `Platform` answers today.

Fifteen crates sounds like a lot. Most are a few files; the split exists so the slow-to-build and
platform-specific parts stay apart, and the dependency check keeps wgpu, winit and cpal out of the test builds. Option: merge `level`,
`terrain`, `engine_sim` and `synth` into `game` and keep only `gdcompat`, `config`, `physics`, `ui`,
`game`, `render`, `platform`, `app`. Recommendation: keep them separate, because Phase 4 ports and checks
each of them on its own against Godot's recordings, and a crate per piece makes "this piece is done"
mean something.

### Game objects without a scene tree

**Plain structs and systems, not an ECS.** `game` has one `Game` struct that owns everything: the
config, the profile, the level, the streamer's state, the Jolt world, the car (with its engine,
drivetrain and damage model), the spectator groups, log piles, felled trees, particle pools, weather,
the active delivery, money, and the open menu pages. A "system" is a plain function or method that
takes the parts it needs, called in a fixed order from `Game::tick`.

Why not an ECS (`hecs`, `bevy_ecs`): there are few kinds of thing, most exist once, and the repeated
ones are already arrays today (`LevelTrees` tiles, `CpuParticlePool`, spectator groups). An ECS buys
flexible queries we don't need, and costs a fixed system order that's harder to see. The order matters
for parity: Godot runs `_physics_process` in scene-tree order, and the game-state trace needs events on
the same tick in the same order. An explicit list of calls in `Game::tick` is that order, written down.

How today's pieces map:

| Today | In Rust |
|---|---|
| A node with `_physics_process` (`car.gd`, `LevelView._timed_physics_process`, `heal_at_points`, `RoadRecovery`) | A system called from `Game::tick`, in the order Phase 1's audit records |
| A node with `_process` that changes game state | Already moved onto the tick by Phase 1.1, so it's a tick system too |
| A node with `_process` that only presents (labels, `_place_nav_beam`, `_place_money`, cameras, particles' look, `TeleportBeacons._place`) | Part of `present`, which reads the game and never writes game state |
| A signal (`DamageModel.damaged`, `gave_up`, `Save.flushing`, `PauseMenu.closed`) | A direct call where one listener reacts at once; otherwise a `GameEvent` pushed onto the tick's event list, which later systems read. The same list feeds the game-state trace |
| `get_tree().paused = true` while a menu is up | `Game.paused`: the tick stops, `present` and the UI keep running (as `PROCESS_MODE_ALWAYS` nodes and `process_frame` hooks such as the shop orbit camera do today) |
| A `.tscn` | Code that builds the struct, as the plan already says |
| Node paths, groups (`LevelView.GROUP`, `MODAL_GROUP`) | Fields on `Game`; a group with one member is just that field |

The autoloads:

| Autoload | Becomes |
|---|---|
| `Config` | `Config { live, authored }`, owned by `Game` and passed by reference. Not a global: tests build their own, which replaces `Config.reset()` |
| `Save` | `Profile` (the `profile.json` data) in `game`, written through `platform`'s storage. `Save.flushing` becomes the platform's lifecycle event (window close, app paused, tab hidden) |
| `Cloud` | `game::cloud`: sign-in and sync as a state machine, sending requests through `platform`'s HTTP and handling the replies as events at the next tick boundary |
| `InputRemap` | The binding tables in `game`'s input map (see "Input") |
| `WorldSession` | Its live parts (the `level_*` settings the level uses) are fields of `Profile`. Its island-only parts aren't ported |
| `Benchmark` | Whatever the cleanup leaves of it (it strips the island benchmark). The level's replay benchmark lives in `app` |
| `DisplayStretch` | The renderer's final-frame transform and the UI's logical size (see "Renderer") |
| `WebFullscreen` | `platform` on web |
| `PerfLog` | `app::perf`: named scoped timers with the same keys the `scripts_ms` report uses, so reports can be compared |
| `Music`, `Audio` | Commands to the audio thread (see "Threads") |
| `CarPreviewCache` | The renderer drawing car previews into small textures, cached by car id |

### Frame and tick

- **The tick is fixed at 60 Hz**, Godot's default (`project.godot` doesn't set
  `physics_ticks_per_second`). Each frame adds the real time passed to an accumulator and runs whole
  ticks, at most 8 per frame like Godot's default `max_physics_steps_per_frame`, dropping the rest so a
  long stall doesn't spiral.
- **Each frame:** read platform events into the input state, run the ticks, apply finished streaming
  work, then `present` (cameras, labels, particles' look, the UI) and draw.
- **No interpolation between ticks**, because Godot's physics interpolation is off today and things
  would look different with it. It's easy to add later as an allowed difference.
- **The tick sees no wall clock.** Sim crates get `dt` and the tick number only. A lint (Clippy's
  `disallowed_methods` on `Instant::now`, `SystemTime::now` and the like) fails the build if they call
  one. Wall-clock things (the frame sampler for adaptive graphics, `updated_utc` in the save, perf
  timers) live in `app` or are passed in.
- **Randomness comes from named streams.** `game` holds one game seed; each system asks for its stream
  by name (and object id where there are many), as Phase 1.1 sets up in Godot, using `gdcompat`'s
  PCG32 so the numbers match. There's no global generator to call by mistake.
- **No iteration over a `HashMap` where order matters.** Rust's standard `HashMap` iterates in a random
  order on every run. Use `BTreeMap`, an index-ordered map, or a sorted `Vec` wherever the order reaches
  game state or a trace. A Godot `Dictionary` keeps insertion order, so an index-ordered map is the
  faithful port of most of them.
- **Streaming lands on tick boundaries.** Finished worker results are applied between ticks, never in
  the middle of one. In normal play, which tick a chunk arrives on depends on machine speed, as in
  Godot today. In **replay mode**, the tick waits until everything the planner wants is in (Phase 1.1
  asks the same of Godot), so goldens are deterministic. Waiting is only possible natively and
  headless: the web main thread can't block. So goldens run native and headless; the web replay is a
  benchmark, not a golden.
- **Inputs per tick are one struct.** `TickInput` holds every action's state for the tick (throttle,
  steer, handbrake, shifts, nitrous, reset and the rest), sampled from the input state at the tick's
  start. A recording is a list of them, so "replay" means feeding recorded `TickInput`s instead of live
  ones.
- **Pose-fed replays** (as `level_replay.gd` → `_play_tick` does today) are one system that runs
  FIRST in `Game::tick`, before every other system and the physics step: `level_replay.gd` runs at
  `process_physics_priority` -100 and writes the pose, velocities and inputs at the start of the tick.
- **Snapshots.** The car, engine, drivetrain and damage model each have `snapshot()` and `restore()`,
  plus the world state the car changes (felled trees, spectator ragdolls). The snapshot struct is the
  one Phase 1.2 records from Godot, serialised the same way, so a Godot snapshot restores straight into
  Rust.

### Threads

| Thread | Runs | Talks to the main thread by |
|---|---|---|
| Main | Platform events, input, the tick (with Jolt), applying streaming results, `present`, the UI, all wgpu calls | — |
| Streaming workers, a small pool | Terrain chunk builds, tree tile packs, ground-cover placement, decoding textures and `.ogg` files at load | A job channel in; a results channel out, which the main thread drains with `try_recv` each frame |
| Audio | The engine synth, music, sound effects, mixing and bus volumes | A lock-free "latest value" slot for the engine's inputs; a lock-free ring buffer for one-shot commands (play this sound, start this track, set this bus volume) |
| HTTP (native only) | Firebase REST calls | A channel of replies. On web, `fetch` runs on the main thread's event loop and replies the same way |

**Why the tick stays on the main thread everywhere.** wgpu's WebGPU objects can't leave the main
thread on web, so rendering is there anyway. Moving the tick to its own thread natively would make
native and web behave differently and add a hand-off of game state every frame, for a sim that should
cost a millisecond or two in Rust. Option: a sim thread on native only, if a phone profile ever shows
the main thread is the limit. Recommendation: main thread, one design everywhere.

What crosses between threads, and the rules:

- **Read-only data is shared, not copied.** The level (`LevelData`, the bake's heights) is loaded once
  and shared with workers behind an `Arc`. Jobs carry just a chunk coordinate and its level of detail.
- **Results are plain bytes and structs.** A finished chunk comes back as its heights (for collision),
  its vertex bytes (for the GPU) and its placement lists. The main thread hands the heights to the Jolt
  world and the vertex bytes to the renderer, then drops them. Headless tests skip building vertex bytes.
- **Nothing on the audio thread waits or allocates.** The callback (cpal natively, the AudioWorklet on
  web) only reads the latest engine inputs, drains the command ring, and fills samples. Decoded sounds
  are handed over as shared, immutable sample buffers. This replaces `EngineAudioFeed`'s mutex and
  sequence counters; one-shot cues (blow-off, nitrous trigger) become ring-buffer commands, so each
  fires exactly once.
- **The main thread never waits on a lock.** On web the main thread can't block (`Atomics.wait` is
  refused there), and a contended lock in WebAssembly spins. Channels with `try_recv` and single-writer
  slots avoid the question.

Web constraints, all already in the plan's stack: WebAssembly threads need SharedArrayBuffer, so the
COOP/COEP headers from Cloudflare Pages; Rust's threads on web need nightly and `-Z build-std` (the
Phase 3 build spike proves it); workers can't touch the GPU, so all uploads happen on the main thread.
The AudioWorklet instantiates the same WebAssembly module on the shared memory, so the synth code is the
same Rust on every platform.

**The streaming spike cost.** The plan says the 10–17 ms of untracked time in Godot's streaming
frames is probably mesh, collision-shape and node creation. In this design the main thread does only
two things per chunk: a GPU buffer write and adding a Jolt body. Jolt's shape objects can be built on
any thread, so if Phase 3 measures shape creation as expensive, workers build the heightfield shape
and the main thread only adds the body. Both are spread across frames under a time budget, as
the streamer's scheduler does today, but the budget now covers only uploads and body adds, not
building.

### Renderer

**A fixed sequence of passes, written out by hand.** No render graph: the frame has a known shape.

1. **Uploads.** Write the frame's uniforms (camera, the `[shader_globals]` values: headlight `hl_*` /
   `fl_*`, `world_light`, wind), the instances that move every frame (the car, spectators, particles,
   beacons, dust), and any streaming results allowed this frame, all with `queue.write_buffer`.
2. **Cull.** One compute dispatch over every instance record. Each thread tests one instance against
   the camera frustum and its draw distance (the equivalent of today's `visibility_range_end`), picks
   its level of detail by screen size (Godot's `mesh_lod/lod_change/threshold_pixels=4.0` rule), and
   appends its index to its batch's slice of the visible list, bumping that batch's instance count in
   the indirect argument buffer.
3. **Main pass** at the low internal resolution. The panorama sky first (one full-screen triangle at
   the far plane), then one indirect draw per batch: opaque, then alpha-cut (trees, ground cover,
   cards), then water, then the few blended things (the nav beam, lamp flares), sorted on the CPU.
4. **Post-process.** `ps1_post_process.gdshader`'s dither and colour grade as one full-screen pass to the screen, with the horizontal stretch applied here.
5. **UI.** The page UI and HUD as one batch of textured quads, under the same stretch.

**Buffers.** Few, big and long-lived:

- **Vertex data in storage buffers, read by index in the vertex shader** ("vertex pulling"), one buffer
  per vertex layout (terrain, static mesh, card). With vertex pulling, all terrain chunks of one level
  of detail are one batch: every chunk at a level has the same vertex count and shares one index
  buffer (as the streamer's `_indices` already does), so the instance record just says which slot
  its vertices are in. Terrain slots are a fixed-size pool per level of detail, so streaming needs no
  general memory allocator.
- **Instance records** in one storage buffer: transform, which mesh, draw distance and level-of-detail
  ranges, and a custom value (tree species, tint). Static ones (trees, buildings, fences, log piles,
  terrain chunks) are written when they stream in and cleared when they stream out. 183k trees at 64
  bytes each is about 12 MB.
- **A mesh table**: per mesh and level of detail, its index range, vertex offset and bounds.
- **Indirect arguments**, one record per batch. A batch is one pipeline and one mesh (or one terrain
  level of detail). Batches, not objects, are what the CPU issues, so the main-thread cost is the
  number of batches: tens, against today's ~420 draws.

**Within WebGPU's default limits:**

- **No multi-draw indirect:** one `drawIndexedIndirect` per batch, which is why batches are kept few.
- **First instance:** every indirect record has `firstInstance = 0`. The vertex shader reads its
  instance as `visible[batch_base + instance_index]`, where `batch_base` comes from a small uniform
  bound with a dynamic offset per draw. That's the "first-instance via storage buffer" the stack row
  asks for.
- **No bindless:** textures stay in the shared atlas (`tools/levels/buildings_atlas.png`) and texture
  arrays (one layer per tree species, which also lifts today's six-species-per-draw limit from
  `LevelTrees.KINDS_PER_DRAW`). Texture arrays are capped at 256 layers and 16 sampled textures per
  shader stage.
- **Bind groups**, at most 4: frame (camera, globals), material (textures), scene (instances, visible
  list, vertex buffers), and the per-draw batch offset. That stays under the 8 storage buffers per
  shader stage.
- **Sizes:** storage bindings up to 128 MB and buffers up to 256 MB, so buffers are sized for Hafren
  with room to spare, and the Rust performance budget (see Testing) records their sizes.

**Streaming uploads land like this:** a worker's vertex bytes go into a free slot with
`queue.write_buffer`, then the chunk's instance record is written, which makes it visible to the next
cull. Streaming a chunk out clears its record and frees the slot. WebGPU orders writes before the next
submit, so there's no fencing to get wrong. A per-frame byte budget keeps a burst of chunks from
causing a spike.

**The rest of what Godot draws:**

- **Lighting per vertex** (`force_vertex_shading=true`), at most 4 lights per object, and fog, are
  written into our shaders. There's no general material system: each `.gdshader` left after the cleanup
  becomes a WGSL pipeline, and Godot's built-in materials the game uses become a few more. All
  pipelines are created at boot behind the loading screen, and warmed up by drawing each pipeline
  once offscreen, which replaces
  today's shader warm-up protocol (`warm_up_materials`, `LevelView._warm_up`).
- **Shadows:** the level has no shadow-casting light; the car's shadow is a blob (`CarShadow`). So no
  shadow map pass. Phase 3 confirms this against the Godot frame.
- **No outlines.** They're dropped from both versions (decided 2026-11-27; the Hafren-only cleanup
  removes them from Godot), so there's no ID pass and no second render target.
- **The anamorphic stretch:** the UI is laid out at the logical size (`DisplayStretch.logical_size()`),
  and the post-process and UI passes stretch the frame by `horizontal_stretch` when drawing to the
  screen.
- **The minimap and car previews** draw into small offscreen textures when they change (the minimap
  when the car has moved `level_minimap_redraw_move_m`, as now), then show as UI quads.
- **Draw counts for the benchmark.** The visible count per batch is copied back a frame late, which
  gives the report a per-batch breakdown like today's `draw_breakdown`.

### Config and tuning

- `config/game.toml` holds every default from `scripts/game_config.gd`, with flat field names exactly
  as today, because upgrades and `Config.authored_value` look fields up by those names. Groups become
  comments. It's generated once from `game_config.gd` by a script, then edited by hand.
- `GameConfig` is a struct whose every field must appear in the TOML (no `Default`, unknown fields
  refused), so the defaults live in one place, as the stack row asks.
- The derive macro generates `get(name)` and `set(name, value)` over a small value type (number,
  integer, bool, colour, vector, string), for `upgrade_library.gd`-style writes by name. An unknown name
  is an error in debug builds and a warning in release, as `Config.get_float` warns today.
- `Config` keeps two copies, `live` (which `apply_car` reshapes per car) and `authored`, as now.
- Reloading while the game runs: desktop dev builds watch the file; other builds use only the
  embedded copy.

### Save and cloud

- `Profile` mirrors `profile.json`'s schema. Fields with a fixed shape are typed; the settings map
  (`Save.set_setting` keys such as `level_car`, `level_money`, `level_parts`) stays a JSON map. Any key
  the Rust version doesn't know is kept and written back, so a Godot → Rust → Godot round trip can't
  drop data.
- **Key bindings are saved in Godot's numbering** (Godot key codes, joypad button and axis indices) and
  translated to winit and gamepad codes when loaded, using Phase 5.7's tables. That keeps the save's
  schema identical, which the parity contract requires.
- Storage is `platform`'s job: files in the app's data folder natively (written to a temporary file
  and renamed, so a crash can't leave half a save); on web, `localStorage`. The three files
  (`profile.json`, `auth.json`, `adaptive_graphics.json`) are small JSON, and `localStorage` is
  synchronous, which keeps the save path simple. Option: IndexedDB as Godot uses, which allows more
  data but is asynchronous. Recommendation: `localStorage`, with a size check in CI.
- `save_manager.gd` also writes `profile.json.bak` (the rolling backup) and
  `profile.json.conflict.bak` (`write_conflict_backup`, kept when a cloud conflict is resolved). Port
  both.
- Cloud sync is `cloud_sync.gd`, `auth_service.gd` and `firestore_codec.gd` ported as logic over a
  small HTTP interface, so tests can use a fake server.

### Input

Three layers:

1. **Devices** (`platform`): winit keys and mouse; gilrs gamepads on desktop and web; GameController
   on iOS; android-activity input events; touch; tilt. Each becomes a raw device event.
2. **Actions** (`game`): the `[input]` section of `project.godot` ported as a table of actions and
   their default bindings, overlaid by the player's saved bindings. Produces each action's state:
   held, pressed since the last tick, strength (with deadzones as configured). Press and release edges
   are latched until the next tick consumes them, like `is_action_just_pressed` in
   `_physics_process`, so a tap shorter than a tick isn't lost. Menus keep per-frame edges.
3. **Consumers:** the tick samples a `TickInput` from the action state; menus receive action presses
   (`ui_up`, `menu_back`, `ui_accept` and the rest).

The touch controls (`features/mobile-controls.md`) are UI widgets that set actions, so the tick never
knows a touch screen exists.

### UI

A small retained UI, built in code from data, as the menus already are (`CardUI.card_page` from a list
of entry dictionaries, `MenuPage`'s body box and action row):

- **Widgets:** labels, buttons, panels, rows and columns, the card carousel, sliders, text fields,
  scroll areas, icons. Layout is a simple measure-then-place pass in whole pixels.
- **Text:** Jersey 10 is a pixel font, drawn from a pre-rasterised 18 px glyph atlas. 36 and 54 px are
  the same glyphs scaled by exactly 2 and 3, nearest-neighbour, so there's no font rasteriser at
  runtime and no blurry sizes can exist. The font API only takes a multiple of 18. Phase 3 checks that
  Godot's 36 px Jersey 10 matches a 2× scale of its 18 px glyphs. The shop signs (`Label3D` today) use
  the same atlas on quads in the world.
- **Navigation:** `MenuNav`'s rules built in: focus lands on the first item (or `opts.first`), is
  re-grabbed when a page shows again, moves with WASD / arrows / D-pad / stick, Back routes to the
  page's handler, and one modal at a time blocks input underneath (`MODAL_GROUP`,
  `MenuNav.input_blocked`). Every page is keyboard and gamepad navigable by construction.
- **Which item focus moves to.** Godot picks the next focus by screen geometry. Options: (a) port
  Godot's neighbour search; (b) give each page an explicit order (lists move up and down, rows move left
  and right). Recommendation: (b), simpler and easier to predict. Menu-flow replays log the focused
  item after every press, so any page where it differs from Godot shows up as a failing replay, and
  that page gets an explicit neighbour to match.
- **Headless:** layout, focus and actions run without a GPU, so menu-flow replays run in `cargo test`.
  Drawing just turns the laid-out tree into quads for the renderer's UI batch.
- **Not egui or similar:** they don't do pixel-exact fonts at fixed sizes, and they don't follow the
  game's focus rules.

### Where the parity harness hooks in

| Golden | Runs in | Hooks into |
|---|---|---|
| Car step | `cargo test -p parity`, headless | `physics` and `engine_sim`: restore the recorded snapshot, apply the tick's `TickInput`, step once, compare. The Jolt world is built from Phase 2's level data, no renderer |
| Car drift report | `parity` command-line tool | The same, run freely for a few seconds from a snapshot; writes the path plot and figures |
| Game-state trace | `cargo test -p parity`, headless | `game` in replay mode with the pose-fed system on, the scripted actions as `TickInput`s, and a hook that takes HP and temperatures from the Godot log each tick. The tick's event list is the trace |
| Menu flow | `cargo test -p parity`, headless | `game` and `ui`: recorded presses go in as action presses; after each, log the page id, the focused label and the state the press changed |
| Scene counts | `cargo test -p parity`, headless | `game` after a teleport in replay mode (streaming finished): the placement lists, by type and position. No renderer: what's in the world is the game's data, not the GPU's |
| Save round-trip | `cargo test -p game` | `Profile` load and save, compared as parsed JSON with numbers normalised |
| Engine sound | `cargo test -p synth` | The synth fed the recorded inputs, samples compared within tolerance |
| Replay benchmark | `app`, on each device (`?replay=1` on web, `--replay` natively) | `app::perf`'s timers, the renderer's batch counts, the upload to `tools/bench_collector.py` |
| Pixels, visual review | `app` with a software GPU adapter, drawing offscreen | Pinned camera, time of day and seed; temporal effects off |

Golden files and the `bless` command live in `parity`. Ordinary runs only read goldens; `bless` is the
only thing that writes them.

### Architecture decisions (settled 2026-11-27)

1. The tick runs on the main thread on every platform.
2. No interpolation between ticks, as in Godot today: the car is drawn at its last tick's pose. Adding
   it later would be an allowed difference.
3. Web saves go in `localStorage`.
4. Each page lists its focus order explicitly, rather than porting Godot's geometric focus search.
5. Config reloads while running only in desktop dev builds.
6. The crate split above stays as it is.

## Phases

**Escalation rule.** When a comparison against Godot keeps failing after two real fix attempts (not the
same fix retried), stop and hand it to an Opus agent with the failing tick or event, the state diff, and
what was tried. This is expected for the car in Phase 4; physics mismatches are hard to localise.

Each phase has an exit check. A phase starts when the phases it depends on (see "Dependencies") have
passed their exits.

### Phase 0 — Bring the Godot game to the target feature set

**Driven by:** Sonnet. **Your steps:** Cloudflare Pages project and domain, Firebase Auth authorized domains, Apple signing and App Store review, Play Data safety form.

The Rust version should be a like-for-like replacement: same platforms, same accounts, same
behaviour. So the features that differ between today's game and the plan land in Godot first, and the
Rust port copies them. Every difference between the two versions found during the migration is then a
bug, not a feature gap. This phase runs before the goldens are recorded in Phase 1, so they're
recorded once.

1. **Move the web build to Cloudflare Pages.** Email links that open the game need a page whose URL the
   game can read. On itch.io the game runs inside a cross-origin iframe that never sees the page's
   URL, and `felixxwu.github.io/TAPPA` is a project page whose domain root belongs to another repo.
   - Serve the web build from Cloudflare Pages, with the COOP/COEP headers that WebAssembly threads
     need set in its `_headers` file.
   - Cloudflare Pages rejects files over 25 MiB per file, and `build/web/index.wasm` is 37 MB,
     `index.pck` 62 MB and the level bake 28 MB. Keep those large files in Cloudflare R2 and serve them
     through a Pages Function on the same origin, so COOP/COEP need no CORP or CORS changes. R2 egress
     is free, so there's still no bandwidth cost.
   - Set `Cache-Control` so players never load an old build: no caching on `index.html`, and
     build-unique or hashed file names for the rest. `update_check.gd` skips web because itch serves
     each build from a build-unique path (see `build_web.sh`); keep that true on Pages and update
     that comment.
   - Move the `export-web` deploy in `features/release-pipeline.md` from itch's `html5` channel to
     Cloudflare Pages, and repoint the `docs/index.html` redirect that the `deploy-pages` job
     publishes.
   - Add one sign-in landing page on Pages. Firebase's own email handler already redirects to the
     `continueUrl` with the code (`oobCode`) appended, so the email template's action URL stays as it
     is. The game sets `continueUrl` per platform when sending: on web, the game page itself; on
     phones and Windows, the landing page, which shows the code to paste (Phase 0.3).
   - Add the Pages domain to Firebase Auth's authorized domains, or `sendOobCode` fails with
     `UNAUTHORIZED_DOMAIN`.
2. **Remove Google sign-in and email + password.** Neither has been reachable since the Hafren
   rewrite. Delete:
   - `scripts/cloud/google_sign_in.gd` and `docs/oauth-callback.html`;
   - the Google paths in `auth_service.gd`, `cloud_manager.gd` (`google`, `sign_in_google`),
     `account_menu.gd` (the button, `_on_google_pressed`, `Cloud.google.cancel`) and
     `firebase_config.gd` (the OAuth client IDs and shipped secret);
   - email + password sign-in, registration and password reset (`auth_service.gd` and
     `cloud_manager.gd` → `sign_in_email`, `register_email`, `send_password_reset`);
   - their tests (`test_account_menu.gd`, `test_cloud_auth.gd`) and `features/cloud-save.md` entries.
3. **Add email link sign-in.** Use Firebase Auth's REST endpoints: `accounts:sendOobCode` with
   `requestType: EMAIL_SIGNIN`, `continueUrl` as set out in Phase 0.1,
   and `canHandleCodeInApp: true`; then `accounts:signInWithEmailLink`, which needs the email address as
   well as the code. Store the address when sending; if the link is opened on another device, ask for
   it again. Firestore sync (`cloud_sync.gd`) keeps working on the resulting account ID.
   - **Make the Account page reachable.** `settings_menu.gd` builds it (`_build_account_page`), but
     `_build_list_page` has no button for it, so no sign-in of any kind is reachable today. Add the
     entry, with a nav test.
   - **On web**, the link lands on the game page, which reads the code from the URL and then
     removes it (`history.replaceState`), so a reload doesn't retry a spent code.
   - **On phones and Windows**, the landing page shows the code for the player to paste into the game. Firebase's code (`oobCode`) is about 50 characters, so it's a
     paste, not something to type. Opening the link straight in the app would need native plugins in
     Godot that are thrown away at switch-over, so only the Rust version does that (Phase 5.6), as an
     allowed difference. Windows has nothing like app links, so it pastes in both versions.
   - **Update the privacy policy.** `docs/privacy-policy.html` (published by `deploy-pages`) says the
     game has no user accounts and makes no network requests to servers we control. Rewrite it to
     cover the email address, account ID, cloud save in Firestore and in-app deletion, keep its URL
     stable when Phase 0.1 changes what Pages serves, and update Google Play's Data safety form.
4. **Add account deletion.** App Store guideline 5.1.1(v) requires any app that lets players create an
   account to let them delete it in the app. Add "Delete account" to the Account page. The order
   matters, because `firestore.rules` only lets a signed-in player delete their own document, and
   `cloud_sync.gd` pushes on profile changes (`cloud_manager._after_sign_in` also pulls and pushes), so
   a cloud save could be re-created mid-delete and then be undeletable forever:
   1. Stop and turn off sync.
   2. Make sure the sign-in is recent enough for `accounts:delete` (Firebase refuses an old one with
      `CREDENTIAL_TOO_OLD_LOGIN_AGAIN`). If not, send a fresh link and have the player sign in again
      first, with sync still off.
   3. Delete the player's Firestore document.
   4. Call `accounts:delete`.
   5. Clear `auth.json`.

   Give it a nav test, and test that sync can't re-create the document and that signing in again
   during deletion doesn't push.
5. **Cloud tests against the Firebase emulators.** Run the sign-in, sync and deletion tests in CI
   against the Firebase Auth and Firestore emulators, not just fakes, so they exercise the real REST
   API and `firestore.rules`. Phase 5 runs the same scripted scenarios against the Rust version.
6. **Add an iOS export.** Godot's iOS export with `gl_compatibility` (OpenGL ES 3 on iOS) gets the
   game onto iPhones now. This step also sets up everything the Rust iOS build will reuse:
   - signing certificates, provisioning profile and the bundle ID;
   - macOS CI runners and the TestFlight upload;
   - the App Store listing, privacy details (cloud save collects an email address and an account ID),
     the privacy policy URL, the privacy manifest (`PrivacyInfo.xcprivacy`), export compliance
     (`ITSAppUsesNonExemptEncryption = false`, as the game only uses HTTPS) and age rating;
   - safe areas (notch, home indicator) in the HUD and menus;
   - turning off the update check on iOS. `UpdateCheck.applicable()` (`scripts/update_check.gd`) is
     true on any native build, so it would offer iPhone players a download from itch, which App Review
     rejects. Extend `test_update_check.gd`.

   Add a preset to `export_presets.cfg`, extend `tests/headless/test_export_presets.gd`, and
   document it in `features/release-pipeline.md`.

**Exit:** the Godot game is live on the App Store and on Cloudflare Pages. Signing in by email link and
deleting the account work on every platform. The native iPhone frame-time number is recorded.

### Phase 1 — Lock down the yardsticks (in Godot)

**Driven by:** Opus first (the determinism audit in 1.1 and the design of each recording), then Sonnet builds them. Before the exit, a fresh reviewer tries to break each recording on purpose: change something that should be caught, and check that it is. **Your steps:** record the drive by hand (1.2).

1. **Make the level deterministic under replay.** Today two replays of the same drive don't produce
   the same game: the car is fed recorded poses, but other systems still depend on frame timing,
   wall-clock time and unseeded randomness. Fix that first, for replays at least:
   - Give every system its own seeded random number stream instead of the global `randf` / `randi`.
     The global calls are in `damage_model.gd` (`nudge_wheels`),
     `level_weather.gd` (`seed_value = randi()`), `dust_puffs.gd`, `wheel_particles.gd`,
     `engine_smoke.gd`, `loading_tips.gd`, `music_library.gd` and `cloud/cloud_sync.gd`. Two more
     sources are generators that are never seeded: `engine.gd` calls `_rng.randomize()` unless
     `Benchmark.active` (recheck this once the cleanup has stripped the `Benchmark` autoload), and
     `exhaust_flames.gd`'s `_rng` is never seeded (in Godot 4 a new
     `RandomNumberGenerator` starts from a random seed). Spectators, log piles, ground cover and the
     engine synth already use seeded generators or hashes.
     - Each stream is a `RandomNumberGenerator` seeded from one game seed plus the system's name
       (and the object's ID where there are many, e.g. a spectator group). Then a new random call
       in one system doesn't shift every other system's numbers, which would break unrelated goldens.
     - Cosmetic randomness (dust, particles, audio) gets streams too: it's no extra work, and it
       keeps pixel and audio comparisons stable.
     - Add a test that fails if `scripts/` calls the global `randf`, `randi`,
       `randf_range`, `randi_range`, `randfn` or `randomize`, `Array.shuffle()` or `pick_random()`
       (which use the global generator), or creates a `RandomNumberGenerator` it never
       seeds, so new code can't bring them back.
   - Move game-state logic that runs per rendered frame onto the physics tick. Examples: the weather
     clock (`level_weather.gd` advances `drive_time` in `_process`), deliveries (`level_view.gd` →
     `_check_delivery` in `_timed_process`).
   - Leave wall-clock fields out of traces (`save_manager.gd` writes `updated_utc` from the system
     clock).
   - Make all streaming finish before each tick during replays. Several systems finish work to a time
     budget or on worker threads, so what exists at a given tick depends on the machine's speed:
     terrain chunks (`LevelStreamer` (features/level-streamer.md)), trees and their hitboxes (`level_trees.gd`
     → `_pump`, plus `WorkerThreadPool` tile packs polled with `is_task_completed`), ground cover
     (`ground_cover.gd`) and spectators (`level_spectators.gd` spawns from `_process`). Audit every
     `_process` and every `WorkerThreadPool` use in `scripts/`, and record in the parity
     checklist how each behaves under a golden replay.
   - Run golden replays with `physics/3d/run_on_separate_thread` off.
   - Run golden replays with adaptive graphics off (the replay's default unless `--adaptive`). Its
     knobs (`LevelKnobs`) change spectators, tree draw distance and ground-cover reach based on
     measured frame time, which would change the scene counts. `AdaptiveController` gets its own
     parity test on a synthetic frame-time sequence instead.
2. **Car step golden.** `benchmark/level_replay.gd` → `_play_tick` writes the recorded pose and
   velocities into the physics server every tick. So the car's path is the recording, not the
   simulation's output, and comparing paths would test nothing. A recording also holds only the pose,
   velocities and three inputs (throttle, steer, handbrake), not the rest of the car's state, so the
   car can't be reset to it. Instead:
   - Add a `snapshot()` to the car, engine, drivetrain and damage model that captures all of their
     per-tick state. Godot only records; `restore()` exists only in Rust, because Godot's
     `VehicleWheel3D` keeps internal state between ticks (wheel rotation, the suspension contact
     latch) and Jolt's contact cache and sleep state can't be set from script. First list which
     per-wheel state `VehicleWheel3D` lets a script read, and for the rest either rebuild it from the
     transforms or accept a tolerance. The state captured: engine RPM, gear, clutch, turbo, nitrous, misfire timer,
     wheel spin, damage, temperatures, wheel bend, cooldowns. Include world state the car changes:
     trees felled through `TreeFall` / `TreeMeshField` (which turn their hitboxes off), the poses
     and velocities of the spectator ragdolls `spectator_group.gd` builds, and the log piles (rigid
     bodies the car hits), which the car can hit.
   - Record a fresh drive by hand with `run_level_replay.sh --record`, extended to log every input
     action (shifting, nitrous and the rest, not just three). The hand session records only that full
     input log (the existing `AutoDriver` plans routes on the island's `RoadNetwork`, so it can't drive
     the level).
   - CI then replays the log headless, free-running, to produce the blessed per-tick golden data
     below, so the goldens come from the CI runner image. Check that this CI run stays on the road. `hafren.rec` can't be reused: its
     inputs only make sense along its pose-fed path, so a free-running car would leave the road within
     seconds and the golden would mostly cover crashes.
   - Each tick of the CI run, store the snapshot before the step, the inputs, and the result after it: pose,
     velocities, RPM, gear, wheel contacts, suspension compression, contact impulses.
   - The Rust comparison restores each tick's snapshot, steps once, and reports the first tick that
     differs past the tolerance.
   - Jolt keeps a contact cache between steps that can't be set from outside, so a restored state's
     next contact impulses differ slightly. Ticks with contacts get a wider tolerance, or are
     compared over a short window of a few ticks.
3. **Car drift report.** Godot's reference is the blessed CI run from step 2: from any tick onward,
   the rest of the drive is what the car did freely. The Rust version restores the snapshot at a tick every
   few seconds, runs freely on the recorded inputs for a few seconds, and is compared on path and
   whole-run figures (segment times, top speeds, where each segment ends) within a
   tolerance that widens over time, as a report you review rather than a pass/fail check.
4. **Game-state trace.** A pose-fed replay (as `level_replay.gd` works today) also writes an event log:
   damage and temperature changes, money, loot drops, shop purchases, rally starts and results,
   weather changes, discoveries, sound effects triggered (logged where the game decides to play
   them, because `Audio` skips playback headless, as in CI), and the full save JSON at the end. Each event
   carries its physics tick. This needs a few scripted actions on top of the recorded drive (a
   purchase, a rally) so those systems run. Two Godot runs must produce the same log; a difference is
   reported as the first differing event. Against Rust, the parity table applies: events exactly,
   damage and temperatures within tolerance.
   - Also log each audio bus's level and the music state (track, crossfade position) every tick, so
     the mix and music are compared too, not just which sounds started.
5. **Menu-flow replays.** A scripted sequence of key presses and gamepad presses through every menu
   page (title, settings, pause, map, shops, results, account). After each press, log a page ID, the
   focused item's label (never a Godot node path, which means nothing to the Rust version) and any
   state the press changed. Built on the nav tests in `features/menu-navigation.md`.
   - **Layout:** on each page, also log every widget's on-screen box in the logical frame. Boxes must
     match within a pixel, so layout drift is caught automatically, not only in the visual review.
   - **Text input:** the account page's "type the email and paste the code" flow, as recorded text
     and paste events.
   - **Touch and tilt:** a second script drives the touch controls (`features/mobile-controls.md`)
     and tilt steering (`tilt_input.gd`) with recorded touch points and device angles, and logs the
     resulting actions and `TickInput`, so phone controls are compared too.
6. **Scene counts.** Taken right after a teleport to each spot, once streaming has finished and
   before anything moves (spectators steer and ragdoll, log piles are rigid bodies, and two physics
   engines won't agree on live positions to 1 cm). At fixed spots along the road (pinned in the golden; e.g. the
   `tools/level_draw_calls.tscn` defaults `0.1,0.35,0.6,0.85` of the road), list every tree,
   building, fence, spectator and log pile within a fixed radius, by type and position. Two lists match
   when every item has a partner of the same type within 1 cm. Rounding to the centimetre and comparing
   exactly would flip on values near a rounding boundary.
7. **Save round-trip.** Fixture saves covering every field of `profile.json` (`save_manager.gd`),
   including the key and gamepad bindings `input_remap.gd` stores (Godot key codes, joypad button
   and axis indices). Load, save, and compare. Compare the parsed values, with numbers normalised,
   not the text: Godot's `JSON.stringify` and serde order keys and print floats differently. In
   Phase 5 the same fixtures go Godot → Rust → Godot, because cloud saves move between the two
   versions and the Godot build stays available for one release after switch-over.
8. **Device targets.** Set frame-time targets for each device class (phone web, Android, iPhone,
   desktop) and record the Godot numbers beside them. Record both the whole frame (`busy_ms` p95 /
   p99) and the draw phase (`draw_phase`), plus a replay with the game-script nodes turned off
   (`--off=`, the `-off-<nodes>` report variant in `features/benchmark.md`) for the Phase 3 gate.
9. **No new Godot features after the recordings.** An intended Godot change during Phases 1–3
   re-blesses the goldens, with your go-ahead.
10. **The parity checklist.** Write it, with one row per feature file.

**Exit:** every golden above (car step, drift report, game-state trace, menu flow, scene counts, save
round-trip) runs in CI, is blessed on the CI runner image, and is documented in `features/testing.md`.
Godot's numbers are recorded for every device class. The parity checklist exists.

### Phase 2 — A neutral data format

**Driven by:** Sonnet.

Today the level's offline bake is a Godot resource (`tools/levels/hafren_5km.bake.res`, written by
`LevelBake` in `scripts/level_bake.gd`). `hafren_5km.json` and `hafren_5km.buildings.bin` (from
`tools/bake_buildings.js`) are already engine-neutral.

1. Make `LevelBake` also write a documented, versioned binary (heights, road frame, road samples, tree
   tiles, visibility) that doesn't depend on Godot.
2. **Distribute it like the current bake.** `*.bake.res` is git-ignored: CI runs
   `tools/fetch_bakes.sh`, which works out the bake's key by running `tools/bake_key.gd` in Godot and
   downloads the file from the `bakes` GitHub release (`tools/publish_bake.sh` uploads it). The neutral file
   needs the same publish and fetch path, with a key that can be computed without Godot (in JS beside
   the labs, or in Rust).
3. Write the same for every other imported asset the shipped game loads: the car models under
   `blender/`, the models under `models/` (spectators, cabin, rocks, ground cover), tree impostors,
   textures, materials (`materials/*.tres`), the UI theme (`theme/ui_theme.tres`) and fonts. For
   the Phase 3 viewer, also export the built level geometry from Godot: terrain chunk meshes, ground
   cover placement and tree tiles. Their
   `.import` files hold the import settings that have to carry over.
   - Textures import as lossy WebP by default (`[importer_defaults]`: `compress/mode=1`, quality
     0.7), so the GPU receives decoded pixels. Only textures whose own `.import` picks VRAM
     compression use ETC2 / ASTC blocks (`[rendering]` →
     `textures/vram_compression/import_etc2_astc`). Meshes get LODs and compressed vertex attributes
     at import. Export the decoded pixels, the compressed blocks for VRAM-compressed textures, and the
     generated LODs from a tool scene, so the Rust version starts from the same data rather than
     re-importing the sources differently.

**Exit:** a small standalone Rust program loads every asset. The level data checksums match the Godot
load exactly. The Rust loader's decoded textures and meshes (pixels, and vertex arrays after
decompression) equal Godot's in-memory data, read from a tool scene.

### Phase 3 — Renderer and build spike, and the go/no-go gate

**Driven by:** Opus. The Architecture section above is settled. The build spike, the stutter measurement and the assumption checks are research rather than implementation. Sonnet can build the viewer's drawing once the renderer design is settled. **Your steps:** the go/no-go decision, TestFlight install.

A standalone wgpu viewer, not yet a game. It loads Phase 2's data and flies the camera along
`hafren.rec`'s path, the same recording the Godot comparison replays.

1. Draw what the Godot frame draws, so the comparison is fair:
   - terrain chunks at every LOD level (see `LevelStreamer` (features/level-streamer.md), and its doc in `features/`), trees, ground cover and buildings;
   - the PS1-style post-process (`ps1_post_process.gdshader`), the panorama sky, water, and the car
     with its shadow;
   - the settings in "What Godot draws that we don't write".

   The GPU culls and picks LODs, and draws are indirect. The built geometry (terrain chunk meshes,
   ground cover placement, tree tiles) comes from Godot, exported in Phase 2, so the viewer draws the
   same geometry. It streams that prebuilt data on worker threads as the camera moves; the speed of
   building it in Rust is Phase 4's concern. The HUD, particles and game scripts are left out.
2. **Build spike.** Prove the parts of the stack nobody has tried here yet, in the same viewer:
   - a Rust Jolt binding at, or forkable to, Godot 4.6's Jolt commit (the available bindings wrap
     specific Jolt versions);
   - that Jolt built for WebAssembly (single-threaded, compiled with `-matomics -mbulk-memory`; see
     the Stack's physics row) links into the threaded shared-memory module, with a heightfield shape
     built on a worker thread;
   - WebAssembly threads working for the streaming workers;
   - one body stepping in the browser;
   - the same steps on native and WebAssembly, with the cross-platform determinism option on, giving
     identical results.
3. Run it on Chrome desktop, Chrome Android, Safari on iOS / macOS, native Windows, native Android
   and native iOS. The iOS run needs the minimal Xcode project that links the Rust library; create it
   here (Phase 6.2 reuses it) and ship it through TestFlight with the signing and CI from Phase 0.
4. **A Rust replay benchmark.** Give the viewer the same report as `benchmark/level_replay.gd`,
   measured the same way: main-thread busy time per frame, the wall-clock frame interval, the draw
   phase, `?replay=1` on web, and the upload to `tools/bench_collector.py`. Phase 5 carries this
   harness into the game.
5. Compare like with like. The viewer runs no game scripts, so compare its frame time against the
   Godot replay with the game-script nodes turned off, and its draw cost against Godot's draw phase
   (Phase 1.8).

6. **Check the Architecture's assumptions**, before the streaming design is finalised:
   - Attribute the untracked 10–17 ms in Godot's streaming spikes (engine-side mesh, collision-shape and
     node creation), as set out under "What the speed gain comes from".
   - Confirm Godot's 36 px Jersey 10 equals a 2× scale of the 18 px glyphs (see the UI section).

**Gate:** the build spike works, and on the phone-web device the viewer's main-thread time (p95) is at
most half the matching Godot replay's. If either fails, stop here. At most Phase 0, Phase 1.8 and Phase 2 have been
spent. Phases 0 and 1 are useful on their own (an iOS release, working cloud sign-in, regression
goldens); Phase 2 isn't.

### Phase 4 — Port the simulation core as plain Rust crates

**Driven by:** Sonnet for pieces 1–3. The car (piece 4) is Sonnet with the escalation rule below.

Each piece becomes a plain Rust crate with no Godot types, checked with `cargo test` against outputs
recorded from Godot. There's no godot-rust (GDExtension) binding layer: it would only ever run in CI and
desktop builds (GDExtension on web is experimental, the web export has
`variant/extensions_support=false`, and iOS needs a statically linked framework), and recorded outputs
check the crates just as well. The Godot game keeps shipping unchanged meanwhile.

The car needs a world to collide with, so its crate gets its own Jolt world, with the same commit and
settings as Godot's (see "The car"), built from Phase 2's data: terrain chunks and the level's other
collision (`level_trees.gd`, `level_buildings.gd`, `obstacle_body.gd`, `level_fences.gd`). Phase 5 reuses that world.

Port order, from easiest to check to riskiest:

1. Engine audio synthesis (`engine_audio_synth.gd`, `engine_audio_feed.gd`). Compare samples against
   GDScript output for the same input.
2. Terrain chunk building and level data decode: the level path of `LevelStreamer` (features/level-streamer.md)
   (`_compute_heights`, `_compute_arrays` today), `level_data.gd` and the `LevelBake` load,
   reading Phase 2's format. Compare outputs exactly; these are also the biggest load-time wins.
3. Engine and drivetrain (`engine.gd`, `drivetrain.gd`). Compare per-tick torque and RPM traces.
4. The car: the `VehicleBody3D` wheel model plus `car.gd`'s forces and `DamageModel`
   (`damage_model.gd`, in `physics`). Compare against Phase 1's car step
   golden.

The Godot feature freeze (see "The parity contract") starts here.

**Exit for each piece:** its outputs match the ones recorded from Godot (the car's against the car
step golden), and the GUT tests that cover it have Rust equivalents that pass. The car piece must pass
the car step golden before Phase 5 starts.

### Phase 5 — The new shell

**Driven by:** Sonnet, building on the Architecture section. Opus reviews the game loop, threading and renderer integration (steps 1–3) before the long tail starts. **Your steps:** the side-by-side visual review.

Build the game around the Rust crates without Godot:

1. Game loop with a fixed timestep, input (see the Stack's input row), cameras (`chase_camera.gd`,
   `camera_manager.gd`), streaming (`LevelStreamer` (features/level-streamer.md)) on worker threads.
2. Physics on Phase 4's Jolt world, plus the rest of the dynamic world (spectator ragdolls, felled
   trees, log piles).
3. The replay benchmark from Phase 3, now running the whole game.
4. HUD (`hud.gd`, `hud_dial.gd`), minimap and map (`level_minimap.gd`, `level_map.gd`).
5. Menus as flat pages with the same navigation rules as `MenuNav` (`scripts/menu_nav.gd`,
   `features/menu-navigation.md`); the look ported from `UITheme`.
6. Save and cloud: port Firestore sync, email link sign-in and account deletion as Phase 0 left them
   (`scripts/cloud/`). They are REST calls and port directly.
   - **Links that open the app** (the allowed difference from Godot): on iOS, universal links; on the
     Play Store Android build (`tappa.game`), App Links. Since Firebase Dynamic Links shut down, Firebase's
     mobile email-link flow opens the app through a Firebase Hosting domain passed as `linkDomain`.
     So turn on Firebase Hosting (free plan; it serves only these tiny files, not the game) on the
     project's default domain, and pass `linkDomain`, `iOSBundleId` and
     `androidPackageName: tappa.game` in `sendOobCode`. Hosting may serve
     `/.well-known/apple-app-site-association` and `/.well-known/assetlinks.json` itself once the apps
     are registered in the Firebase project (iOS Team ID and App Store ID, Android SHA-256); check the
     current Firebase docs and hand-write them only if it doesn't.
   - `assetlinks.json` must list the **Play App Signing** certificate's SHA-256 (Play re-signs the
     build), not just the upload key's.
   - The itch Android APK (`io.itch.felixxwu.rally`) and Windows keep the paste-the-code page, as in
     Godot.
   - Local files are `profile.json`, `auth.json` (stays signed in) and `adaptive_graphics.json`; none
     is imported from the Godot build (see "Settled decisions").
7. Input actions and bindings: port the `[input]` section of `project.godot`, and translate the
   bindings saved by `input_remap.gd` with fixed tables from Godot key codes to winit keys and from
   Godot joypad button and axis indices to the Rust gamepad layer.
8. Everything else, listed from three sources so nothing outside the level view is missed: the
   `[autoload]` section of `project.godot` (e.g. `CarPreviewCache`, `DisplayStretch`,
   `WebFullscreen`, `InputRemap`), every `.tscn` (title screen, loading screen, photo mode, the
   update check), and the parity checklist. That covers weather, spectators, fences, tyre marks,
   dust, smoke, lamps, rallies, shops and loot, and also everything in "What Godot draws that we don't
   write".

**Exit:** the new shell plays the Phase 1 recordings and produces the same car steps, game-state trace,
menu-flow log and scene counts as Godot, and you've reviewed the drift report. Saves round-trip
Godot → Rust → Godot unchanged. The layout and touch logs match, and the cloud scenarios pass against
the Firebase emulators. The Phase 1.8 frame-time targets are met on every device class,
measured with the Rust replay benchmark. You've signed off the side-by-side visual review. Every row of
the parity checklist is done. The Rust performance budget (see Testing) is then set from these runs.

### Phase 6 — Platforms, tools, switch-over

**Driven by:** Sonnet. **Your steps:** Play App Signing fingerprints, App Store submission, the switch-over call.

1. CI builds: WebAssembly (deployed to Cloudflare Pages like the Godot build), Android (cargo-ndk,
   android-activity; both APK and AAB, matching today's `export_presets.cfg`), Windows, and iOS. Keep
   the same app IDs and signing keys, and version numbers (`versionCode`, `CFBundleVersion`) above
   Godot's last release. Google Play requires 16 KB page alignment for native libraries: build the
   Rust and Jolt libraries with NDK r28+ (or `-Wl,-z,max-page-size=16384`) and check it in CI.
   Cloudflare Pages' 25 MiB per-file limit applies: serve the large `.wasm` and data files from R2
   through a Pages Function, as in Phase 0.1.
   Update `features/release-pipeline.md`.
2. **iOS release.** The store listing, signing and macOS CI exist from Phase 0, and the Xcode project
   from Phase 3, so this is swapping the build: ship it as an update to the same App Store app, with
   the privacy manifest carried over. Choose the minimum iOS version: the oldest one whose devices meet
   the phone frame-time target, not the oldest one Metal supports.
3. Port the GDScript tools that are still needed to Rust command-line tools: `tools/bake_level.gd`,
   `tools/bake_key.gd` (unless Phase 2 already replaced it), `tools/build_ui_theme.gd`,
   `tools/bake_ui_palette.gd`, `tools/build_vegetation.gd` and the capture scenes. The browser labs
   (`tools/level_editor_lab.html`, `tools/*_lab.html`) and the JS bake scripts stay as they are.
4. **An asset importer.** Phase 2 exports assets through Godot, which is deleted at switch-over, so
   new or changed textures and models need a Rust command-line importer: texture decode and
   compression, mesh LOD generation and vertex compression. Its output must match Phase 2's for the
   existing assets.
5. **A device checklist** for what can't be automated, run by hand on each platform before
   switch-over (and before each later release): app backgrounded and resumed mid-drive, the web audio
   unlocking on the first tap, fullscreen on and off, safe areas on a notched iPhone, the save
   surviving a closed tab or killed app, an email sign-in link opened from the device's mail app, and typing the email and pasting the code.
   Keep it in `features/release-pipeline.md`.
6. Switch over once Phase 5's exit checks, including the frame-time targets, pass on every platform, and
   the device checklist passes: ship the Rust build, keep the
   Godot build buildable for one release, then delete Godot, GUT and the GDScript. There's no
   parallel beta period, because nobody is playing the game yet; the scripted goldens are the
   whole parity check. Rewrite `features/` and the project `CLAUDE.md` for the new codebase.

## Testing

### Ordinary tests

Logic and behaviour tests move from GUT (`tests/headless/`) to `cargo test`. The `CLAUDE.md` testing
rules carry over unchanged: no pinned tuning values, synthetic fixtures instead of catalogue entries,
behaviour such as "W drives the car forward" and "reset returns to the start". Port each GUT test
alongside the code it covers in Phases 4–5, not as a separate pass. Rust tests that need no scene should run in
seconds, which removes most of the cost-model work in `features/testing.md`.

### Golden tests: change detectors, not correctness tests

These record a known-good output and fail on any change. They clash with the rule against pinning
tuning values (any retune changes them), so they work differently from ordinary tests:

- **They run as their own suite.** A failure means "this changed, was it meant to?", not "this is
  broken".
- **Re-recording ("blessing") is a human decision.** Only an explicit command (`bless`) writes golden
  files; ordinary runs never do. A `CLAUDE.md` rule: an agent may not bless unless the user asked for
  the behaviour change. A CI check fails any change to golden files whose commit message has no
  `Bless:` line saying why (a git hook wouldn't be installed by cloning, and agents can skip it).
- **Every failure produces a readable diff.** For images, a side-by-side PNG with the differing pixels
  highlighted. For physics, a plot of the car's path against the golden and the first differing tick.
  Agents can read PNGs, so they can tell "the trees vanished" from "the sky shifted by 1%".

The parity goldens are described in Phase 1. After switch-over, these keep guarding the Rust version:

1. **Car step and drift.** The Phase 1 goldens, re-recorded from the Rust version at switch-over. With
   Jolt's cross-platform determinism option on, the same golden must pass on native and WebAssembly.
2. **Rust performance budget.** Draw calls, triangles, loaded chunks and GPU buffer sizes at the
   pinned spots, from the Phase 5 numbers. It's Rust-only: draw-call counts mean something different
   in a GPU-driven renderer, so there's no Godot equivalent to share. Deterministic and needs no
   images. Raising the budget counts as a bless and needs a reason, as `CLAUDE.md` already says.
3. **Pixels.** About 5–10 shots, not more: a few spots on Hafren, the HUD, one per menu page. A large
   set ends up re-blessed by reflex. To keep the output stable:
   - render on a software GPU in CI (lavapipe or SwiftShader for Vulkan, WARP for DX12);
   - pin the camera, time of day and seed, and turn off temporal effects;
   - compare with a per-pixel threshold and a maximum share of differing pixels.

### Parity during the migration

The goldens recorded from Godot in Phase 1 (car step, drift report, game-state trace, menu flow, scene
counts, save round-trip) are shared by both versions and are the working form of the parity contract.
Phase 4 checks each crate against them; Phase 5 checks the whole new shell against them. They
are never re-blessed to make Rust pass: a Rust difference is a Rust bug. The only exception is a Godot
bug found during the port, which is fixed in Godot first.

Pixels and performance can't be shared, because the two renderers will never match. Instead:

- **Side-by-side visual review.** Godot and Rust screenshots from the same camera positions and time
  of day, with a loose perceptual diff highlighting large differences. It's a report for you to sign
  off shot by shot, not an automatic gate.
- Once signed off, the Rust screenshots become the first pixel goldens, and from then on guard the
  Rust renderer against regressions.

## Risks

- **Car feel.** The wheel model and Godot's Jolt layer are the hardest parts to match. Mitigation: the
  car step golden and drift report from Phase 1, and porting the car last in Phase 4.
- **Determinism work in Phase 1.** Making today's level replay deterministic touches many systems
  (random numbers, frame-timed logic, streaming). It's sizeable, but every exact parity check depends
  on it.
- **The web payoff depends on the game-code port, not just the renderer.** The spike puts Godot's draw
  phase at ~40% of the web frame; the rest is scripts, physics and streaming. If the Rust game code
  turns out only modestly faster than GDScript, the web gain shrinks to roughly the draw phase.
- **WebAssembly toolchain.** Jolt (C++) and Rust threads on WebAssembly both need non-default
  toolchains (clang with the wasi-sdk sysroot, nightly Rust). The Phase 3 build spike proves them before
  anything expensive is committed.
- **WebGPU reach, accepted.** Older Android phones, iPhones that can't run iOS 26 (on web) and
  Firefox on Android are turned away. This was a deliberate choice, not a risk to mitigate.
- **Scope.** All of the GDScript left in `scripts/` after the Hafren-only cleanup, plus everything Godot gives us for free: asset
  import, shader warm-up, Android export, the scene tree. Phases 0–3 exist so that scope is only
  committed after the speed gain is shown. The Godot editor isn't used (scenes are written as code
  and text, and authoring happens in the browser labs), so losing it costs nothing. The `.tscn`
  files are ported as code like everything else.
- **App Store review.** It's a new gate we don't control. Phase 0 goes through it with the Godot build
  first, so the switch-over is a routine update, not a first review.

## Dependencies

- Phase 0 needs the Hafren-only cleanup (done 2026-11-28) to be done. Phase 1
  needs Phase 0, so the goldens are recorded once, with the final feature
  set. Phase 2 needs only the cleanup and can run alongside Phases 0 and 1.
- Phase 1.8 (the device numbers) needs only Phase 0.6, the iOS build, not the rest of Phase 0.
- Phase 3 needs Phase 2's data, Phase 0's iOS signing, and only Phase 1.8, not the rest of Phase 1. So
  the go/no-go gate doesn't wait for the determinism work or App Store review.
- Phase 4 needs Phase 1's goldens, Phase 2's format and Phase 3's gate to have passed.
- Phase 5 needs Phase 4's car piece to be done.
- Phase 6 needs Phase 5.

## Open questions

None.

Settled 2026-11-27: iOS is a target (native, App Store). The Godot editor isn't used. WebGPU-only is
accepted. Sign-in is email link only. The web build moves to Cloudflare Pages. The iPhone version is
free with no purchases. Phases 0 and 1 start only when the migration does. No local save import. Outlines are
dropped from both versions. The architecture decisions are listed under "Architecture".
