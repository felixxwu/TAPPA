# Configuration (`GameConfig`)

All gameplay and look tuning lives in a single resource so it can be changed
without touching code or scenes.

- **Resource file:** `config/game_config.tres`
- **Script / class:** `scripts/game_config.gd` (`class_name GameConfig extends Resource`)
- **Autoload accessor:** `scripts/config.gd` (`Config` singleton) → `Config.data`

**Tests:** `tests/headless/test_config_applied.gd`, `tests/headless/test_config_isolation.gd`

```gdscript
# Reading config anywhere:
var cfg := Config.data
body.mass = cfg.mass
```

`config.gd._init()` loads `res://config/game_config.tres`, falling back to a
fresh `GameConfig.new()` if missing. Values are read-only during play; editing
the `.tres` requires a scene reload to take effect.

## Reading a field with a fallback

Several call sites (audio.gd and others) need a specific field
with a fallback for when `Config.data` is unavailable (e.g. an off-tree unit test).
Use the shared accessors rather than re-deriving the null-handling:

```gdscript
Config.get_float("sfx_beep_frequency_hz", DEFAULT_FREQUENCY_HZ)
Config.get_bool("sfx_enabled", true)
```

These used to be reimplemented locally in five places with two different (and two
missing) null-handling strategies. The chosen semantics is `field in data` — "is this
a genuinely declared `@export` property" — rather than `data.get(field) != null`,
because every `GameConfig` field has a non-null default, so the two checks agree for
every real field; `in` is preferred because it says what we mean directly, and a
missing field (a typo'd name) `push_warning`s instead of silently resolving to the
fallback, which is how that class of bug used to hide. See `scripts/config.gd` for
the full rationale comment.

## The live config's identity is load-bearing

`Config.data` is held **by reference**: the active car (and through it `Drivetrain` /
`EngineSim`) keeps it as `car.config`, while `hud.gd`, `engine_audio.gd`, the tuning lift
and the save layer read `Config.data`. That shared identity is the wiring — it is how a
mid-stage refit on the car is seen by the HUD at all. So **code that saves and restores the
config around a mutation must copy VALUES back into the same object**, never
`Config.data = <a duplicate>`; reassigning splits the car from everything that reads it
(the boost-gauge bug in start-line.md (deleted with the free-roam pivot) → *grid spawn*).

`GameConfig.snapshot_values()` / `restore_values()` are that pair:

```gdscript
var saved := Config.data.snapshot_values()   # { property_name: value }, containers deep-copied
...                                          # something mutates the live config
Config.data.restore_values(saved)            # written back IN PLACE
```

They walk the **script property list**, not just the `@export`ed fields, because the LIVE
engine fields (`peak_torque`, `redline_rpm`, `engine_cylinders`, `engine_firing_angles`) are
plain `var`s that `EngineLibrary.apply()` writes at fielding time — `Resource.duplicate()`
resets those to their declared defaults, so it isn't a value-complete snapshot either.
Callers: `car.gd`'s `_live_baseline` (the pre-upgrade/pre-tune baseline `retune()` /
`refit_upgrades()` re-derive from) and `start_line.gd`'s `_spawn_grid`. Only
`Config.reset()` / `reload_from_disk()` legitimately install a new object, and both are
boot/debug paths that re-field the car afterwards. Guarded by
`tests/headless/test_config_isolation.gd`.

## The authored baseline (`Config.authored_value`)

`Config` keeps a SECOND reference alongside `data`: `_authored`, the pristine `.tres` as
loaded, which nothing ever mutates (`data` is a `duplicate(true)` of it precisely so the
runtime is free to retune itself). `Config.authored_value(field, fallback)` reads a field
off it.

Its one caller is `UpgradeLibrary._reseed_globals`. A per-car field mutated by the effects
funnel is re-seeded by `car.gd::apply_car` on the next fielding, but the skill rows
(`todo/roguelike-pivot.md` decision 51) target GLOBAL tunables — a coin radius, a money
rate, a stage-target pace — that nothing re-seeds, on a `Config.data` that outlives every
scene. Without a pristine copy to read there is no way back to the authored number, so a
multiplier would compound stage after stage and un-equipping the skill would never undo it.
See skills.md (deleted with the free-roam pivot) → *Why every skill row carries `reseed`*.

Note the difference from `snapshot_values()` above: that captures the LIVE config at a
moment (including engine fields written at fielding time); this is the authored file, and
only ever the authored file.

## Property groups

`game_config.gd` exposes 50+ `@export` properties, grouped:

### Car
| Property | Default | Purpose |
|----------|---------|---------|
| `mass` | 120.0 | Chassis mass (kg) |
| `brake_torque` | 300.0 | Foot-brake N·m per axle (S) |
| `handbrake_torque` | 400.0 | Rear handbrake N·m (Space) |
| `drag_coefficient` | 0.4 | Quadratic aero drag (top-speed limiter) |
| `hitbox_chamfer_fraction` | 0.333 | Fraction of body width cut off each vertical corner of the collision hull, chamfering it into an elongated octagon (equal inset on X + Z → 45° corners, regular octagon at the nose). Only affects obstacle contacts + damage impulses, not grip/speed. 0 = plain box (range 0.0–0.5) |
| `downforce_front` / `downforce_rear` | 0.0 | N per (m/s)² at each axle; negative = lift (range -2.0–2.0). Set **per-car** by `apply_car` from the CarLibrary spec (these defaults are just the fallback); every car has a small rear value |
| `steer_limit` | 1.0 rad | The wheel's MECHANICAL stop, and the only bound on the angle. The grip servo measures the peak-grip angle rather than predicting a cap, so there is no slip-derived limit or low-speed blend to configure |
| `steer_speed` | 2.0 (`.tres`) | Rate limit (rad/s) when winding MORE lock on (target further from center, same direction as the current wheel angle, or starting from center) — the model of how fast a hand can turn the wheel, and also the input smoothing. The servo covers just the tire's slip angle (~8.6° on tarmac), not full lock, so this is the dominant feel parameter and is tuned far below a lock-to-lock rate |
| `counter_steer_speed` | 3.5 (`.tres`) | Rate limit (rad/s) when winding lock back OFF, measured relative to `null_angle` (not center) — target closer to the null or across to its far side. Real countersteering/slide-catching happens faster than winding new lock on, so this is tuned higher than `steer_speed`; being null-relative keeps one continuous slide-catch on this rate even as it crosses center, see `features/car-physics.md` |
| `steer_deadzone` | 0.02 | Steering demand below which the wheels servo to their zero-lateral-slip angle (auto-countersteer). A deadzone, not an exact-zero test, because sticks and the touch slider never return 0 |
| `spin_assist_torque` | **0.0 (off)** | Spin protection: corrective yaw torque (N·m) back toward the travel direction past `spin_assist_angle` of slip; suppressed while the handbrake is held. **Deliberately disabled** — grip-servo steering plus the lowered `com_height` and the grounded anti-roll bar handle slides without a yaw aid. The code stays for anyone who wants it back |
| `spin_assist_angle` | 0.6 rad (`.tres`) | Slip angle (≈34°) where spin protection starts; ramps to full at twice this angle |
| `level_assist_torque` | 10000.0 (`.tres`) | Self-righting roll+pitch torque while airborne (N·m at 90° tilt); 0 disables |
| `level_assist_grounded` | 1.0 (`.tres`) | Fraction of `level_assist_torque` kept with all four wheels planted, where the aid acts as an anti-roll bar (referenced to the wheel contact normal, not world up); 0 = airborne-only |
| `wheel_roll_influence` | 1 (`.tres`) | Height tire forces act at (0..1): body roll (lateral) + pitch dive/squat (longitudinal); 0 = CoM (rollover-proof fudge), 1 = contact patch (physical) |
| `com_height` | −0.25 (`.tres`) | Centre-of-mass height (m) relative to the body origin; negative lowers it. Sets the rollover threshold `track / (2 × CoG height)` — see car-physics.md |
| `wheel_friction_slip_front` | 0.8 | Front tire grip coefficient μ |
| `wheel_friction_slip_rear` | 0.6 | Rear tire grip coefficient μ |
| `parking_hold_grip` | 1.0 | Static-friction hold cap (`·m·g`) for a stopped, fully-braked car so it doesn't creep down a slope (`car._apply_parking_hold`); 0 disables |
| `parking_hold_stiffness` | 300.0 | Stiction spring stiffness (1/s²) pulling a held car back to its anchor; resting slack ≈ disturbance accel / this. Must stay well under `1/dt²` to remain convergent |
| `parking_hold_damping` | 20.0 | Damping (1/s) on that stiction spring (~0.6 of critical) |
| `parking_hold_slack` | 0.05 | Slack (m) the anchor trails the car by once the grade beats the stiction cap and the car slides |
| `suspension_travel` | 0.5 | Spring compression distance (m) / wheel rest length |
| `suspension_travel_front` | 0.0 | Front travel override; 0 = inherit `suspension_travel` |
| `suspension_travel_rear` | 0.0 | Rear travel override; 0 = inherit `suspension_travel` |
| `suspension_stiffness` | 10.0 | Overall spring rate; split front/rear by `weight_front` (`axle_stiffness`), dampers derived per axle |
| `weight_front` | 0.5 | Static front-axle weight fraction; drives the centre of mass AND the spring-rate split |

Four steering knobs were **removed** by grip-servo steering — `steer_travel_alignment`,
`steer_lock_blend_end_speed`, `steer_assist_torque` and `steer_assist_min_speed` — because the
servo measures the grip limit instead of predicting it. See
[car-physics.md](car-physics.md) → Steering.

### Engine & Transmission
| Property | Default | Purpose |
|----------|---------|---------|
| `idle_rpm` | 900.0 | No-stall minimum |
| `rev_limiter_band` | 100.0 | Bouncing limiter width (rpm) |
| `gear_ratios` | [6,4,2.9,2.4,2] | Forward gear ratios |
| `reverse_ratio` | 6.0 | Reverse ratio |
| `final_drive` | 4.0 | Differential ratio (multiplies all gears) |
| `clutch_max_torque` | 250.0 | Max clutch holding torque |
| `clutch_engage_speed` | 4.0 | Coast speed below which auto-clutch opens |
| `shift_time` | 0.25 | Clutch-open throttle cut per gear change (s); **overridden per-car** by `CarLibrary` |
| `auto_gearbox` | false | Unused — the transmission is always automatic now (`SettingsMenu.gearbox_auto()` always returns `true`); there is no gearbox settings row or runtime toggle |
| `nitrous_boost_gain` | 0.0 | Extra torque fraction while nitrous is held (delivered torque × `(1 + this)`); 0 = no nitrous fitted. See [nitrous.md](nitrous.md) |
| `nitrous_tank_seconds` | 0.0 | Seconds of nitrous a full tank holds; 0 = no nitrous fitted. `has_nitrous()` is true only when both this and `nitrous_boost_gain` are positive. See [nitrous.md](nitrous.md) |
| `upshift_redline_fraction` | 0.90 | Auto upshift at this % of redline |
| `engine_volume_db` | -6.0 | Master audio gain |
| `engine_idle_gain` | 0.25 | Idle audio floor |
| `engine_harmonics` | 4 | Firing-pulse richness |
| `engine_noise_level` | 0.15 | Broadband noise mix (per-car from `CarLibrary.noise_db`, in dB) |
| `engine_smoothing_rate` | 200.0 | RPM/throttle audio tracking rate |
| `engine_low_octave_mix` | 0.0 | Crossfade toward a voice one octave lower (per-car; Viper 0.7) |
| `engine_soft_clip_drive` | 0.6 | Pre-amp into the sine soft clipper (global; higher = more grit) |
| `engine_soft_clip_post_gain` | 1.0 | Post-amp after the soft clipper (global; 1.0 = transparent) |
| `engine_audio_ref_distance_m` | 8.0 | Proximity attenuation: full-volume radius (m) from the active camera |
| `engine_audio_max_attenuation_db` | -60.0 | Proximity attenuation: quietest a distant engine drops to (dB floor) |
| `drive_mode` | 0 (RWD) | Initial layout: RWD, AWD, FWD |

### HUD / Camera / World
| Property | Default | Purpose |
|----------|---------|---------|
| `hud_enabled` | true | Show speed/gear overlay |
| `mobile_controls_force` | false | Force on-screen touch controls on (testing; otherwise auto-enabled on touch devices) |
| `mobile_controls_debug` | false | Top-left readout of the touch input path (which browser snapshot is feeding the overlay, fingers the browser thinks are down, regions held) — for diagnosing stuck buttons on a real phone |
| `tilt_sensitivity` | 2.0 | TILT scheme: multiplier on device roll → steer (higher = full lock at a gentler tilt) |
| `tilt_deadzone` | 0.05 | TILT scheme: device roll (fraction of 1 g) ignored around level |
| `tilt_invert` | false | TILT scheme: flip the steering direction — the escape hatch if a device reports its roll the other way round (see [mobile-controls.md](mobile-controls.md) › Tilt) |
| `follow_distance` | 6.0 | Chase camera distance behind (m) |
| `follow_height_ratio` | 1.0 | Chase camera height as a multiple of `follow_distance` |
| `smoothing` | 5.0 | Camera follow smoothing rate |
| `photo_move_speed` | 25.0 | Photo mode free-fly camera lateral/vertical movement speed (m/s) |
| `photo_look_sensitivity` | 0.003 | Photo mode mouse look sensitivity (multiplier on mouse delta per frame) |
| `photo_touch_look_sensitivity` | 0.004 | Photo mode **touch** drag-to-look sensitivity (radians per pixel of drag) — kept separate from `photo_look_sensitivity` since a finger drag and a mouse delta cover different pixel ranges. See [camera.md](camera.md) › *On-screen touch controls* |
| `photo_fov_min` / `photo_fov_max` | 20.0 / 90.0 | Photo mode pinch-zoom FOV clamp (degrees) — pinching apart zooms in toward `photo_fov_min`, pinching together zooms out toward `photo_fov_max` |
| `fog_density` | 0.02 | Environment fog thickness |
| `background_color` | (0.35,0.3,0.45) | Sky + fog color |

### Stage
| Property | Default | Purpose |
|----------|---------|---------|
| `stage_countdown_seconds` | 3.0 | Countdown before controls unlock at the start of a stage |
| `stage_complete_percent` | 99.0 | Track-progress % (0..100) that ends the stage |
| `hud_elapsed_enabled` | true | Show the top-right run timer |
| `hud_popup_show_seconds` | 3.0 | How long a transient in-run HUD tag (the corner-cut flash) stays before fading |

See [stage.md](stage.md).

### Lap-time model
| Property | Default | Purpose |
|----------|---------|---------|
| `gravel_grip` | 1.0 | Surface grip multiplier for gravel in `LapTimeModel` (`scripts/lap_time_model.gd`); blended with `tarmac_grip` by the event's tarmac fraction to get the effective µ |
| `tarmac_grip` | 1.3 | Surface grip multiplier for tarmac (higher → faster tarmac-heavy events) |
| `traction_factor_rwd` | 1.0 | Corner-exit traction ceiling for RWD cars in `LapTimeModel`'s forward pass (`a = min(factor × grip_long, a_engine)`). **1.0 is an exact no-op** |
| `traction_factor_awd` | 1.0 | Same, for AWD. Raising the AWD factor relative to the others is how AWD earns its traction advantage in generated times |
| `traction_factor_fwd` | 1.0 | Same, for FWD |

> **Moving any `traction_factor_*` off 1.0 changes every AI, rival and ghost time
> in the game.** Rival fields are generated live, so the change lands immediately
> — but it also re-scores every car's `CarPerformance` rating, which is what
> challenge ceilings are authored against. The same applies to authoring
> `downforce_front` / `downforce_rear` onto a catalogue car.

### Damage
| Property | Default | Purpose |
|----------|---------|---------|
| `impact_threshold_g` | 2.0 | Deceleration (g) a physics tick must exceed before it costs HP — keeps braking/clean landings free; the single sensitivity knob for the unified deceleration-damage model |
| `impact_ref_speed_kmh` | 60.0 | Reference shed-velocity (km/h) at which a hit costs `impact_ref_hp_loss` |
| `impact_ref_hp_loss` | 200.0 | HP a reference hit costs (square-law in shed velocity); a full arrest sheds ≈ the approach speed |
| `impact_max_loss` | 450 | Cap on one tick's HP loss, as a flat HP amount, so no single spike empties the bar; absolute so max_hp matters — a fragile car reaches 0 HP in fewer hits (it still drives, just slowly); a stopped car self-limits, a tumble racks up several |
| `damage_misfire_health_threshold` | 0.5 | Health fraction at/above which the engine is fully healthy; below it BOTH damage effects (misfire and rev cap) ramp in together |
| `damage_misfire_level_max` | 0.8 | Worst misfire intensity at 0 HP — below 1.0 so a 0 HP engine still fires often enough to drive |
| `damage_rev_limit_min_fraction` | 0.6 | Fraction of the redline still usable at 0 HP (see [engine-and-transmission.md](engine-and-transmission.md) § Damage rev cap) |
| `damage_misfire_rate_max` | 9.0 | Engine fuel-cuts/sec at 0 HP under full load (stumbling power loss) |
| `damage_misfire_load_bias` | 0.35 | How much the misfire fires independent of load (0..1) |
| `damage_misfire_duration_min` | 0.04 | Shortest single fuel-cut (s) |
| `damage_misfire_duration_max` | 0.16 | Longest single fuel-cut (s) |
| `damage_wheel_toe_gain` | 0.12 | Wheel-toe (rad) a full-per-hit-cap impact adds, scaled by hit strength & a random 0.5..1 per wheel |
| `damage_wheel_toe_max` | 0.14 | Per-wheel clamp on accumulated toe (rad) |
| `hud_hp_enabled` | true | Show the in-run HP gauge |
| `hud_low_hp_warn_frac` | 0.25 | HP fraction below which the gauge flashes a warning |

Per-car `max_hp` is CarLibrary metadata, not a `GameConfig` field. See
[damage.md](damage.md).

### Recovery
Automatic stuck-car recovery (see [progress.md](progress.md)).
| Property | Default | Purpose |
|----------|---------|---------|
| `recovery_enabled` | true | Master toggle for the stuck watchdog (the timed off-track reset runs regardless) |
| `recovery_timeout_s` | 3.0 | Seconds stationary + unable to self-recover before the free auto-reset fires |
| `recovery_speed_mps` | 0.7 | Below this speed the car counts as "not moving" |
| `recovery_depth_m` | 3.0 | Metres below the road surface that count as fallen-into-a-pit (recovers even with no throttle) |
| `recovery_upright_dot` | 0.3 | up·UP below which the car counts as flipped |

### Terrain Layers
Three (wavelength, amplitude) pairs — `terrain_layerN_wavelength` /
`terrain_layerN_amplitude` for N = 1,2,3 (large hills → fine bumps). See
[terrain.md](terrain.md).

### Water
Roadside lakes (see [lakes.md](lakes.md)). `water_enabled` (off by default),
`track_water_level_m` (per-event flood height), `water_shore_clearance_m` (start-pad
margin), `water_drag` (soft-hazard drag), `water_min_basin_area_m2`, and the
`water_color` / `water_shore_color` / `water_ripple_speed` / `water_sparkle_strength`
look knobs.

### Cliffs
Track-side cliffs & drops (see [terrain.md](terrain.md) → *Cliffs & drops*).
| Property | Default | Purpose |
|----------|---------|---------|
| `cliff_enabled` | true | Master toggle; off ⇒ the bake skips the cliff pass entirely |
| `cliff_wavelength_m` | 60.0 | Along-track period of the camber noise (**global**, same every event) |
| `cliff_gain` | 1.6 | Camber-noise scale before the `[-1,1]` clamp (higher ⇒ more full-height cliffs) |
| `cliff_max_height_m` | 8.0 | Global height ceiling at `\|camber\|=1` (= drop depth); scaled per event |
| `cliff_run_m` | 6.0 | Horizontal run road-edge band → full height (small ⇒ steep) |
| `cliff_fade_m` | 6.0 | Horizontal run full height → back to grade (bounds the influence radius R) |
| `cliff_open_radius_m` | 4.0 | Radius of the post-bake morphological open that knocks down thin tall walls (narrower than ~2× this); 0 disables |
| `cliff_amount` | 1.0 | Runtime per-stage scale on `cliff_max_height_m` (`[0,1]`); written by `StageConfig.apply_event_config` from the event's `cliffiness`, else the shipped fallback |

Pushed onto the terrain by `GameConfig.apply_cliffs(tm)` before `set_track` (mirrors
`apply_terrain_light`). `cliff_seed = track_seed`.

### Loading
The frame cap held for the duration of world generation only, via
`WorldRuntime.loading_cap(touch)` — see [loading.md](loading.md).

| Property | Old const | Purpose |
|----------|-----------|---------|
| `loading_max_fps` | `WorldRuntime.LOADING_MAX_FPS` | Loading-window cap on non-touch targets. 0 = uncapped (the fastest load). |
| `loading_touch_max_fps` | `WorldRuntime.LOADING_TOUCH_MAX_FPS` | The same on touch/web — bounded, to avoid cooking a phone through a long load. |

> **The old consts still exist, as FALLBACK DEFAULTS ONLY.** Each of the scripts above
> keeps its `const` (documenting the shipped value beside the design rationale, and
> serving as the `Config.get_float` fallback), and outside callers — tests,
> `tools/calibrate_pace_floor.gd` — still name them. Retuning one changes NOTHING on its
> own: the authored value in `game_config.tres` is what the game reads.

## Engine data

`GameConfig` no longer owns an engine preset system — it has no
`ENGINE_PRESETS` array and no `engine_type` export. The `engine_*` fields
(`engine_cylinders`, `engine_firing_angles`, `redline_rpm`, `peak_torque`,
`peak_torque_rpm`, `engine_inertia`, `engine_low_octave_mix`,
`engine_volume_db`, `engine_noise_level`, `engine_soft_clip_post_gain`) are
just live fields with neutral defaults; the real catalog of engines now lives
in `scripts/engine_library.gd` (`class_name EngineLibrary`), one entry per
real powerplant keyed by a stable string `id`. Each `CarLibrary` car
references exactly one engine by that id (`"engine": "<engine_id>"`), and
`car.gd`'s `apply_car()` resolves it (`EngineLibrary.by_id`) and writes the
whole profile onto the fielded `GameConfig` via `EngineLibrary.apply()` — the
only writer of these fields. See
[engine-and-transmission.md](engine-and-transmission.md) and
[engine-audio.md](engine-audio.md).

## Derived-value helpers

- `axle_stiffness(front)` → `suspension_stiffness × 2 × axle_weight_fraction` (front/rear rate split by `weight_front`; ×2 keeps the two-axle mean at the base rate)
- `axle_travel(front)` → the front/rear travel override, or `suspension_travel` when the override is 0
- `suspension_damping_compression(rate)` → √rate (critically damped; defaults to `suspension_stiffness`)
- `suspension_damping_relaxation(rate)` → 1.5× compression (stiffer rebound)
- `engine_firing_phases()` → firing angles normalized to 0..1 crank cycle
- `terrain_layers()` → `[Vector2(wavelength, amplitude), ...]`

## Current overrides in `game_config.tres`

The committed `.tres` differs from script defaults in places, e.g.
`auto_gearbox = true`, `drag_coefficient = 2.645`, `steer_speed = 2.0`,
`engine_nitrous_hiss_gain = 0.25`, `upshift_redline_fraction = 0.7`. Check the file
for the authoritative values.
