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
| `downforce_front` / `downforce_rear` | 0.0 | N per (m/s)² at each axle; negative = lift (range -2.0–2.0). Set **per-car** by `apply_car` from the CarLibrary spec (these defaults are just the fallback); every car has a small rear value |
| `steer_limit` | 0.3 rad | Max steer angle from travel direction |
| `steer_speed` | 5.0 | Steering responsiveness (rad/s) |
| `steer_travel_alignment` | 1.0 | Auto-countersteer fraction (0..1) |
| `steer_assist_torque` | 200.0 | Yaw torque vs understeer (N·m) |
| `steer_assist_min_speed` | 8.333 | Min speed (m/s ≈30 km/h) before steer assist applies |
| `level_assist_torque` | 8000.0 | Self-righting roll+pitch torque while airborne (N·m at 90° tilt); 0 disables |
| `wheel_roll_influence` | 0.1 | Height tire forces act at (0..1): body roll (lateral) + pitch dive/squat (longitudinal); 0 = CoM, 1 = contact patch |
| `wheel_friction_slip_front` | 0.8 | Front tire grip coefficient μ |
| `wheel_friction_slip_rear` | 0.6 | Rear tire grip coefficient μ |
| `suspension_travel` | 0.5 | Spring compression distance (m) |
| `suspension_stiffness` | 10.0 | Spring rate; dampers derived from it |

### Engine & Transmission
| Property | Default | Purpose |
|----------|---------|---------|
| `engine_type` | 0 (i4) | Preset: i4, i5, i6, v6, v8, v10, v12 — setter applies preset |
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
| `engine_low_octave_mix` | 0.0 | Crossfade toward a voice one octave lower (per-car; LFA 0.5) |
| `engine_soft_clip_drive` | 0.6 | Pre-amp into the sine soft clipper (global; higher = more grit) |
| `engine_soft_clip_post_gain` | 1.0 | Post-amp after the soft clipper (global; 1.0 = transparent) |
| `drive_mode` | 0 (RWD) | Initial layout: RWD, AWD, FWD |

### HUD / Camera / World
| Property | Default | Purpose |
|----------|---------|---------|
| `hud_enabled` | true | Show speed/gear overlay |
| `mobile_controls_force` | false | Force on-screen touch controls on (testing; otherwise auto-enabled on touch devices) |
| `tilt_sensitivity` | 2.0 | TILT scheme: multiplier on device roll → steer (higher = full lock at a gentler tilt) |
| `tilt_deadzone` | 0.05 | TILT scheme: device roll (fraction of 1 g) ignored around level |
| `follow_distance` | 6.0 | Chase camera distance behind (m) |
| `follow_height` | 3.0 | Chase camera height above (m) |
| `smoothing` | 5.0 | Camera follow smoothing rate |
| `fog_density` | 0.02 | Environment fog thickness |
| `background_color` | (0.35,0.3,0.45) | Sky + fog color |

### Stage
| Property | Default | Purpose |
|----------|---------|---------|
| `stage_countdown_seconds` | 3.0 | Countdown before controls unlock at the start of a stage |
| `stage_complete_percent` | 99.0 | Track-progress % (0..100) that ends the stage |
| `hud_elapsed_enabled` | true | Show the top-right run timer |

See [stage.md](stage.md).

### Damage
| Property | Default | Purpose |
|----------|---------|---------|
| `impact_min_speed_kmh` | 10.0 | Impact speed (km/h) below which a hit costs no HP |
| `impact_ref_speed_kmh` | 60.0 | Reference impact speed (km/h) at which a hit costs `impact_ref_hp_loss` |
| `impact_ref_hp_loss` | 200.0 | HP a reference-speed hit costs (square-law in speed); ~200 ⇒ most cars survive 4-5 hits at 60 km/h, barely any at 20 |
| `impact_max_loss_frac` | 0.34 | Cap on one impact's HP loss, as a fraction of max HP (no single crash wrecks) |
| `impact_cooldown_s` | 0.7 | Post-hit window where impacts are ignored (groups a crash into one hit) |
| `damage_power_loss_max` | 0.4 | Fraction of engine power lost at 0 HP |
| `damage_steer_bias_max` | 0.08 | Max wheel-alignment steer pull (rad) at 0 HP |
| `hud_hp_enabled` | true | Show the in-run HP gauge (hidden for the immortal starter) |
| `hud_low_hp_warn_frac` | 0.25 | HP fraction below which the gauge flashes a warning |

Per-car `max_hp` is CarLibrary metadata, not a `GameConfig` field. See
[damage.md](damage.md).

### Terrain Layers
Three (wavelength, amplitude) pairs — `terrain_layerN_wavelength` /
`terrain_layerN_amplitude` for N = 1,2,3 (large hills → fine bumps). See
[terrain.md](terrain.md).

## Engine preset system

`ENGINE_PRESETS` (in `game_config.gd`) is an array of 7 dictionaries (i4, i5,
i6, v6, v8, v10, v12). Each defines `cylinders`, `firing_angles` (crank
degrees), `redline_rpm`, `peak_torque`, `peak_torque_rpm`. Setting `engine_type`
calls `_apply_engine_preset()`, which copies the preset into the engine fields.

## Derived-value helpers

- `suspension_damping_compression()` → √`suspension_stiffness` (critically damped)
- `suspension_damping_relaxation()` → 1.5× compression (stiffer rebound)
- `engine_firing_phases()` → firing angles normalized to 0..1 crank cycle
- `terrain_layers()` → `[Vector2(wavelength, amplitude), ...]`

## Current overrides in `game_config.tres`

The committed `.tres` differs from script defaults in places, e.g. `engine_type
= 1` (i5), `auto_gearbox = true`, `drag_coefficient = 0.3`, `steer_limit = 0.4`,
`upshift_redline_fraction = 0.75`. Check the file for the authoritative values.
