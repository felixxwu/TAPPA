class_name GameConfig
extends Resource
# Central tuning knobs for the whole game. Edit config/game_config.tres
# (Inspector or text), not the per-node values in main.tscn — runtime
# config overrides those defaults at startup.

# Engine character, set from the engine_type preset (see ENGINE_PRESETS). These
# are not Inspector sliders: pick the engine via engine_type and the preset
# fills them in. Tests and gameplay read them as ordinary properties.
var engine_cylinders := 4  # firings per cycle = cylinders (4-stroke)
# Crank angles (degrees over the 720° four-stroke cycle) at which cylinders fire.
# Even spacing → smooth; uneven → burble.
var engine_firing_angles: Array[float] = [0.0, 180.0, 360.0, 540.0]
var redline_rpm := 8000.0  # rev limiter; top speed is redline in top gear
var peak_torque := 211.6  # peak crank torque (N·m), reached at peak_torque_rpm
var peak_torque_rpm := 4500.0

# One profile per engine_type, in the same order as the @export_enum below.
# firing: crank angles over the 720° cycle — even spacing sounds smooth, uneven
# burbles. Performance values (redline/torque/rpm) are balanced starting points.
const ENGINE_PRESETS: Array[Dictionary] = [
	{  # i4 — even 180°; preserves the car's original feel
		"cylinders": 4, "firing": [0.0, 180.0, 360.0, 540.0],
		"redline_rpm": 8000.0, "peak_torque": 211.6, "peak_torque_rpm": 4500.0,
	},
	{  # i5 — even 144°; off-beat warble
		"cylinders": 5, "firing": [0.0, 144.0, 288.0, 432.0, 576.0],
		"redline_rpm": 7500.0, "peak_torque": 264.5, "peak_torque_rpm": 4200.0,
	},
	{  # i6 — even 120°; silky smooth
		"cylinders": 6, "firing": [0.0, 120.0, 240.0, 360.0, 480.0, 600.0],
		"redline_rpm": 7500.0, "peak_torque": 317.4, "peak_torque_rpm": 4800.0,
	},
	{  # v6 — uneven (90° bank, shared crankpins); lumpy burble
		"cylinders": 6, "firing": [0.0, 90.0, 240.0, 330.0, 480.0, 570.0],
		"redline_rpm": 7000.0, "peak_torque": 299.8, "peak_torque_rpm": 4000.0,
	},
	{  # v8 — uneven (cross-plane); muscle-car lope
		"cylinders": 8, "firing": [0.0, 80.0, 180.0, 260.0, 360.0, 440.0, 540.0, 620.0],
		"redline_rpm": 7000.0, "peak_torque": 440.8, "peak_torque_rpm": 4200.0,
	},
	{  # v10 — even 72°; high-revving scream
		"cylinders": 10,
		"firing": [0.0, 72.0, 144.0, 216.0, 288.0, 360.0, 432.0, 504.0, 576.0, 648.0],
		"redline_rpm": 8500.0, "peak_torque": 396.8, "peak_torque_rpm": 6000.0,
	},
	{  # v12 — even 60°; smooth and high
		"cylinders": 12,
		"firing": [0.0, 60.0, 120.0, 180.0, 240.0, 300.0,
			360.0, 420.0, 480.0, 540.0, 600.0, 660.0],
		"redline_rpm": 8000.0, "peak_torque": 529.0, "peak_torque_rpm": 5500.0,
	},
]

@export_group("Car")
# Units are real-world SI: mass in kg, torques in N·m, inertias in kg·m². The
# car's handling was originally balanced in an abstract scale (baseline car at
# mass 120); the whole sim was converted to real kg by scaling mass and every
# coupled force/torque/inertia by S = 1058/120 ≈ 8.8167 (the Mazda MX-5's real
# 1058 kg over its old game mass), which preserves accelerations exactly since
# gravity is fixed. Dimensionless values (grip, ratios) and lengths/rpm are
# unchanged. Per-car overrides live in CarLibrary (also in real units).
@export var mass := 1058.0
# Must comfortably exceed the sliding tires' reaction torque (≈ μ·N·r per
# axle, ~150 N·m at μ 0.7) or the wheels can't lock against grippy ground.
@export var brake_torque := 2645.0  # N·m per axle from the foot brake (S)
@export var handbrake_torque := 3527.0  # N·m on the rear axle (Space)
@export var engine_friction_base := 10.0  # N·m always-on crank friction at 0 rpm (FMEP constant term)
@export var engine_friction_slope := 4.0  # N·m of extra crank friction per 1000 rpm (FMEP linear term)
@export var axle_inertia := 2.645  # kg·m² rear axle spin inertia; fronts use half each
@export var drag_coefficient := 3.527  # quadratic aero drag on the chassis
## N of aero downforce per (m/s)² at the FRONT axle, applied downward at the
## axle midpoint. Compresses the suspension so grip rises via normal force.
## 0.2 ≈ half the car's weight at 25 m/s. Negative values produce lift,
## extending the suspension and reducing front grip at speed.
@export_range(-2.0, 2.0) var downforce_front := 0.0
## N of aero downforce per (m/s)² at the REAR axle. Same effect as the front
## value, but biases grip rearward — raise it to settle a loose tail at speed.
## Negative values produce lift, lightening the rear at speed. Set PER-CAR by
## car.gd.apply_car from the CarLibrary spec's `downforce_front`/`downforce_rear`
## (this default is only the fallback when a spec omits them); the aero_kit upgrade
## adds on top of the car's value.
@export_range(-2.0, 2.0) var downforce_rear := 0.0
## Max steering offset (radians) from the car's direction of travel.
@export_range(0.0, 1.2) var steer_limit := 0.3
@export var steer_speed := 5.0
## How much the front wheels caster toward the direction of travel: 1.0 = fully
## track it (automatic countersteer), 0.0 = steering input only.
@export_range(0.0, 1.0) var steer_travel_alignment := 1.0
## Yaw torque (N·m) applied while steering to fight understeer — a steering aid,
## not a physical force.
@export_range(0.0, 10000.0) var steer_assist_torque := 1763.0
## Minimum speed (m/s) before the steer-assist yaw torque kicks in. Below this
## the car is too slow for understeer to matter and the aid only makes low-speed
## handling twitchy, so it is suppressed. 30 km/h ≈ 8.333 m/s.
@export_range(0.0, 50.0) var steer_assist_min_speed := 8.333
## Slip angle (radians) at which the steer-assist yaw torque tapers to zero. The
## assist is full when the car points along its travel direction and fades
## linearly to nothing once the car has rotated this far into the turn, so it
## helps rotate the car in but won't keep over-rotating it into a spin. 30° ≈ 0.524 rad.
@export_range(0.0, 1.571) var steer_assist_max_angle := deg_to_rad(30.0)
## Self-righting assist: when one or more wheels leave the ground, a roll+pitch
## torque (N·m at full 90° tilt) eases the car back toward flat, scaling with how
## far it has tilted. Never yaws the car. 0 disables. A landing/anti-flip aid,
## not a physical force.
@export_range(0.0, 30000.0) var level_assist_torque := 8000.0
## Weight of drive force in the traction ellipse: 0.5 = Godot's solver (tires
## transmit up to 2x more drive than side force), 1.0 = strict circle (drive
## and lateral share one friction budget).
@export_range(0.1, 1.0) var traction_ellipse_ratio := 0.5
## Height where tire forces (both lateral and longitudinal) are applied:
## 0 = at the centre of mass (no body roll from cornering, no pitch dive/squat
## from braking/throttle, rollover-proof), 1 = at the contact patch (full,
## physical roll and pitch).
@export_range(0.0, 1.0) var wheel_roll_influence := 0.1
@export var wheel_friction_slip_front := 0.8
@export var wheel_friction_slip_rear := 0.6
## Per-surface grip multipliers on the base tire μ. Gravel is the standard 1.0
## (the generated road's default surface); grass (off the road) is lower and
## tarmac higher. A wheel's multiplier is resolved from the terrain at its
## contact point (TerrainManager.surface_grip_at) and blends smoothly across the
## same feathered bands the road colour uses — grass↔road and gravel↔tarmac.
@export_range(0.1, 2.0) var grass_grip := 0.7
@export_range(0.1, 2.0) var gravel_grip := 1.0
@export_range(0.1, 2.0) var tarmac_grip := 1.3
@export var tire_slip_peak := 1.5
## Grip retained when a tire is fully sliding, as a fraction of peak μN. The
## tire force falls from full grip at tire_slip_peak down to this when locked.
@export_range(0.1, 1.0) var sliding_grip_ratio := 0.7
@export var suspension_travel := 0.5  # also used as the wheel rest length (ray length)
## Spring rate of the suspension. Dampers are derived from this (see functions
## below), not configured separately.
@export_range(0.1, 50.0) var suspension_stiffness := 10.0
# Dampers are derived from stiffness (see functions below), not configured.
@export var wheel_radius := 0.35
## Extra height (m) the car is lifted to on spawn, reset and car swaps, above
## its authored start position — keeps the wheels from clipping under the
## terrain when it drops in, especially on a slope or after resizing the car.
@export var spawn_clearance := 2.5

@export_group("Tuning")
# Free, reversible per-car tuning (features/tuning.md). Each OwnedCar stores three
# normalized sliders in [-1, +1] (grip_balance / brake_bias / aero_balance);
# TuningLibrary.apply re-balances the live config from these, scaled by the
# authority knobs below so a slider can never zero or invert a value. The lift
# UI (hq.gd) drives the sliders; gating (aero/brake) comes from installed upgrades.
## Front share of the foot-brake torque (the new front/rear split drivetrain.gd
## applies). 0.5 = today's equal split; the brake_bias slider moves it around 0.5.
@export_range(0.0, 1.0) var brake_bias := 0.5
## Max fraction of grip shifted front<->rear at slider |1| (grip_balance).
@export_range(0.0, 1.0) var tuning_grip_authority := 0.15
## Half-span of brake_bias the slider can move from 0.5 (brake_bias, gated by the
## brakes upgrade) — e.g. 0.3 lets the slider reach brake_bias in [0.2, 0.8].
@export_range(0.0, 0.5) var tuning_brake_authority := 0.3
## Max fraction of downforce shifted front<->rear at slider |1| (aero_balance,
## gated by the aero upgrade).
@export_range(0.0, 1.0) var tuning_aero_authority := 0.5

@export_group("Engine & Transmission")
## Engine type. Selecting a preset drives the whole engine character — cylinder
## count and firing angles (the sound) plus redline, peak torque and the rpm it
## peaks at (the performance). Even-firing presets (i4/i5/i6/v10/v12) sound
## smooth; the uneven v6/v8 burble. The values it sets live in ENGINE_PRESETS.
@export_enum("i4", "i5", "i6", "v6", "v8", "v10", "v12") var engine_type := 0:
	set(value):
		engine_type = value
		_apply_engine_preset()
@export var idle_rpm := 900.0  # the no-stall floor: omega never drops below this
## Bouncing rev limiter width (rpm): fuel cuts at redline and only restores once
## the revs fall this far below it, so they oscillate across the band — an
## audible bounce off the limiter rather than a silent pin.
@export_range(10.0, 1500.0) var rev_limiter_band := 100.0
@export var engine_inertia := 0.0882  # kg·m² flywheel; small = fast revving
@export var gear_ratios: Array[float] = [6.0, 4.0, 2.9, 2.2, 1.2]
@export var reverse_ratio := 6.0
@export var final_drive := 4.0
@export var clutch_max_torque := 2204.0  # N·m the clutch can hold before slipping
# Below this wheel surface speed (m/s) the auto-clutch opens when coasting,
# so the engine idling never creeps the car.
@export var clutch_engage_speed := 4.0
@export var shift_time := 0.25  # seconds of open clutch + throttle cut per shift
@export var auto_gearbox := false  # start in automatic mode (toggle in-game with T)
## Automatic-mode upshift point, as a fraction of redline. Each gear upshifts at
## the ground speed where it reaches this fraction of redline rpm. Must stay
## below the steady-state ground/redline ratio (~0.94 here) or the car never
## reaches the point and sticks in gear. 0.90 lands the next gear near peak torque.
@export_range(0.5, 0.95) var upshift_redline_fraction := 0.90
## Downshift dead band: thresholds sit this fraction below each upshift point,
## preventing the gearbox from hunting between gears.
@export_range(0.0, 1.0) var shift_hysteresis := 0.15
# --- Engine audio ---
## Master level of the engine voice, in decibels. Per-car, set from CarLibrary's
## volume_db; this value is the fallback default for cars that omit the key.
@export var engine_volume_db := -6.0
## Audible floor of the engine voice at zero throttle (0 = silent at idle).
@export_range(0.0, 1.0) var engine_idle_gain := 0.25
## Richness of each firing pulse — more harmonics = brighter, harsher engine note.
@export_range(1, 8) var engine_harmonics := 4
## Amount of broadband noise mixed into the engine voice (0 = pure tone).
@export_range(0.0, 1.0) var engine_noise_level := 0.15
## Crossfade toward a second engine voice one octave lower (half the firing
## frequency). 0 = the normal voice only, 0.5 = a 50/50 blend, 1 = fully the
## low octave. Per-car, set from CarLibrary's low_octave_mix to deepen engines
## whose synthesized note sits too high.
@export_range(0.0, 1.0) var engine_low_octave_mix := 0.0
## One-pole rate the synth tracks rpm/throttle at. Higher = snappier, so the
## rev-limiter bounce and throttle stabs come through; lower = smoother glide.
## Effective low-pass cutoff ≈ rate / 2π (so 200 ≈ 32 Hz). Very high ≈ no smoothing.
@export_range(10.0, 2000.0) var engine_smoothing_rate := 200.0
## How far the firing voice ducks while the rev limiter has fuel cut (no
## combustion): 1 = no change, 0 = silent. The engine still spins, so mechanical
## noise and crackle carry through — this only mutes the combustion pulses. The
## sim bounces the cut on/off at the limit (~a couple Hz), so this produces the
## audible warble of a soft bounce limiter. Tracked on a fast envelope so the
## bounce stays crisp regardless of engine_smoothing_rate.
@export_range(0.0, 1.0) var engine_limiter_cut_level := 0.18
## Amplitude of the exhaust-crackle burst fired each time the limiter cuts fuel
## (unburnt fuel popping in the exhaust on overrun). 0 = no crackle. Added as a
## short decaying noise burst on top of the engine voice.
@export_range(0.0, 1.0) var engine_limiter_crackle := 0.5
## Pre-amp into the sine soft clipper that shapes the combined engine signal
## (voice + noise + crackle). Low-level gain through the curve ≈ (π/2)·drive;
## higher = more low-level boost and harder peak rounding (more grit). Must be
## > 0. 0.6 ≈ near-unity low level with gentle peak rounding.
@export_range(0.05, 100.0) var engine_soft_clip_drive := 0.6
## Global post-amp applied after the soft clipper, before the final clamp. Sets
## output level independently of the drive amount. 1.0 = transparent; > 1 is
## caught by the clamp backstop.
@export_range(0.0, 4.0) var engine_soft_clip_post_gain := 1.0
@export_enum("RWD", "AWD", "FWD") var drive_mode := 0  # initial layout (cycle in-game with Y)
# AWD uses a fully locked centre diff (front + rear share one driveline speed),
# so there is no torque-split knob.

@export_group("HUD")
@export var hud_enabled := true  # on-screen speed readout

@export_group("Stage")
## Countdown length, in seconds, before the car's controls unlock at the start
## of a stage. The car holds position (handbrake forced) until it elapses.
@export var stage_countdown_seconds := 3.0
## Track-progress percentage (0..100) that ends the stage. Below 100 because
## progress is monotonic and the on-road snap means _best_offset can approach but
## not exactly reach the baked length — see todo/stage-start-and-end.md §1.
@export_range(0.0, 100.0) var stage_complete_percent := 99.0
## Show the top-right elapsed-time readout during the run (mirrors hud_enabled).
@export var hud_elapsed_enabled := true

@export_group("Start Line")
## The pre-event start-line sequence (todo/menus.md location 2): on track load the
## "time to beat" is shown while an orbit camera circles the car queued between a
## leader and a trailing car; on launch the leader drives off and the field scoots
## up, then the screen fades to black and back to the chase camera + driving UI as
## the countdown starts. Only runs inside an active RallySession; a plain dev boot
## of main.tscn skips straight to the countdown. Off restores that old behaviour.
@export var start_line_enabled := true
## Orbit camera angular speed (rad/s) around the car during the start reveal.
@export var start_orbit_speed := 0.5
## Orbit camera radius (m) out from the car.
@export var start_orbit_radius := 7.0
## Orbit camera height (m) above the car it looks at.
@export var start_orbit_height := 2.4
## Gap (m) between queued cars along the start heading (leader ahead, one behind).
@export var start_queue_gap := 7.0
## Safety cap (s) on the launch animation: the fade-to-black normally waits for the
## player to roll up and come to a COMPLETE stop, but won't wait longer than this.
@export var start_drive_off_seconds := 3.5
## Seconds a rolling-up car holds throttle before easing off (< the drive-off
## length, so it settles under the parking brake). Applies to the player + trailer.
@export var start_trailer_scoot_seconds := 0.7
## Stagger (s) between successive cars launching, so the queue rolls off one after
## another (leader, then player, then trailer) rather than all at once.
@export var start_queue_stagger_seconds := 0.35
## Seconds each half (out, then back) of the fade-to-black transition takes.
@export var start_fade_seconds := 0.6
## Straight road (m) forced AHEAD of the start line on a staged run, so the leader
## has road to drive off down (the queue cars are axis-locked to a straight line).
@export var start_lead_in_ahead_m := 22.0
## Straight road (m) extended BEHIND the start line on a staged run, so the player
## (staged half a gap back) and the trailing car behind it sit on road.
@export var start_lead_in_behind_m := 16.0

@export_group("Damage")
# Per-car HP attrition (features/damage.md). Max HP is CarLibrary metadata
# (mass-keyed), NOT here; these are the global magnitudes that govern how impacts
# drain it and how a damaged car degrades. Tuning numbers are placeholders to be
# settled by playtest — this fixes the mechanism, not the values.
# Damage is keyed to the SPEED the car was travelling at when it hit something:
# nothing at a crawl, then a square-law (kinetic-energy) climb so a moderate-speed
# crash hurts far more than a low-speed nudge. See DamageModel.hp_loss_for_speed.
## Impact speed (km/h) below which a hit costs no HP — at a crawl the car just
## leans on obstacles, so low-speed bumps and parking nudges never chip it.
@export_range(0.0, 60.0) var impact_min_speed_kmh := 10.0
## Reference impact speed (km/h) at which a hit costs impact_ref_hp_loss. HP loss
## grows with the SQUARE of speed (kinetic energy) from impact_min_speed_kmh up to
## here, so a 20 km/h tap barely scratches while a moderate crash bites.
@export_range(1.0, 200.0) var impact_ref_speed_kmh := 60.0
## HP a reference-speed (impact_ref_speed_kmh) hit costs. With per-car max HP of
## ~800-1100, ~200 means most cars survive 4-5 such moderate hits; the square law
## then makes a 20 km/h hit cost only a small fraction of this (barely any damage).
@export_range(0.0, 2000.0) var impact_ref_hp_loss := 200.0
## Cap on the HP a SINGLE impact can cost, as a fraction of max HP — so no one
## high-speed crash can wreck the car outright (it still survives a couple).
@export_range(0.0, 1.0) var impact_max_loss_frac := 0.34
## After a damaging hit, ignore further impacts for this long (s). The window re-arms
## on each continuing obstacle contact, so it only starts counting down once the car
## breaks free — a sustained crash (pinned against / grinding through obstacles for
## seconds) stays ONE hit, not 30 per tick nor a fresh hit every cooldown.
@export_range(0.0, 5.0) var impact_cooldown_s := 0.7
## Fraction of engine power lost at 0 HP (caps the power-loss effect). The driven
## torque is scaled by 1 - d * this, where d is the damage fraction.
@export_range(0.0, 1.0) var damage_power_loss_max := 0.4
## Max wheel-alignment steer bias (radians, same unit as steer_limit) at 0 HP —
## the car pulls to one side as it takes damage. Direction is re-rolled per run.
@export_range(0.0, 0.5) var damage_steer_bias_max := 0.08
## Show the in-run HP gauge (mirrors hud_enabled). Hidden for the immortal starter.
@export var hud_hp_enabled := true
## HP fraction below which the gauge flashes a low-HP warning.
@export_range(0.0, 1.0) var hud_low_hp_warn_frac := 0.25
## When the fielded car is wrecked mid-event the crash plays out, then an orbit
## camera + "car wrecked" menu appears (scripts/wreck_screen.gd, reusing the
## start-line orbit knobs). This caps how long (s) we wait for the wreck to settle
## before showing the menu, in case the car never fully comes to rest.
@export_range(0.0, 10.0) var wreck_settle_max_seconds := 4.0

@export_group("Mobile")
# On-screen touch controls (steer left / steer right / throttle / brake).
# Shown automatically on touch devices (DisplayServer.is_touchscreen_available()).
# Set this true to force them on for testing on a desktop/in the editor. Which of
# the six control schemes is shown is a per-player setting chosen on the title
# screen's Settings page (persisted in the save profile, not here).
@export var mobile_controls_force := false
## Tilt-steering sensitivity (TILT scheme): multiplier on the device roll. 1.0 maps
## a full 90° tilt to full lock; higher reaches full lock at a gentler tilt.
@export_range(0.5, 5.0) var tilt_sensitivity := 2.0
## Tilt-steering deadzone: device roll (as a fraction of 1 g) ignored around level,
## so a phone held roughly flat doesn't drift the steering.
@export_range(0.0, 0.9) var tilt_deadzone := 0.05

@export_group("Debug")
@export var debug_wheel_forces := false  # per-wheel arrows (toggle with H): green = suspension, red = friction, blue = aero downforce
## Length of the debug force arrows, in metres drawn per newton of force.
@export_range(0.00001, 0.01) var debug_force_arrow_scale := 0.00025

@export_group("Camera")
@export var follow_distance := 6.0
@export var follow_height := 3.0
@export var smoothing := 5.0
## Bonnet (hood) camera local offset on the car. Front of the car is -Z, so a
## negative Z sits the camera over the bonnet; +Y raises it to eye height.
@export var bonnet_offset := Vector3(0.0, 0.7, -0.6)
## Field of view (degrees) for the bonnet camera.
@export_range(30.0, 120.0) var bonnet_fov := 75.0

@export_group("Menu / HQ")
## Seconds the HQ menu camera takes to ease into framing the focused car
## (todo/diegetic-hq.md). 0 snaps instantly.
@export var menu_camera_move_time := 0.6
## HQ menu camera position relative to the focused car (car space: -Z is the car's
## nose), so the default sits the camera ahead-and-to-the-side at eye height for a
## 3/4 hero shot.
@export var menu_camera_offset := Vector3(3.2, 1.6, 4.8)
## Height (m) above the car's origin that the HQ menu camera looks at.
@export var menu_camera_look_height := 0.6
## Spacing (m) between parked cars in the HQ car-park lineup (along the lot's X).
@export var menu_car_spacing := 6.0
## Height (m) above the lot the parked cars drop from, so they settle onto their
## suspension under physics before being frozen at the settled pose.
@export var menu_car_drop_height := 0.6
## Seconds the parked cars run live physics to settle before they're frozen (so a
## full car park costs nothing to keep parked once settled).
@export var menu_car_settle_seconds := 1.2
## Maximum number of cars the player may own. Winning a rally still grants the car
## even when the garage is full; the next HQ visit then makes the player scrap one
## (the just-won car included) back down to this cap. See hq.gd's OVERFLOW station.
@export var max_owned_cars := 10
## Car-park lineup placement. The lineup is pushed this far off the lot centre (m,
## along +X) and each car is yawed 90° so its flank faces the garage and its nose
## points at the now-open centre courtyard; the row itself recedes along Z
## (menu_car_spacing apart). The exterior/title camera is shifted by the same
## offset so it still frames the lineup at the same 45°-ish angle.
@export var menu_car_park_offset := 8.0

# --- Podium / reward-reveal sequence (podium.gd) ------------------------------
## Height (m) above each podium step the top-3 cars drop from, so they settle onto
## their suspension under physics (the "suspension simulated and loaded" beat).
@export var podium_car_drop_height := 0.7
## Seconds the podium cars run live physics to settle before being frozen.
@export var podium_car_settle_seconds := 1.4
## Height (m) of the 1st-place podium step; 2nd/3rd are scaled down from it.
@export var podium_step_height := 0.9
## Spacing (m) between the three podium steps (along X). The winner is centred.
@export var podium_step_spacing := 3.6
## Seconds the slot-machine reveal (car / upgrade) spins before locking onto the
## won item. The Continue button is hidden until it finishes. 0 = instant.
@export var podium_slot_spin_time := 2.2
## Degrees/second the won car rotates on the showroom turntable in the reveal.
@export var podium_showroom_spin_dps := 32.0

# --- Diegetic HQ: one 3D space the camera flies through (todo/diegetic-hq.md).
# Camera "stations" are an eye position + a look target (world space); the camera
# tweens between them over menu_camera_move_time. The exterior is the boot/title
# shot (block buildings + the car park); Start flies into the garage (the map table
# + the tuning lift); tapping the table drops to a near-top-down view of the 3D map.
## Exterior/title camera: eye, then look target.
@export var hq_exterior_cam_eye := Vector3(0.0, 13.0, 58.0)
@export var hq_exterior_cam_look := Vector3(0.0, 2.5, 26.0)
## Garage interior camera (sees the map table + tuning lift).
@export var hq_garage_cam_eye := Vector3(0.0, 4.6, 13.0)
@export var hq_garage_cam_look := Vector3(0.0, 1.1, 0.0)
## Map-table camera: a steep, near-top-down look down onto the table's 3D map, close
## in so the map fills the screen; drag to pan across it (clamped to the map extents).
## (Keep a small Z offset between eye and look so looking_at doesn't go degenerate at
## a perfectly vertical angle.)
@export var hq_table_cam_eye := Vector3(-3.0, 2.6, 0.4)
@export var hq_table_cam_look := Vector3(-3.0, 0.95, -0.3)
## Map-table pan speed: world metres per screen pixel of drag.
@export var hq_table_pan_speed := 0.012
## Where the car-park lineup sits (outside, in front of the garage). Cars row along X.
@export var hq_carpark_origin := Vector3(0.0, 0.0, 26.0)
## Garage interior footprint (m): floor X/Z extent; walls + roof are built from it.
@export var hq_garage_size := Vector2(14.0, 12.0)
## Grey concrete apron under the garage + car park: centre (XZ) and size (X, Z). Laid
## over the grass-textured ground so the lot reads as paved and the rest as field.
@export var hq_concrete_center := Vector3(0.0, 0.0, 13.0)
@export var hq_concrete_size := Vector2(48.0, 44.0)
## Map table: centre position, block size, and the 3D map plane laid on its top.
@export var hq_table_pos := Vector3(-3.0, 0.0, -0.2)
@export var hq_table_size := Vector3(4.6, 0.9, 3.4)
@export var hq_map_plane_size := Vector2(4.2, 3.0)
## Tuning lift: centre position + platform size.
@export var hq_lift_pos := Vector3(4.0, 0.0, -1.0)
@export var hq_lift_size := Vector3(3.0, 0.35, 3.0)
## Height (m) the selected car is raised to on the lift (wheels hanging, as on a
## real ramp). Above the platform top.
@export var hq_lift_car_height := 1.3
## Height (m) above the platform top the car rests at when LOWERED — its pose in
## the garage view (on the ground). The lift animates between this and
## hq_lift_car_height when the bay is entered/left.
@export var hq_lift_car_lowered_height := 0.4
## Seconds the lift takes to raise/lower the car (the slow ramp animation). 0 snaps.
@export var hq_lift_raise_time := 1.6
## Tuning-lift camera: frames the raised car off to one side so the tuning menu
## (anchored to the other side of the screen, hq.gd) doesn't cover the car. eye,
## then look target — the look is offset toward +X of the car so it sits LEFT of
## frame, leaving the right side clear for the menu panel.
@export var hq_lift_cam_eye := Vector3(2.6, 2.2, 6.0)
@export var hq_lift_cam_look := Vector3(5.2, 1.3, -1.0)
## Fraction of the screen width the tuning menu panel occupies (anchored right).
@export_range(0.25, 0.6) var hq_lift_menu_width_frac := 0.42

@export_group("World")
## Exponential distance fog. Demoted from "opaque wall hiding the ~75 m terrain
## edge" to thin aerial haze now that DistantTerrain provides a far horizon — low
## enough to see the distant hills + skybox. See todo/distant-terrain-and-sky.md.
@export var fog_density := 0.005
## How much the fog tints the sky (Environment.fog_sky_affect). Low so the skybox
## reads clearly above the haze.
@export_range(0.0, 1.0) var fog_sky_affect := 0.15
## Fog / backdrop colour. Matched to the skybox's HORIZON (sampled from
## textures/sky_field.png) so the distant terrain dissolves into the field seam.
@export var background_color := Color(0.482, 0.498, 0.403)
## Coarse far-terrain backdrop (DistantTerrain) that gives the sky a horizon past
## the detailed chunk ring. Disable to fall back to fog-only edge hiding.
@export var distant_terrain_enabled := true
## Half-extent of the backdrop square (m) — how far the visible terrain reaches.
@export_range(50.0, 1000.0) var distant_terrain_radius_m := 250.0
## Backdrop grid spacing (m). Coarse is fine at distance; smaller = finer hills, more verts.
@export_range(2.0, 40.0) var distant_terrain_cell_m := 10.0
## Depth (m) the whole coarse backdrop is sunk below true terrain height, so the
## detailed chunk ring always sits above it and the coarse mesh never pokes
## through. No holes are cut in the backdrop (it underlaps the detail ring
## entirely); at distance the slight step at the ring edge is imperceptible.
@export_range(0.0, 5.0) var distant_terrain_sink_m := 1.5
@export var terrain_tile_per_meter := 0.125  # ground texture tiles per metre, baked into terrain UVs
## Gravel/road texture tiles per metre. Independent of the ground tiling so the
## road can be finer or coarser than the surrounding grass.
@export_range(0.05, 4.0) var road_tile_per_meter := 0.5

@export_group("Terrain Layers")
# Three stacked perlin noise layers: wavelength in metres, amplitude in metres.
## Layer 1 wavelength (m): spacing of the largest, rolling hills.
@export_range(1.0, 1000.0) var terrain_layer1_wavelength := 66.784
## Layer 1 amplitude (m): height of the largest, rolling hills.
@export_range(0.0, 100.0) var terrain_layer1_amplitude := 10.0
## Layer 2 wavelength (m): spacing of the mid-scale undulations.
@export_range(1.0, 200.0) var terrain_layer2_wavelength := 15.0
## Layer 2 amplitude (m): height of the mid-scale undulations.
@export_range(0.0, 10.0) var terrain_layer2_amplitude := 1.382
## Layer 3 wavelength (m): spacing of the finest surface bumps.
@export_range(1.0, 200.0) var terrain_layer3_wavelength := 3.0
## Layer 3 amplitude (m): height of the finest surface bumps.
@export_range(0.0, 10.0) var terrain_layer3_amplitude := 0.18

@export_group("PS1 Look")
@export var virtual_resolution := Vector2(480, 360)  # keep matching [display] in project.godot
@export var chassis_color := Color(0.85, 0.2, 0.15)
@export var cabin_color := Color(0.25, 0.3, 0.4)
@export var wheel_color := Color(0.12, 0.12, 0.12)
@export var wheel_spoke_color := Color(0.85, 0.85, 0.78)

@export_group("Lighting")
# Fake hemisphere-ambient + single-directional-sun shading (no light nodes, no
# shadows, no extra render pass — see features/rendering.md). The CAR computes
# it per-vertex in shaders/ps1_models_lit.gdshader (it rotates, so its lit side
# changes each frame). The TERRAIN, which never moves under a sun that never
# moves, bakes the identical math into its vertex colours ONCE at generation
# time (terrain_manager._bake_light) — zero per-frame cost. Both share the sun
# direction and colours below; each has its own amount.
## 0 = flat (unlit), 1 = full shading. Strength on the car.
@export_range(0.0, 1.0) var car_light_amount := 1.0
## 0 = flat (unlit), 1 = full shading. Strength baked into the terrain.
@export_range(0.0, 1.0) var terrain_light_amount := 1.0
## World-space direction TO the sun (need not be normalised; normalised on use).
## ALIGNED TO THE SKYBOX: panoramas are pre-rolled (tools/align_sky_sun.py) so the
## sun sits at the image centre, which is +Z in Godot's panorama mapping (verified
## in-engine) — hence the azimuth here is always +Z (x≈0, z>0); only the elevation
## (y/z split) tracks the sky's sun height. Matches textures/sky_field.png's low sun.
@export var sun_direction := Vector3(0.0, 0.184, 0.983)
## Directional "sun" contribution added on lit-facing surfaces.
@export var sun_color := Color(0.5, 0.5, 0.5)
## Ambient colour on upward-facing surfaces (sky).
@export var sky_color := Color(0.5, 0.5, 0.5)
## Ambient colour on downward-facing surfaces (ground bounce).
@export var ground_color := Color(0.35, 0.35, 0.35)

@export_group("Track")
## Total width of the generated track, in metres; cells within half this
## distance of the centerline are coloured as track.
@export var track_width := 6.0
## Extra separation, in metres, required between non-adjacent track sections.
## Only inflates the collision footprint used by the generator's overlap test —
## the visible track stays `track_width` wide. Larger values stop the track from
## looping back and running alongside itself too closely.
@export_range(0.0, 30.0) var track_clearance := 8.0
## Seed for the deterministic track search.
@export var track_seed := 1
## Number of corners chained into the track.
@export var track_turn_count := 15
## How forested this track is, in [0, 1] — the fraction of area covered by trees.
## Trees only spawn where the forest noise (forest_wavelength_m) exceeds
## (1 - track_forestiness): 0 = bare, 1 = trees everywhere. Set per rally event by
## RallyLibrary.event_forestiness; the default (1.0) keeps free-roam fully wooded.
## Bushes ignore this (they scatter everywhere).
@export_range(0.0, 1.0) var track_forestiness := 1.0
## Wavelength, in metres, of the Perlin noise that breaks the trees into forest
## patches (larger = bigger, smoother stands of forest separated by clearings).
@export_range(10.0, 2000.0) var forest_wavelength_m := 300.0
## Width, in 0.5 m cells, of the smooth transition band just outside the road
## edge where height and colour blend from the flat road to the true terrain.
@export var track_transition_cells := 3
## Fraction of this track surfaced as tarmac, in [0, 1]; the rest is gravel. The
## track switches surface exactly ONCE along its length (gravel→tarmac or
## tarmac→gravel, picked deterministically from track_seed), so this also fixes
## where the switch sits. 0 = all gravel, 1 = all tarmac. Set per rally event by
## RallyLibrary.event_tarmac_fraction; the default (0) keeps free-roam all gravel.
@export_range(0.0, 1.0) var track_tarmac_fraction := 0.0
## Length, in metres ALONG the track, of the smooth feather where the surface
## switches between gravel and tarmac — the lengthwise analogue of the
## perpendicular grass↔road band (track_transition_cells). Both the road colour
## and the per-wheel grip cross-fade over this band.
@export_range(0.0, 40.0) var track_surface_transition_m := 6.0
## Solid fill colour for tarmac sections. TODO: replace with a proper tarmac
## texture (see todo/tarmac-texture.md) — for now a flat grey under the same
## baked terrain lighting as the rest of the floor.
@export var tarmac_color := Color(0.32, 0.32, 0.34)
## Lateral distance from the road centerline, in metres, within which track
## progress accrues; straying beyond it triggers the off-track reset. Generous on
## purpose — you can run wide onto the verge / cut across rough ground (rally!)
## before being snapped back. The distance is measured against a LOCAL window of
## the centerline (TrackProgress._local_closest_offset), so this is independent of
## `track_clearance` and won't snap onto a different track section.
@export var track_progress_max_dist_m := 25.0
## Master switch for the off-track auto-reset. Progress tracking (for the HUD)
## runs regardless; this only gates the snap-back-onto-road behaviour.
@export var off_track_reset_enabled := true

@export_group("Tire Marks")
## Gravel ruts laid behind the wheels while driving on the road (features/tire-marks.md).
@export var tire_marks_enabled := true
## Gravel rut colour — a solid, constant shade noticeably darker than the gravel
## (gravel.jpg averages ~0.42 grey), so the ruts read as dug-in. Unshaded, so tune
## against the lit road in-game.
@export var tire_mark_color := Color(0.24, 0.23, 0.21)
## Tarmac skidmark colour — a dark grey scuff laid only where a driven wheel spins
## on the tarmac (the gravel ruts use tire_mark_color instead).
@export var tire_mark_tarmac_color := Color(0.16, 0.16, 0.16)
## Width of a wheel's mark ribbon, in metres (roughly a tyre's width).
@export var tire_mark_width_m := 0.22
## Don't lay marks below this car speed (m/s) — keeps the countdown/parked car clean.
@export var tire_mark_min_speed_mps := 2.0
## Distance the wheel must travel before a new ribbon segment is added, in metres.
@export var tire_mark_segment_step_m := 0.5
## Max segments retained per wheel (ring buffer); older marks recycle. ~100 m at
## the default step — bounds memory, and the chase cam looks forward anyway.
@export var tire_mark_max_segments := 200
## Height the ribbon sits above the wheel's contact patch, in metres (lifts it
## clear of the road surface so it never z-fights or clips under the terrain).
@export var tire_mark_ground_offset_m := 0.15
## Extra lateral allowance beyond the road half-width within which marks still lay
## (so the verge of the gravel still marks), in metres.
@export var tire_mark_gravel_margin_m := 0.3


@export_group("Wheel Particles")
## Cheap gravel spray flung from the driven wheels when they spin faster than the
## ground (features/wheel-dust.md). One MultiMesh of billboarded quads.
@export var wheel_particles_enabled := true
## Clod colour — matched to the gravel road (gravel.jpg averages ~0.42 grey).
## Unshaded, so tune it against the lit road in-game.
@export var wheel_particle_color := Color(0.42, 0.40, 0.36)
## Hard cap on live particles (the ring-buffer size + MultiMesh instance count).
## Oldest clods are recycled first, so memory and draw cost are bounded.
@export_range(16, 2000) var wheel_particle_max := 50
## Edge length of each square clod billboard, in metres.
@export var wheel_particle_size_m := 0.12
## Minimum wheelspin (tread speed minus ground speed along the roll direction, m/s)
## before any dirt is thrown — keeps a cleanly-rolling wheel from spraying.
@export var wheel_particle_min_slip_mps := 1.5
## How long each clod lives before it recycles, in seconds.
@export var wheel_particle_lifetime_s := 1.1
## Throw speed as a fraction of the wheel's surface speed (omega x radius). 1.0
## flings clods backward as fast as the tread spins; lower keeps the spray tighter.
@export_range(0.0, 2.0) var wheel_particle_speed_scale := 0.4
## Extra upward launch speed added to every clod, in m/s — angles the spray up.
@export var wheel_particle_up_speed_mps := 2.2
## Downward gravity applied to each clod, in m/s^2 (sells the weight of the dirt).
@export var wheel_particle_gravity_mps2 := 12.0
## Linear air drag per second (fraction of speed bled off each second) — a slight
## value so fast clods decelerate a touch in flight rather than flying dead straight.
@export_range(0.0, 5.0) var wheel_particle_air_resistance := 0.6
## Clods spawned per emitting wheel per physics tick while it spins.
@export_range(1, 20) var wheel_particle_spawn_count := 3
## Random spread of the throw, as a fraction of the throw speed — widens the spray
## cone (and grows with how hard the wheel is spinning).
@export_range(0.0, 1.0) var wheel_particle_spread := 0.35


@export_group("Trees")
## Billboard tree sprites scattered around each track turn.
## Target tree count per turn — drives the scatter grid's density (the actual count is
## approximate, since foliage sits on a global jittered grid). 0 disables trees AND
## bushes (they share these params).
@export_range(0, 500) var trees_per_turn := 12
## Radius, in metres, of the disc around each turn anchor that trees spawn in.
@export_range(1.0, 100.0) var tree_spawn_radius_m := 25.0
## Extra gap, in metres, kept between a tree and the visible road edge. Trees
## are rejected on the road footprint inflated by this margin, so larger values
## push the nearest trees further back from the track.
@export_range(0.0, 20.0) var tree_road_margin_m := 1.0
## How far each tree wanders from its grid-cell centre, as a fraction of the cell
## (0 = a rigid lattice, 1 = anywhere in the cell). Spacing is inherent: two trees are
## never closer than (1 - tree_jitter) x cell, so lower values look more regular.
@export_range(0.0, 1.0) var tree_jitter := 0.6
## Billboard size in metres: width (x) by height (y). Pivot is the bottom edge.
@export var tree_size_m := Vector2(4.0, 6.0)
## Half-extent (m) in X/Z of each tree's box hitbox — a square trunk footprint.
@export_range(0.05, 5.0) var tree_collision_radius_m := 0.5
## Height (m) of each tree's box hitbox.
@export_range(0.5, 20.0) var tree_collision_height_m := 4.0
## Distance (m) past which trees are fully culled. Defaults near the loaded
## terrain extent (RADIUS=1, CHUNK_M=50 -> ~75 m).
@export_range(10.0, 500.0) var tree_render_distance_m := 80.0
## Width (m) of the dithered dissolve band just before the render cutoff.
@export_range(0.0, 100.0) var tree_render_fade_m := 15.0
## Billboard size (m) for bushes: width (x) by height (y). Bushes are smaller
## than trees; everything else about their scatter/render matches the trees.
@export var bush_size_m := Vector2(1.0, 1.5)
## Distance (m) bushes are sunk into the ground, hiding the gap at the bottom of
## the bush texture.
@export_range(0.0, 5.0) var bush_sink_m := 0.5


@export_group("Roadside Signs")
# A-frame (wet-floor) roadside signs along the stage: sector boards, turn arrows,
# and start/finish banners (todo/roadside-signs.md). Few per stage (tens), so they
# are individual nodes, not a MultiMesh. Authored face textures go in sign_textures;
# until they exist, a per-kind colour fallback keeps the geometry testable.
## Number of equal arc-length sectors the stage is split into. Signs mark
## entering sectors 2..N (sector 1 is the start gate).
@export_range(1, 12) var sign_sector_count := 4
## One A-frame panel's width (x) by height (y), in metres — thin near-square boards.
@export var sign_panel_size_m := Vector2(1.2, 1.2)
## Panel thickness, in metres.
@export_range(0.005, 0.5) var sign_thickness_m := 0.05
## Half-angle, in degrees, each panel tilts from vertical to form the A-frame splay.
@export_range(0.0, 60.0) var sign_splay_deg := 20.0
## How far inside the visible road edge the sign base sits, in metres — keeps the
## footprint on the flat road surface rather than the sloped verge.
@export_range(0.0, 3.0) var sign_edge_inset_m := 0.3
## Collision/footprint depth along the road, in metres.
@export_range(0.1, 3.0) var sign_base_depth_m := 0.8
## Mass (kg) of a sign's knock-over body. Light so the car scatters it freely.
## Signs deal no HP damage — they are cosmetic clutter, not obstacles.
@export_range(0.1, 50.0) var sign_mass_kg := 3.0
## Map of texture_key (e.g. "sector_2", "arrow_square_left") → res://textures/signs/*.png.
## Empty leaves every sign on its per-kind colour fallback.
@export var sign_textures: Dictionary = {}

@export_group("Finish Arch")
# The inflatable rally finish gate straddling the road at the stage end
# (features/finish-arch.md). One per stage, placed by world.gd at the centerline's
# end and aligned with the finish sign pair.
## Whether to build the finish arch at the end of the stage.
@export var finish_arch_enabled := true
## Clear gap, in metres, between each road edge and the inside face of a leg.
## The arch's opening = track_width + 2 x this, so the legs stand clear of the
## road and the car drives through cleanly.
@export_range(0.0, 6.0) var finish_arch_road_margin_m := 1.5


@export_group("Performance")
## Render frame cap (FPS). The game is inherently low-end and ships one lean
## value; a steady cap avoids thermal throttling on phones. 0 = uncapped (desktop
## dev). Physics runs independently at the project physics tick.
@export_range(0, 240) var target_fps := 60
## Texture LOD bias for the foliage/ground shaders: positive values pull distant
## sampling toward cheaper (lower) mip levels, saving texture bandwidth on
## tile-based mobile GPUs. Keep modest so the alpha-cutout silhouettes don't blur.
@export_range(0.0, 4.0) var texture_lod_bias := 0.75


func _init() -> void:
	# Populate the engine-character fields before the resource loader assigns
	# engine_type (which re-applies via its setter). Keeps GameConfig.new() sane.
	_apply_engine_preset()


# Copy the selected engine_type's profile into the character fields.
func _apply_engine_preset() -> void:
	var preset: Dictionary = ENGINE_PRESETS[clampi(engine_type, 0, ENGINE_PRESETS.size() - 1)]
	engine_cylinders = preset["cylinders"]
	var firing: Array[float] = []
	for angle in preset["firing"]:
		firing.append(angle)
	engine_firing_angles = firing
	redline_rpm = preset["redline_rpm"]
	peak_torque = preset["peak_torque"]
	peak_torque_rpm = preset["peak_torque_rpm"]


# Critically damped for the spring rate. Godot scales each wheel's
# mass-normalized spring/damper by the full chassis mass, so with 4 wheels the
# bounce mode is x'' + 4c x' + 4k x = 0 and per-wheel critical damping is
# sqrt(stiffness), not the textbook 2 * sqrt(stiffness).
func suspension_damping_compression() -> float:
	return sqrt(suspension_stiffness)


# Rebound damper runs 1.5x the compression value for stability.
func suspension_damping_relaxation() -> float:
	return 1.5 * suspension_damping_compression()


# Firing angles normalized to the 0..1 crank cycle (720° four-stroke). When
# engine_firing_angles is empty, derive even spacing from engine_cylinders so
# the simple case needs no explicit table.
func engine_firing_phases() -> Array[float]:
	var out: Array[float] = []
	if engine_firing_angles.is_empty():
		var n: int = maxi(engine_cylinders, 1)
		for i in range(n):
			out.append(float(i) / float(n))
		return out
	for angle in engine_firing_angles:
		out.append(fposmod(angle / 720.0, 1.0))
	return out


# The terrain layers as (wavelength, amplitude) pairs, for terrain generation.
func terrain_layers() -> Array[Vector2]:
	return [
		Vector2(terrain_layer1_wavelength, terrain_layer1_amplitude),
		Vector2(terrain_layer2_wavelength, terrain_layer2_amplitude),
		Vector2(terrain_layer3_wavelength, terrain_layer3_amplitude),
	]


# Push the fake car-lighting uniforms onto a ps1_models.gdshader material. Used
# for every lit car mesh (chassis/cabin/wheels in world.gd, the MX-5 body in
# car.gd) so the light parameters live in one place. Terrain materials are never
# passed here, so they keep the shader's default light_amount of 0 (flat).
func apply_car_light(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("light_amount", car_light_amount)
	mat.set_shader_parameter("light_dir", sun_direction)
	mat.set_shader_parameter("sun_color", sun_color)
	mat.set_shader_parameter("sky_color", sky_color)
	mat.set_shader_parameter("ground_color", ground_color)


# Push the shared sun/ambient values + the terrain amount onto a TerrainManager,
# which bakes them into vertex colours when chunks generate. Call BEFORE the
# initial terrain build so the shading is baked into the first chunks.
func apply_terrain_light(tm: TerrainManager) -> void:
	tm.light_amount = terrain_light_amount
	tm.sun_dir = sun_direction.normalized()
	tm.sun_color = sun_color
	tm.sky_color = sky_color
	tm.ground_color = ground_color


# The scalar tree-scatter knobs packed into the Dictionary TreeScatter.scatter
# expects. tree_size_m is rendering-only and passed separately to BillboardField.
func tree_params() -> Dictionary:
	return {
		"trees_per_turn": trees_per_turn,
		"spawn_radius_m": tree_spawn_radius_m,
		"jitter": tree_jitter,
	}


# Layout inputs for SignLayout.plan (todo/roadside-signs.md §2): what to place.
func sign_params() -> Dictionary:
	return {
		"sector_count": sign_sector_count,
	}


# Render/build inputs for SignField.build (§3): how each placed sign looks and
# where it sits relative to the road edge.
func sign_render_params() -> Dictionary:
	return {
		"panel_size_m": sign_panel_size_m,
		"thickness_m": sign_thickness_m,
		"splay_deg": sign_splay_deg,
		"edge_inset_m": sign_edge_inset_m,
		"base_depth_m": sign_base_depth_m,
		"mass_kg": sign_mass_kg,
		"textures": sign_textures,
		"track_width": track_width,
	}
