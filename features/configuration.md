# Configuration (`GameConfig`)

All gameplay and look tuning lives in a single resource so it can be changed
without touching code or scenes.

- **Resource file:** `config/game_config.tres`
- **Script / class:** `scripts/game_config.gd` (`class_name GameConfig extends Resource`)
- **Autoload accessor:** `scripts/config.gd` (`Config` singleton) → `Config.data`

```gdscript
# Reading config anywhere:
var cfg := Config.data
body.mass = cfg.mass
```

`config.gd._init()` loads `res://config/game_config.tres`, falling back to a
fresh `GameConfig.new()` if missing. Values are read-only during play; editing
the `.tres` requires a scene reload to take effect.

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
| `steer_limit` | 0.8 rad | Mechanical max steer angle from travel direction (full lock at low speed); at speed the effective cap is bounded by the tire's optimum slip angle (`Car.optimum_steer_limit`), derived from the surface, not a tuned ramp |
| `steer_speed` | 5.0 | Steering responsiveness (rad/s) |
| `steer_travel_alignment` | 1.0 | Auto-countersteer fraction (0..1) |
| `steer_assist_torque` | 0.0 | Yaw torque vs understeer (N·m); scaled at speed by `Car.steer_authority` (cap ÷ `steer_limit`). Authored **per car** in `CarLibrary` (overlaid by `apply_car()`); this global is a 0 fallback |
| `steer_assist_min_speed` | 8.333 | Min speed (m/s ≈30 km/h) before steer assist applies |
| `spin_assist_torque` | 6000.0 | Spin protection: corrective yaw torque (N·m) back toward the travel direction past `spin_assist_angle` of slip; suppressed while the handbrake is held; 0 disables |
| `spin_assist_angle` | 0.611 rad | Slip angle (≈35°) where spin protection starts; ramps to full at twice this angle |
| `level_assist_torque` | 8000.0 | Self-righting roll+pitch torque while airborne (N·m at 90° tilt); 0 disables |
| `wheel_roll_influence` | 0.1 | Height tire forces act at (0..1): body roll (lateral) + pitch dive/squat (longitudinal); 0 = CoM, 1 = contact patch |
| `wheel_friction_slip_front` | 0.8 | Front tire grip coefficient μ |
| `wheel_friction_slip_rear` | 0.6 | Rear tire grip coefficient μ |
| `parking_hold_grip` | 1.0 | Static-friction hold cap (`·m·g`) for a stopped, fully-braked car so it doesn't creep down a slope (`car._apply_parking_hold`); 0 disables |
| `suspension_travel` | 0.5 | Spring compression distance (m) / wheel rest length |
| `suspension_travel_front` | 0.0 | Front travel override; 0 = inherit `suspension_travel` |
| `suspension_travel_rear` | 0.0 | Rear travel override; 0 = inherit `suspension_travel` |
| `suspension_stiffness` | 10.0 | Overall spring rate; split front/rear by `weight_front` (`axle_stiffness`), dampers derived per axle |
| `weight_front` | 0.5 | Static front-axle weight fraction; drives the centre of mass AND the spring-rate split |

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
| `auto_gearbox` | false | Start in auto mode (toggle T) |
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
| `tilt_sensitivity` | 2.0 | TILT scheme: multiplier on device roll → steer (higher = full lock at a gentler tilt) |
| `tilt_deadzone` | 0.05 | TILT scheme: device roll (fraction of 1 g) ignored around level |
| `follow_distance` | 6.0 | Chase camera distance behind (m) |
| `follow_height_ratio` | 1.0 | Chase camera height as a multiple of `follow_distance` |
| `smoothing` | 5.0 | Camera follow smoothing rate |
| `fog_density` | 0.02 | Environment fog thickness |
| `background_color` | (0.35,0.3,0.45) | Sky + fog color |

### Stage
| Property | Default | Purpose |
|----------|---------|---------|
| `stage_countdown_seconds` | 3.0 | Countdown before controls unlock at the start of a stage |
| `stage_complete_percent` | 99.0 | Track-progress % (0..100) that ends the stage |
| `hud_elapsed_enabled` | true | Show the top-right run timer |
| `hud_stage_delta_enabled` | true | Show the in-run "vs P1" pace popup (needs a session P1) |
| `stage_delta_interval_turns` | 5 | Turns between pace popups (every Nth turn) |
| `stage_delta_show_seconds` | 3.0 | How long the pace popup stays before fading |

See [stage.md](stage.md).

### Lap-time model
| Property | Default | Purpose |
|----------|---------|---------|
| `gravel_grip` | 1.0 | Surface grip multiplier for gravel in `LapTimeModel` (`scripts/lap_time_model.gd`); blended with `tarmac_grip` by the event's tarmac fraction to get the effective µ |
| `tarmac_grip` | 1.3 | Surface grip multiplier for tarmac (higher → faster tarmac-heavy events) |
| `driver_factor` | 1.08 | Driver-imperfection multiplier applied to the physics floor from `LapTimeModel`; turns the theoretical optimum into a beatable human PAR |

### Damage
| Property | Default | Purpose |
|----------|---------|---------|
| `impact_threshold_g` | 2.0 | Deceleration (g) a physics tick must exceed before it costs HP — keeps braking/clean landings free; the single sensitivity knob for the unified deceleration-damage model |
| `impact_ref_speed_kmh` | 60.0 | Reference shed-velocity (km/h) at which a hit costs `impact_ref_hp_loss` |
| `impact_ref_hp_loss` | 200.0 | HP a reference hit costs (square-law in shed velocity); a full arrest sheds ≈ the approach speed |
| `impact_max_loss_frac` | 0.34 | Cap on one tick's HP loss, as a fraction of max HP (no single spike wrecks); a stopped car self-limits, a tumble racks up several |
| `damage_misfire_health_threshold` | 0.5 | Health fraction at/above which the engine is fully healthy; misfire ramps in below it |
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
| `recovery_enabled` | true | Master toggle for the stuck watchdog (the lateral off-track reset runs regardless) |
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
| `cliff_amount` | 1.0 | Runtime per-event scale on `cliff_max_height_m` (`[0,1]`); written by `RallySession` from the event's `cliffiness`, else the shipped fallback |

Pushed onto the terrain by `GameConfig.apply_cliffs(tm)` before `set_track` (mirrors
`apply_terrain_light`). `cliff_seed = track_seed`.

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
`auto_gearbox = true`, `drag_coefficient = 2.645`, `steer_limit = 0.5`,
`steer_assist_torque = 5000.0`, `upshift_redline_fraction = 0.7`. Check the file
for the authoritative values.
