class_name GameConfig
extends Resource
# Docs: features/car-performance.md, features/configuration.md, features/forced-induction.md, features/signs.md, features/tuning.md, features/world-panel.md — update in the same change as this file.
# Tests: tests/headless/test_config_applied.gd, tests/headless/test_config_isolation.gd, tests/headless/test_car_performance.gd — extend in the same change. (Nearly every headless test reads this file; those three are the ones that cover it AS config. For a specific knob, the owning area's doc above names its own tests.)
# Central tuning knobs for the whole game. Edit config/game_config.tres
# (Inspector or text), not the per-node values in main.tscn — runtime
# config overrides those defaults at startup.
#
# THE LITERALS IN THIS FILE ARE FALLBACK DEFAULTS, NOT THE TUNING SURFACE. To change a
# gameplay value, author it in config/game_config.tres; editing the literal here is only
# correct when the .tres does not author that property, and you cannot tell which from
# this file — a .tres stores ONLY non-default values, so a property absent from it is
# live at the literal below and a property present in it silently wins over the literal.
#   To check before you edit:  grep '<property_name>' config/game_config.tres
#   Hit   -> edit the .tres; your change here would be dead on arrival.
#   Miss  -> the literal is live, but add it to the .tres so the value is authored where
#            every other tuned value lives.
# Some properties are overwritten a THIRD way, per-car or per-engine, from the authored
# tables in CarLibrary / EngineLibrary / UpgradeLibrary; those carry a FALLBACK ONLY note
# on their own line. Read it before assuming an edit here reaches the game.

# Engine character. These are the LIVE engine fields: EngineLibrary.apply()
# (scripts/engine_library.gd) writes them from the fielded car's referenced
# engine. Their initializers below are only the neutral default for an unfielded
# GameConfig. Tests and gameplay read them as ordinary properties.
var engine_cylinders := 4  # firings per cycle = cylinders (4-stroke)
# Crank angles (degrees over the 720° four-stroke cycle) at which cylinders fire.
# Even spacing → smooth; uneven → burble.
var engine_firing_angles: Array[float] = [0.0, 180.0, 360.0, 540.0]
var redline_rpm := 8000.0  # rev limiter; top speed is redline in top gear
var peak_torque := 211.6  # peak crank torque (N·m), reached at peak_torque_rpm
var peak_torque_rpm := 4500.0

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
@export var brake_torque := 1500.0  # N·m per axle from the foot brake (S)
@export var handbrake_torque := 5000.0  # N·m on the rear axle (Space)
## FALLBACK ONLY — CHANGING THIS NUMBER DOES NOTHING ONCE A CAR IS FIELDED.
## EngineLibrary.apply overwrites engine_friction_base per-engine from the authored
## ENGINES table (scaled ~cylinder count), so this default only covers the baseline car
## before any engine is seated. To make engine braking stronger across the board, move
## engine_friction_slope below (which nothing overwrites) or retune the ENGINES table.
@export var engine_friction_base := 20.0  # N·m always-on crank friction at 0 rpm (FMEP constant term)
## The other half of the FMEP model, and the one that IS globally live. Engine braking on
## a lift-off is friction = engine_friction_base + engine_friction_slope * rpm/1000, so at
## a typical 4000 rpm the slope contributes 4x its value against a base of 20-60 N·m —
## a change worth feeling is a multiple, not a few percent.
@export var engine_friction_slope := 1.0  # N·m of extra crank friction per 1000 rpm (FMEP linear term)
## ADDING OR RETUNING AN ENGINE-BRAKING KNOB IS A THREE-PART CHANGE. Part 3 is the one every
## attempt so far has skipped, so it carries its own paste-able skeleton below.
##   1. the knob — an `@export` here (never a literal in engine.gd/car.gd). Read
##      `is_lifting_off()`'s comment in engine.gd FIRST: it is true while BRAKING, so gating
##      drag on it also changes wheel lock-up.
##   2. the docs — `features/engine-and-transmission.md` (the FMEP model and its "Related
##      config" list) AND `features/car-physics.md` (which narrates what slows the car).
##      Two docs describe this and only one is usually updated.
##   3. A BEHAVIOURAL TEST in `tests/headless/test_car.gd`. Legal and easy: assert the
##      DIRECTION, never the chosen number — pinning the value is banned (CLAUDE.md), which
##      is why "no test is possible here" is wrong rather than merely lazy. Paste this and
##      edit the two marked lines:
##
##        func test_stronger_engine_braking_slows_a_coasting_car_more() -> void:
##            var decel_at := func(gain: float) -> float:
##                Config.data.engine_friction_lift_off_gain = gain   # EDIT: your knob's name
##                var car := _spawn_car()                            # EDIT: this file's helper
##                _settle(car)
##                car.throttle_input = 0.0
##                var v0: float = car.linear_velocity.length()
##                for _i in 60:
##                    _step(car)
##                return v0 - car.linear_velocity.length()
##            var weak := float(decel_at.call(1.0))
##            var strong := float(decel_at.call(2.0))
##            assert_gt(strong, weak,
##                "raising the lift-off gain must slow a coasting car more")
##            Config.reset()   # a non-authored baseline must not leak into the next test
##
##      Then run it: `./run_tests.sh --fast test_car test_drivetrain` — test_drivetrain is
##      what catches the braking side effect part 1 warns about.
@export var axle_inertia := 2.645  # kg·m² rear axle spin inertia; fronts use half each
@export var drag_coefficient := 3.527  # quadratic aero drag on the chassis
## Fraction of the chassis WIDTH cut off each of the four vertical corners of the
## collision hull, chamfering the box into an elongated octagon (top-down). The
## cut is applied as an equal ABSOLUTE inset on both the width (X) and length (Z)
## at every corner, so the corner is 45° and the nose/tail read as a regular
## octagon — 1/3 leaves a flat front edge one-third of the car's width. 0 = a
## plain box. Only affects obstacle contacts + damage impulses (the wheels are
## independent raycasts), so it changes how the car clips scenery, not its grip
## or speed. Clamped in car.gd so every face keeps a positive flat edge.
@export_range(0.0, 0.5) var hitbox_chamfer_fraction := 1.0 / 3.0
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
## MECHANICAL max steering offset (radians) — the wheel's physical stop, and now the only
## bound on the wheel angle. The grip servo (Car._update_steering) finds the peak-grip angle
## by MEASURING the front tires rather than predicting a cap, so there is no longer a
## slip-derived limit or a low-speed blend to configure.
@export_range(0.0, 1.2) var steer_limit := 1.0
## How fast the front wheels can turn (rad/s) — the model of how fast a hand can turn the
## wheel, and the ONLY rate in the steering system (it is also the input smoothing; there is
## no separate easing stage). The grip servo needs to cover only the tire's slip angle
## (~8.6° on tarmac) rather than most of full lock, so this is the dominant feel parameter
## and is tuned much lower than a lock-to-lock rate would be.
@export var steer_speed := 5.0
## Steering demand below which the wheels servo to their zero-lateral-slip angle (pointing
## along their own travel — automatic countersteer). A deadzone rather than an exact-zero
## test because analogue sticks and the touch slider never return exactly 0.
@export_range(0.0, 0.5) var steer_deadzone := 0.02
## Spin protection: corrective yaw torque (N·m) that pulls the nose back toward
## the direction of travel once the car has rotated further than
## spin_assist_angle into a slide. The one remaining steering aid, and it solves what
## the grip servo cannot: a player who holds steering INTO a slide until the car
## rotates past recovery. Includes yaw-rate damping so it settles the slide
## rather than oscillating. Suppressed while the handbrake is held so
## deliberate drifts stay possible. 0 disables. An anti-spin aid, not a
## physical force.
@export_range(0.0, 30000.0) var spin_assist_torque := 0.0
## Slip angle (radians) where spin protection starts. The torque ramps in
## linearly from 0 at this angle to full strength at twice it. Keep it above the
## surface's optimum slip angle (asin(slip_peak), ≈8–18°) so the two aids never
## fight over the same slide. 35° ≈ 0.611 rad.
@export_range(0.0, 3.0) var spin_assist_angle := deg_to_rad(50.0)
## Self-righting assist: when one or more wheels leave the ground, a roll+pitch
## torque (N·m at full 90° tilt) eases the car back toward flat, scaling with how
## far it has tilted. Never yaws the car. 0 disables. A landing/anti-flip aid,
## not a physical force.
@export_range(0.0, 30000.0) var level_assist_torque := 0.0
## Fraction of level_assist_torque the aid keeps while ALL FOUR wheels are
## planted, where it acts as a cheap anti-roll bar: it resists body roll in
## corners and dive/squat under braking, and settles the chassis flat ON THE
## SURFACE (the aid references the average wheel contact normal when grounded,
## not world up, so it never fights a cambered or off-camber road). 0 = the
## classic airborne-only behaviour.
@export_range(0.0, 1.0) var level_assist_grounded := 0.0
## Weight of drive force in the traction ellipse: 0.5 = Godot's solver (tires
## transmit up to 2x more drive than side force), 1.0 = strict circle (drive
## and lateral share one friction budget).
@export_range(0.1, 1.0) var traction_ellipse_ratio := 0.5
## Height where tire forces (both lateral and longitudinal) are applied:
## 0 = at the centre of mass (no body roll from cornering, no pitch dive/squat
## from braking/throttle, rollover-proof), 1 = at the contact patch (full,
## physical roll and pitch).
@export_range(0.0, 1.0) var wheel_roll_influence := 0.1
## Centre-of-mass height (m) relative to the car body's origin — negative lowers it.
## The body origin sits high (settled_ride_height = wheel_radius + axle_travel -
## mount_y, ~1 m drooped with the shipped long-travel suspension), so leaving the CoM
## there puts it far above a real car's ~0.5 m CoG. Since the roll lever a tyre force
## gets is the vertical CoM-to-contact-patch distance (drivetrain.gd, scaled by
## wheel_roll_influence), a too-high CoM drops the static rollover threshold
## track / (2 x CoG height) below the ~1 g the tyres can make, and the car tips
## instead of sliding. Lowering it here restores the real ~1.4 g margin WITHOUT
## faking the lever via wheel_roll_influence. Global (all cars); a per-car CarLibrary
## field would be the next step if tall vans should roll more than low coupes.
@export_range(-1.0, 0.0) var com_height := -0.25
## Runtime per-axle tyre μ. apply_car() seeds BOTH from the car's single
## tire_compound (same rubber front and rear); the grip_balance tuning slider
## (TuningLibrary) then shifts them apart to trim handling. The drivetrain scales
## these by the surface multiplier AND the load-sensitivity factor (see
## tire_load_factor) to get each wheel's live μ.
@export var wheel_friction_slip_front := 0.8
@export var wheel_friction_slip_rear := 0.6
## Tyre section width (m) per axle; apply_car() copies these from the CarLibrary
## spec's wheel_width_front / wheel_width_rear. Used BOTH to size the wheel meshes
## (car.gd) and to feed tire_load_factor: a wider tyre spreads the axle load over
## more contact patch, so it holds more grip under the same weight.
@export var wheel_width_front := 0.225
@export var wheel_width_rear := 0.225
## Tyre load sensitivity: a real tyre's μ drops as the vertical load pressed through
## its contact patch rises. tire_load_factor models this as (ref_pressure / actual)^k,
## where pressure ~ load / width. k (this) keeps it gentle — real tyres vary only a few
## percent; 0 disables the effect entirely (μ = compound regardless of load/width).
@export_range(0.0, 0.5) var tire_load_sensitivity := 0.12
## Reference contact pressure (N per m of tyre width) at which the load factor is 1.0.
## Calibrated so a mid-pack car sits at ~1.0; heavier-per-width tyres fall below, lighter
## or wider rise above.
@export var tire_ref_pressure := 14000.0
## Per-surface grip multipliers on the base tire μ. Gravel is the standard 1.0
## (the generated road's default surface); grass (off the road) is lower and
## tarmac higher. A wheel's multiplier is resolved from the terrain at its
## contact point (TerrainManager.surface_grip_at) and blends smoothly across the
## same feathered bands the road colour uses — grass↔road and gravel↔tarmac.
@export_range(0.1, 2.0) var grass_grip := 0.7
@export_range(0.1, 2.0) var gravel_grip := 1.0
@export_range(0.1, 2.0) var tarmac_grip := 1.3
## SNOW REGION (features/snow-region.md). A region may override the three μ scales
## above for every stage tagged to it — the first case of a region influencing
## HANDLING rather than only look. The region names these fields (it never authors
## numbers), exactly as a WeatherLibrary condition does, so all tuning stays here.
##
## RegionLibrary.surface_grip_of resolves them; RallySession.apply_event_config seats
## them onto grass_grip/gravel_grip/tarmac_grip for the stage. Every other region
## leaves those at the authored baseline above, so this is an exact no-op elsewhere.
##
## LapTimeModel._surface_grip reads the same live fields, so the AI field scales with
## the player automatically: snow is a VARIETY lever, not a difficulty one (like rain
## and sandstorm, unlike fog). CarPerformance is unaffected — it benchmarks at a
## frozen BENCHMARK_SURFACE_GRIP, so ratings and the matched field cannot drift.
##
## Keep the grass < gravel < tarmac ordering; snow drops all three well below home.
@export_range(0.1, 2.0) var snow_grass_grip := 0.30
@export_range(0.1, 2.0) var snow_gravel_grip := 0.55
@export_range(0.1, 2.0) var snow_tarmac_grip := 0.70
## SURFACE-DEPENDENT TYRE COMPOUND (features/drivetrain-and-tires.md). Every other
## tyre effect is a flat multiplier on μ; these two are the SPECIALISED half of the
## snow compound — a bonus on snow ground and a penalty on tarmac, so the part is a
## trade-off rather than a strictly-weaker rung of the same ladder.
##
## LIVE fields, not authoring knobs: car.gd::_apply_physics_spec re-seeds both to 1.0
## with the axle μ (pipeline step 1) and UpgradeLibrary.apply multiplies the fitted
## part's figures in (step 2). 1.0 on a car with no such tyre fitted, which makes the
## whole mechanism an exact no-op for every other compound. The authored numbers live
## on the part in UpgradeLibrary.UPGRADES, like every other effect.
##
## TO ADD AN AXIS (wet, gravel, ice, …): add an @export here AND a row in
## TIRE_SURFACE_AXES right below AND its arm in _channel_weight. Those three edits sit
## within twenty lines of each other, and they are the whole job for any axis keyed on
## something fill_tire_context already carries — the contact's tarmac weight, whether the
## region is snowy, or the stage weather. No consumer file changes for those.
## An axis keyed on anything ELSE also needs that value added to fill_tire_context and to
## its two fill sites; read the honest limit written on that function before you start.
## An @export with no row applies as a permanent 1.0 (the part reads as fitted and does
## nothing); tests/headless/test_tire_surface_axes.gd fails on exactly that.
@export var tire_snow_grip_mult := 1.0
@export var tire_tarmac_grip_mult := 1.0
## THE REGISTRY of surface-dependent tyre axes — the one place that knows which
## per-surface multipliers exist. Every consumer derives from this table rather than
## naming the fields: tire_surface_mult_for() below (the live physics via
## Drivetrain._surface_at and the AI field via LapTimeModel._surface_grip),
## car.gd::_apply_physics_spec's neutral re-seed, and
## car_performance.gd::merged_meta's carry list. That is why adding an axis touches
## no file but this one.
##   field   — the GameConfig property holding the live multiplier
##   channel — which surface channel feathers it; the blend rule lives in
##             _channel_weight, next to this table
## Guarded BOTH WAYS by tests/headless/test_tire_surface_axes.gd: a row naming a
## property that does not exist, and an export with no row, both fail there.
const TIRE_SURFACE_AXES: Array[Dictionary] = [
	{"field": "tire_snow_grip_mult", "channel": "snow"},
	{"field": "tire_tarmac_grip_mult", "channel": "tarmac"},
]
## REGISTERING AN AXIS HERE DOES NOT REGISTER THE EFFECT. The three edits in this file (the
## @export, the row above, the _channel_weight arm) make the axis exist and blend. They do NOT
## let an upgrade author it: a part's `effect` key is looked up in UpgradeLibrary.EFFECTS, and a
## key with no row there is dropped silently — the part reads as fitted and does nothing. So a new
## tyre axis is FOUR edits, three here and one in upgrade_library.gd. Round 041 of the
## small-model-readiness loop shipped a wet-weather tyre with all three of these correct and no
## rain grip at all, five test files green. Guarded by test_upgrade_library.gd ->
## test_every_authored_effect_key_is_registered_in_the_effects_table.
## Deep snow at the roadside — the snow equivalent of grass. Two effects doing two
## different jobs: the low grip above makes the car SLIDE, this makes it BOG.
## Neither alone reads as deep snow.
##
## Linear drag coefficient applied to the chassis while off-road, feathered by the
## same road weight the visual raise uses so the bog appears exactly where the snow
## is drawn. Player-only: no drag term exists in the lap-time model (a rival never
## drives off the road), so this is a small residual difficulty edge on top of the
## scaled grip — the same asymmetry storm's crosswind has, and deliberate.
@export_range(0.0, 400.0) var snow_deep_drag := 90.0
## Metres the VISUAL ground is drawn above the collision surface off-road, so the car
## visibly sinks in. Collision is untouched, so the wheels rest at true ground level.
## Applied in ps1_models.gdshader's vertex stage against the baked road weight, so the
## road itself is never raised and the existing feather turns the step into a bank.
@export_range(0.0, 2.0) var snow_visual_depth_m := 0.35
## LIVE per-stage values, seated by RallySession.apply_event_config from the driven
## region (0.0 for every region that authors no deep snow). Never author these — they
## are the deep-snow counterpart to `weather`, written by the funnel and read by
## car.gd (drag) and world.gd (the shader uniform).
@export var deep_snow_drag := 0.0
@export var deep_snow_depth_m := 0.0
## FROZEN LAKES (features/snow-region.md). In the Alps the water is ice: the lake plane
## becomes SOLID and is driven on, rather than being the soft drag hazard it is
## everywhere else. Authored values, named by the region like the grip block above.
##
## Tyre μ on the ice. An OVERRIDE, not a multiplier — what is under the ice does not
## matter, so this replaces the surface blend rather than scaling it. Well below even
## snow's grass value: sliding is the whole point of a frozen lake.
@export_range(0.02, 1.0) var ice_grip := 0.12
## The frozen lake's surface colours, replacing water_color / water_shore_color. Pale
## and cold; the shore colour is what reads as the ice thinning at the bank.
@export var ice_color := Color(0.80, 0.86, 0.90)
@export var ice_shore_color := Color(0.88, 0.92, 0.95)
## LIVE per-stage: the ice μ, or 0.0 when this stage's water is liquid. Seated by
## RallySession.apply_event_config from the driven region. 0.0 is the "not frozen"
## sentinel and is what every non-Alps stage runs, so the lake stays a soft hazard
## everywhere it always was.
@export var frozen_water_grip := 0.0
## ADAPTIVE DIFFICULTY (features/adaptive-difficulty.md). The field is drawn matched to
## the player's rating; these steer it AWAY from that match based on results — harder when
## the player keeps winning stages, easier when they keep losing them.
##
## The lever is deliberately the opponents' MACHINERY rather than their pace: a rival in a
## quicker car has a genuinely lower optimum, so the ghost can still represent its time.
## Scaling pace instead would need rivals to beat their own physics optimum, which the
## ghost cannot show.
##
## Turning ai_adapt_enabled off restores the pre-adaptive behaviour exactly — as does an
## offset of 0, which is where every career starts.
@export var ai_adapt_enabled := true
## One step, as a fraction of the player's rating. 0.04 => each step moves the field the
## opponents are drawn from by 4%.
@export_range(0.005, 0.25) var ai_adapt_step_fraction := 0.04
## Consecutive stages (won, or not won) needed to push PAST a matched field. One rally is
## three stages, so 3 means a clean sweep or a clean loss is what commits to a handicap.
## Coming BACK toward matched always takes a single result, never this many.
@export_range(1, 10) var ai_adapt_stages_per_step := 3
## Caps, separate per direction because the car roster is not symmetric around the player:
## there is far more of it below a mid-pack car than above a quick one, so the easy side is
## fully reachable while the hard side is limited by what can actually be fielded.
## Placeholders — set these from real play (design D4).
@export_range(0, 12) var ai_adapt_max_ease_steps := 5
@export_range(0, 12) var ai_adapt_max_hard_steps := 5
## How tightly the AI field is matched to the player's CarPerformance rating, in
## rating points. Rivals are drawn with a weight of exp(-|their rating - yours| /
## this), so it is a BIAS, not a filter: a mismatched car stays possible, just
## unlikely, and a rally whose categorical restriction admits only a handful of
## cars still fields a full grid.
##
## Smaller = a tighter, more evenly-matched grid. Larger = a more ragged field with
## clearer front-runners and backmarkers. Zero would make the draw degenerate, so it
## is floored. See features/car-performance.md.
@export_range(5.0, 400.0) var opponent_rating_match_spread := 60.0
## Geometry of the CarPerformance benchmark track (scripts/benchmark_track.gd) —
## a straight, then a hairpin, then N sweepers, scored on the TOTAL time only.
## See docs/superpowers/specs/2026-08-15-car-performance-rating-design.md.
##
## benchmark_straight_m is the PRIMARY balance lever: it shifts the rating between
## rewarding power and rewarding cornering. Shorten it if the rating is found to
## favour straight-line speed. benchmark_sweeper_radius_m is the secondary lever —
## it trades low-speed grip against high-speed aero, since downforce only asserts
## itself above a certain speed.
##
## Changing any of these RE-SCORES EVERY CAR. That is safe for career (nothing is
## persisted) because CarPerformance normalises against a reference car, but see
## features/car-performance.md before moving them.
@export_range(50.0, 2000.0) var benchmark_straight_m := 500.0
@export_range(5.0, 60.0) var benchmark_hairpin_radius_m := 15.0
@export_range(30.0, 400.0) var benchmark_sweeper_radius_m := 90.0
@export_range(1, 8) var benchmark_sweeper_count := 3
## How far apart the performance ratings are SPREAD, without touching the benchmark track.
##
## The raw rating is proportional to average speed — `500 x reference_time / this_time` —
## and lap time is a compressive measure of a car's capability: a hypercar is many times
## the machine a kei van is, but only ~1.5x faster round a lap. So the honest numbers bunch
## up, and the roster reads as flatter than it feels to drive.
##
## This is the exponent on that ratio: `500 x (reference_time / this_time) ^ spread`. 1.0 is
## the raw, physically-proportional number. Above 1.0 stretches the field about the 500
## anchor — a car exactly as fast as the reference still scores 500, a faster car gains more
## and a slower car loses more.
##
## An EXPONENT rather than a linear stretch on purpose: it is multiplicative, so it can
## never drive a slow car to zero or below the way `500 + (raw - 500) * gain` does, and it
## keeps "twice the ratio" meaning the same thing everywhere on the scale.
##
## It cannot separate cars the benchmark finds genuinely equal — differences are amplified
## proportionally, so two cars within 1% of each other stay within `spread`% of each other.
## Widening the WHOLE field is what this does; discriminating between the fast cars is a
## benchmark-geometry question (benchmark_straight_m, above).
##
## Changing this RE-SCORES EVERY CAR, and rating-space values elsewhere — notably
## opponent_rating_match_spread and any authored rating ceiling — are then measured against
## a wider field, so revisit those together.
@export_range(0.5, 4.0) var rating_spread := 1.0
## Corner-exit traction ceiling per drive mode, used by LapTimeModel's forward
## pass (a = min(factor * grip_long, a_engine)). The real Drivetrain couples the
## driveline so AWD spreads drive torque across four contact patches — less slip
## per patch, less wheelspin — while FWD asks the front tyres to steer and drive
## at once. The QSS model has no wheels, so this scalar stands in for that.
##
## The values follow the CONTACT PATCHES. An AWD car drives through all four, so it is
## the 1.0 reference; a 2WD car drives through two and can put down roughly half. The
## 2WD split is asymmetric because acceleration transfers weight REARWARD, loading a
## RWD car's driven axle and unloading a FWD car's — hence RWD 0.6, FWD 0.4.
##
## This ONLY binds where the car is grip-limited. The forward pass takes
## min(factor * grip_long, a_engine), so a power-limited car — most of a long straight —
## is unaffected whatever these are, and every drivetrain times identically there. That
## is the intended shape: drivetrain buys traction, not power.
##
## Setting all three to 1.0 makes the whole term an exact no-op. Changing any of them
## moves every AI, rival and ghost time in the game, so treat it as a roster-wide
## balance change. Indexed by CarLibrary.RWD / AWD / FWD.
@export_range(0.2, 1.0) var traction_factor_rwd := 0.6
@export_range(0.2, 1.0) var traction_factor_awd := 1.0
@export_range(0.2, 1.0) var traction_factor_fwd := 0.4
## The LIVE weather condition for the stage currently being played (RallyLibrary.
## WEATHER_DRY / WEATHER_RAIN). Seated by RallySession.apply_event_config from the
## event's authored `weather` field — the ONE funnel into the live config, so a new
## scene-entry site can't route weather around it. Session-less callers (free roam,
## benchmark, dev boot) reload the authored baseline and stay dry. See features/weather.md.
@export var weather := RallyLibrary.WEATHER_DRY
# The active condition's sun_energy_mult, seated by world.gd::_apply_overcast_look
# each stage boot (and reset to 1.0 there when the condition has no look block).
# NOT exported and NOT authored: it is a derived runtime value, mirroring onto the
# CAR the same dimming the terrain already bakes into its vertex colours, so a
# dimmed stage doesn't leave a full-brightness car floating in it. Read only by
# apply_car_light. Defaults to 1.0 so a session-less boot is unaffected.
var weather_sun_mult := 1.0
## Global tyre μ multiplier applied on top of the surface grip when weather ==
## WEATHER_RAIN (Drivetrain.surface_tire_params). A single multiplier regardless of
## surface — see features/weather.md for the per-surface trade-off this defers.
@export_range(0.1, 1.0) var rain_grip_mult := 0.8
## Slip at which grip peaks, as a NORMALIZED (dimensionless) slip — lateral it is
## sin(slip angle), longitudinal it is the slip ratio Δv/v. 0.15 ≈ sin(8.6°), so
## peak lateral grip lands at ~8.6° of slip angle at ANY speed (a real tyre peaks
## at a roughly constant angle, not a constant slip *speed*). The contact's slip
## velocities are divided by the patch's ground speed (floored by tire_norm_floor)
## before this curve is applied — see Drivetrain._tire_force.
@export var tire_slip_peak := 0.15
## Floor (m/s) on the reference speed used to normalize slip into the grip curve.
## A stationary tyre has no well-defined slip angle, so below this speed the model
## degrades gracefully toward the old slip-velocity behavior instead of dividing
## by ~0. Keep it low enough not to affect cornering feel, high enough to stay
## stable at creep.
@export var tire_norm_floor := 2.5
## Grip retained when a tire is fully sliding, as a fraction of peak μN. The
## tire force falls from full grip at tire_slip_peak down to this when locked.
@export_range(0.1, 1.0) var sliding_grip_ratio := 0.7
## Per-surface OVERRIDES of the two grip-curve shape parameters above. When a
## wheel is on terrain, tire_slip_peak and sliding_grip_ratio are resolved from
## these anchors, blended across the SAME feathered grass↔road / gravel↔tarmac
## bands surface_grip uses for μ (Drivetrain.surface_tire_params). Off terrain
## (flat fixtures) the globals above are the fallback.
## Optimum slip is a NORMALIZED slip (sin of the slip angle, laterally). Rubber
## on hard tarmac peaks at a low angle then drops off sharply (Pacejka-shaped);
## loose gravel/grass shears a wedge of material and peaks at a MUCH larger angle
## with a broad, forgiving plateau past it — which is why rally is driven
## sideways. sin(8°)≈0.14, sin(18°)≈0.31, sin(20°)≈0.34.
@export var tarmac_slip_peak := 0.20
@export var gravel_slip_peak := 0.35
@export var grass_slip_peak := 0.40
## Post-peak grip retention per surface (see sliding_grip_ratio). Tarmac falls
## off; loose surfaces stay near their peak well past it (the plateau).
@export_range(0.1, 1.0) var tarmac_slide_ratio := 0.6
@export_range(0.1, 1.0) var gravel_slide_ratio := 0.85
@export_range(0.1, 1.0) var grass_slide_ratio := 0.82
## Static-friction hold for a nearly-stopped, fully-braked car (handbrake or the
## low-speed parking brake). The tire model's grip fades to zero as slip does, so
## without this a parked car slowly creeps down a slope. Car._apply_parking_hold
## cancels the residual in-plane velocity, clamped to this·m·g — like real stiction,
## it holds any sane grade but a wall-steep slope still slides. ~1.0 ≈ gravel μ.
@export_range(0.0, 2.0) var parking_hold_grip := 1.0
## Stiction spring stiffness (1/s², acceleration per metre of slack) pulling a held car
## back to the spot it stopped on. Sets how much slack a grade buys: offset ≈ g·sinθ / this.
## Must stay well under 1/dt² (~3600) — that is what keeps the hold convergent instead of
## the ringing/vibration the old velocity-cancel hold produced.
@export_range(0.0, 400.0) var parking_hold_stiffness := 300.0
## Damping (1/s) on that stiction spring. ~2·sqrt(stiffness) is critical; the default is
## about 0.6 of critical, enough to settle without stiffening the suspension's own body roll.
@export_range(0.0, 40.0) var parking_hold_damping := 20.0
## Slack (m) the anchor keeps behind the car once the grade beats the stiction cap — the
## car slides, and the anchor follows this far back instead of building unbounded slack
## that would snap the car back when the grade eased.
@export_range(0.0, 1.0) var parking_hold_slack := 0.05
## Speed (m/s) below which a braked, grounded car engages the static parking hold
## (_apply_parking_hold) that cancels residual creep. Above it the car is rolling
## and the hold stays off.
@export var handbrake_lock_speed := 0.5
## Speed (m/s) below which the auto finish-stop releases the foot brake once the car
## has effectively halted at the finish (car.gd _resolve_drive_inputs). Above it the
## brake stays pinned to bring the car to rest.
@export var finish_stop_speed := 0.8
@export var suspension_travel := 0.5  # also used as the wheel rest length (ray length)
## Per-axle spring travel / rest length (m) OVERRIDES. 0 = inherit suspension_travel
## (the common case); a positive value lets a body run a longer front or rear stroke
## (rake / wheel-well fit). apply_car() sets them per car; axle_travel() resolves the
## right one per wheel, falling back to suspension_travel when the override is 0.
@export var suspension_travel_front := 0.0
@export var suspension_travel_rear := 0.0
## Spring rate of the suspension — this is the OVERALL rate; the front/rear rates
## are derived from it by weight_front (see axle_stiffness), so a heavier axle gets
## a proportionally stiffer spring and the car sits level instead of drooping onto
## its heavy end. Dampers are derived from the resolved per-axle rate (see functions
## below), not configured separately.
@export_range(0.1, 50.0) var suspension_stiffness := 10.0
# Dampers are derived from stiffness (see functions below), not configured.
## Static front-axle weight fraction (0..1); apply_car() copies it from the
## CarLibrary spec's weight_front. Drives BOTH the custom centre of mass (car.gd)
## and the front/rear spring-rate split (axle_stiffness). 0.5 = 50/50.
@export_range(0.0, 1.0) var weight_front := 0.5
@export var wheel_radius := 0.35
## Extra height (m) the car is lifted to on spawn, reset and car swaps, above
## its authored start position — keeps the wheels from clipping under the
## terrain when it drops in, especially on a slope or after resizing the car.
@export var spawn_clearance := 2.5
## Reference speed (km/h) grip readouts are rated at — downforce grows with v², so a
## lateral-g figure means nothing without the speed it was measured at. THE SINGLE SOURCE:
## CarStatBounds (the roster-wide bar scale) and any per-car grip readout both
## read this rather than each carrying their own copy, so the bar and the figure it draws
## can never be rated at different speeds.
@export var grip_reference_kmh := 50.0

@export_group("Tuning")
# Free, reversible per-car tuning (features/tuning.md). Each OwnedCar stores three
# normalized sliders in [-1, +1] (grip_balance / brake_bias / aero_balance);
# TuningLibrary.apply re-balances the live config from these, scaled by the
# authority knobs below so a slider can never zero or invert a value. The lift
# UI (hq.gd) drives the sliders; the aero gate comes from the installed aero kit.
## Front share of the foot-brake torque (the front/rear split drivetrain.gd
## applies). 0.5 = equal split. This is only the FALLBACK: CarLibrary.apply_car
## seeds it per-car from each car's authored brake_bias, and the brake-bias slider
## shifts it about that baseline. Used directly only for a car that omits the field.
@export_range(0.0, 1.0) var brake_bias := 0.5
## Max fraction of grip shifted front<->rear at slider |1| (grip_balance).
@export_range(0.0, 1.0) var tuning_grip_authority := 0.3
## Half-span the brake_bias slider can move from the car's default (ungated — brake
## bias is free) — e.g. 0.3 lets a car with a 0.55 default reach [0.25, 0.85].
@export_range(0.0, 0.5) var tuning_brake_authority := 0.3
## Max fraction of downforce shifted front<->rear at slider |1| (aero_balance,
## gated by the aero upgrade).
@export_range(0.0, 1.0) var tuning_aero_authority := 0.5

@export_group("Engine & Transmission")
## Hidden global de-rate applied to EVERY car's drive torque. Multiplies the
## crank torque the engine actually makes (engine.gd), so it scales acceleration
## for all cars at once WITHOUT touching the published peak_torque — the stats
## panel and power-to-weight still report the full, pre-scaling figure. Use it to
## globally dial back pace without re-balancing every car. 1.0 = no scaling.
@export_range(0.1, 1.0) var global_torque_scale := 1.0
@export var idle_rpm := 900.0  # the no-stall floor: omega never drops below this
## Bouncing rev limiter width (rpm): fuel cuts at redline and only restores once
## the revs fall this far below it, so they oscillate across the band — an
## audible bounce off the limiter rather than a silent pin.
@export_range(10.0, 1500.0) var rev_limiter_band := 300.0
@export var engine_inertia := 0.0882  # kg·m² flywheel; small = fast revving
@export var gear_ratios: Array[float] = [6.0, 4.0, 2.9, 2.2, 1.2]
@export var reverse_ratio := 6.0
@export var final_drive := 4.0
@export var clutch_max_torque := 2204.0  # N·m the clutch can hold before slipping
# Below this wheel surface speed (m/s) the auto-clutch opens when coasting,
# so the engine idling never creeps the car.
@export var clutch_engage_speed := 4.0
@export var shift_time := 0.25  # seconds of open clutch + throttle cut per shift
## Default transmission mode: true = automatic. Only the DEFAULT — the player's
## Settings -> Gearbox choice (SettingsMenu.GEARBOX_SETTING_KEY) wins once set, and
## car.gd mirrors it onto the live engine each tick.
@export var auto_gearbox := false
## Automatic-mode upshift point, as a fraction of redline. Each gear upshifts at
## the ground speed where it reaches this fraction of redline rpm. Must stay
## below the steady-state ground/redline ratio (~0.94 here) or the car never
## reaches the point and sticks in gear. 0.90 lands the next gear near peak torque.
@export_range(0.5, 0.95) var upshift_redline_fraction := 0.90
## Downshift dead band: thresholds sit this fraction below each upshift point,
## preventing the gearbox from hunting between gears.
@export_range(0.0, 1.0) var shift_hysteresis := 0.15
# --- Forced induction (features/forced-induction.md) ---
## Whether this engine has a turbocharger fitted (stock or via a turbo upgrade).
## When false the turbo sim is skipped and delivered torque is the NA figure.
@export var turbo_enabled := false
## Rotational inertia of the turbo shaft (kg·m²) — the PHYSICAL source of lag.
## Bigger turbo = larger = spools slower. Must be > 0. Balance placeholder.
@export var turbo_inertia := 1.0e-2
## Shaft speed (rad/s) at which boost reaches its full value (1.0). Larger turbos
## use a higher value (need more speed/flow for full boost), so they come on higher.
@export var turbo_omega_ref := 12000.0
## Torque multiplier at full boost: delivered = na_torque * (1 + boost^response * this).
## "How much extra power". 0 = no boost (NA). Balance placeholder.
@export var turbo_boost_gain := 0.0
## Shaping exponent on boost for the torque delivery ONLY (the HUD gauge + audio still
## read raw boost). 1.0 = linear (spool 50% -> half the gain); >1 delays the power so a
## partially-spooled turbo delivers disproportionately little — lag felt more. Endpoints
## (0 boost, full boost) are unchanged for any response. See features/forced-induction.md.
@export var turbo_boost_response := 1.0
## Constant extra crank friction (N·m) a fitted turbo adds — bigger turbos author more.
## Always-on (NOT boost- or rpm-gated): off boost it just bogs the engine, so a big turbo
## on a small engine (where this is a large fraction of peak torque) really struggles to
## climb the low range; once revs are up the boost torque swamps it. 0 = NA / no penalty.
@export var turbo_parasitic_friction := 0.0
## Couples exhaust flow (∝ throttle * rpm) into shaft drive torque — how hard the
## exhaust spins the wheel up. Balance placeholder (steady-state: drive_gain*throttle*rpm = drag_coef*omega²).
@export var turbo_drive_gain := 0.024
## Bearing/aero drag on the shaft (∝ omega²): sets the steady-state speed for a
## given flow and the off-throttle bleed-down rate. Balance placeholder.
@export var turbo_drag_coef := 1.0e-6
## Anti-lag: keep the shaft spinning off-throttle (instant response) + exhaust bangs.
@export var turbo_antilag := false
## Residual exhaust drive injected off-throttle when anti-lag is on (keeps omega up).
@export var turbo_antilag_drive := 0.0
## Whether this engine has a belt-driven supercharger. Drives the whine audio layer,
## and — when supercharger_boost_gain is > 0 — the belt-drive boost physics below. A
## STOCK supercharged engine leaves the gain at 0 (its power is already baked into the
## authored peak_torque); only the supercharger UPGRADE authors a gain, so the flag on
## its own stays audio-only exactly as before. See features/forced-induction.md.
@export var supercharger_enabled := false
## Torque multiplier at full belt boost: delivered = na_torque * (1 + sc_boost * this).
## 0 = no physics (audio-only / stock blown engine). Balance placeholder.
@export var supercharger_boost_gain := 0.0
## Engine rpm at which belt boost saturates at 1.0. Because the blower is crank-driven,
## boost is LINEAR in rpm with no shaft inertia — full boost arrives the instant the
## revs are there, which is the whole character of a supercharger vs. a turbo.
@export var supercharger_rpm_ref := 4000.0
## Belt drag the blower costs the crank, in N·m per 1000 rpm — unlike a turbo's constant
## backpressure this grows WITH revs (the blower takes more to spin the faster it turns),
## so the top end pays for the instant bottom-end response. 0 = no penalty.
@export var supercharger_parasitic_coef := 0.0


# Forced-induction predicates. These live HERE, next to the fields whose encoding they
# interpret, because more than one layer needs the same answer: EngineSim gates the belt
# sim on the first, and the HUD hides its boost bar on the second. The "a non-zero GAIN,
# not merely the supercharger_enabled flag, is what means real physics" rule is subtle
# (the flag alone is a stock engine's audio-only blower), so it is stated once rather than
# re-derived per caller. See features/forced-induction.md.

## Whether the belt-drive physics are live: a STOCK blown engine sets supercharger_enabled
## for the whine but leaves the gain at 0, so the flag alone must not switch the sim on.
func has_supercharger_physics() -> bool:
	return supercharger_boost_gain > 0.0


## Whether this engine makes boost at all, by either route — the question "is there a
## boost reading worth showing / simulating", not "which part is fitted".
func has_forced_induction() -> bool:
	return turbo_enabled or has_supercharger_physics()


# --- Nitrous ------------------------------------------------------------------
# A per-STAGE resource, not a permanent power level: the tank is refilled to full by
# EngineSim.reset() (so every stage start AND every in-stage reset-to-start begins
# full), and holding the `nitrous` action multiplies delivered crank torque while the
# tank drains. Deliberately NOT part of effective_meta / power-to-weight, so fitting
# nitrous can never move a car's rally eligibility — it makes events easier, it is not
# a stat. See todo/star-gated-special-events.md and features/nitrous.md.

## Extra torque fraction while nitrous is held — delivered torque is multiplied by
## (1.0 + this). 0 = no nitrous fitted. The upgrade ladder raises this ("harder").
@export var nitrous_boost_gain := 0.0

## Seconds of nitrous a full tank holds. The upgrade ladder raises this ("longer").
@export var nitrous_tank_seconds := 0.0

## Whether nitrous is fitted and live. Mirrors has_supercharger_physics: a gain OR a
## tank of zero means nothing to deliver, so both must be positive before the sim, the
## HUD gauge, the audio layer or the mobile button appear.
func has_nitrous() -> bool:
	return nitrous_boost_gain > 0.0 and nitrous_tank_seconds > 0.0
## Seconds the HQ car-lineup preview holds the throttle when a car is highlighted:
## a free-revving (neutral, no-load) EngineSim climbs for this long, then releases
## and falls back to idle so the player hears each car's engine as they flick the
## lineup. See scripts/car_preview_audio.gd + features/engine-audio.md.
@export_range(0.0, 2.0) var preview_rev_hold_seconds := 0.5
# --- Engine audio ---
## Master level of the engine voice, in decibels. Per-car, set from CarLibrary's
## volume_db; this value is the fallback default for cars that omit the key.
@export var engine_volume_db := -6.0
## Global master volume for ALL engine audio, in decibels. Unlike engine_volume_db
## (which is per-car and scales only the cylinder firing voice), this is a single
## project-wide lever applied to the FINAL mixed engine signal — the firing voice,
## broadband noise, exhaust crackle, turbo whistle/air-rush, supercharger whine,
## blow-off vent, and anti-lag bangs all pass through it. Set to 0 dB for no change,
## negative to attenuate everything, -80 to effectively mute. Not per-car.
@export var engine_master_volume_db := 0.0
## Full-volume radius (m) for engine proximity attenuation. Within this distance
## from the active camera a car's engine plays at 0 dB; beyond it the level falls
## off with distance (1/d sound-pressure law, -6 dB per doubling). Tunable.
@export var engine_audio_ref_distance_m := 8.0
## Full-volume radius (m) used INSTEAD of engine_audio_ref_distance_m for cars
## waiting behind the reveal-card focus car during the start-line REVEAL sequence
## (start_line.gd). The queue spacing (start_queue_gap, 7 m) is smaller than the
## normal 8 m radius, so with the general radius every queued car sits at/near full
## volume at once — cluttered. A smaller radius here makes queued cars fall off
## faster with distance while the reveal camera is anchored, without touching the
## general/racing-context radius or the departing car's already-fine falloff once
## it has actually launched. Tunable; keep it comfortably under start_queue_gap so
## adjacent queued cars actually differentiate.
@export var engine_audio_ref_distance_reveal_m := 0.5
## Attenuation floor (dB, <= 0) for a distant engine — the quietest a car's voice
## drops to, so a far car recedes to near-silence without going to -inf. Tunable.
@export var engine_audio_max_attenuation_db := -60.0
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
## Mix level of the turbo spool whistle (0 = off). Rides on top of the engine note,
## amplitude tracking boost. Negative values invert the layer's phase (subtractive mix).
@export_range(-1.0, 1.0) var engine_turbo_whistle_gain := 0.0
## Turbo spool CHARACTER. The whistle is resonant band-pass-FILTERED NOISE (real
## turbos are air rushing through the compressor, not a pure tone), whose centre
## frequency (Hz) sweeps from _freq_min (barely spooling) to _freq_max (full boost)
## with the turbo shaft speed. See features/forced-induction.md.
@export_range(100.0, 4000.0) var engine_turbo_whistle_freq_min := 350.0
@export_range(1000.0, 9000.0) var engine_turbo_whistle_freq_max := 2500.0
## Filter resonance: low Q = airier / breathier rush; high Q = a more tonal whistle.
@export_range(0.5, 12.0) var engine_turbo_whistle_q := 2.0
## Blend of the broadband air-rush layer under the resonant whine: 0 = pure resonant
## whine, 1 = mostly airflow "whoosh". Keeps it from sounding like a test tone.
@export_range(0.0, 1.0) var engine_turbo_air_mix := 0.45
## Amplitude of the blow-off / dump-valve "pshhh" burst on a throttle lift while boosted.
@export_range(-1.0, 1.0) var engine_turbo_bov_gain := 0.0
## Decay time (ms) of the blow-off burst's envelope — how long the "pshhh" tail
## rings out. Instant attack, exponential decay. Independent of the anti-lag bang.
@export_range(1.0, 500.0) var engine_turbo_bov_decay_ms := 300.0
## Blow-off FLUTTER: an LFO (tremolo) over the burst, for the stuttering
## "brrrap" flutter/surge character. 0 = smooth "pshhh"; 1 = full depth (chops
## the burst to silence at each LFO trough).
@export_range(0.0, 1.0) var engine_turbo_bov_flutter_amount := 0.5
## Flutter LFO frequency (Hz) — how fast the burst stutters. ~10–40 Hz reads as flutter.
@export_range(1.0, 200.0) var engine_turbo_bov_flutter_hz := 15.0
## Amplitude of the anti-lag exhaust bang burst (its OWN noise burst, independent of
## the limiter crackle, so it mixes separately).
@export_range(-1.0, 1.0) var engine_turbo_antilag_bang_gain := 0.0
## Decay time (ms) of each anti-lag bang's envelope — shorter = a sharper crack,
## longer = a fatter thud. Independent of the blow-off burst.
@export_range(1.0, 500.0) var engine_turbo_antilag_decay_ms := 12.0
## Mix level of the belt-driven supercharger whine (0 = off). Pitch tracks engine rpm.
## Negative values invert the layer's phase (subtractive mix).
@export_range(-1.0, 1.0) var engine_supercharger_whine_gain := 0.0
## Mix level of the nitrous hiss layer (0 = off). Unlike the whine this is BROADBAND noise
## with no tonal component, and it only sounds while nitrous is actually being delivered —
## see features/nitrous.md. Negative values invert the layer's phase (subtractive mix).
@export_range(-1.0, 1.0) var engine_nitrous_hiss_gain := 0.7
@export_enum("RWD", "AWD", "FWD") var drive_mode := 0  # initial layout (cycle in-game with Y)
# AWD uses a fully locked centre diff (front + rear share one driveline speed),
# so there is no torque-split knob.

@export_group("HUD")
@export var hud_enabled := true  # on-screen speed readout
## Show the in-run rally pacenote strip along the top of the screen: the current
## turn (arrow + grade) with the upcoming turns queued, dimmer, to its right. Reads
## left-to-right and slides left as each corner is passed. Mirrors hud_enabled.
@export var hud_pacenotes_enabled := true

@export_group("Music")
## Wall-clock gap (s) between processed frames above which we assume the main
## thread stalled long enough that web audio underran and went silent — triggers
## music stall recovery. Well above a normal ~16 ms frame, below any real freeze.
@export var music_stall_threshold_sec := 0.5
## After a stall, how long (s) frames must flow normally again before music
## resumes from a clean start.
@export var music_resume_stable_sec := 0.4

@export_group("SFX")
## Master switch for one-shot sound effects (the `Audio` autoload / scripts/audio.gd).
## false = every Audio.play_* call is a silent no-op; the game runs unchanged.
@export var sfx_enabled := true
## Pitch (Hz) of the standard cue beep — what Audio.play_beep() uses when the caller
## doesn't pass a frequency. Call sites should override this only when a cue is
## deliberately a DIFFERENT pitch (e.g. a higher "GO" over the countdown ticks).
@export var sfx_beep_frequency_hz := 880.0
## Length (s) of the standard cue beep. Keep it short — this is a blip, not a tone.
@export var sfx_beep_duration_sec := 0.12
## Level (dB) of the standard cue beep, before any per-call offset. 0 = full scale.
@export var sfx_beep_volume_db := -6.0
## Exponential amplitude decay rate (per second) of the beep's tail. Higher = a
## tighter, more percussive blip; 0 = a flat tone that stops abruptly.
@export var sfx_beep_decay := 12.0
## Synthesis/mix rate (Hz) for procedural SFX. Matches engine_audio.gd's MIX_RATE;
## higher costs more CPU in the GDScript render loop for no audible gain on a blip.
@export var sfx_mix_rate := 22050.0

@export_group("Stage")
## Countdown length, in seconds, before the car's controls unlock at the start
## of a stage. The car holds position (handbrake forced) until it elapses.
@export var stage_countdown_seconds := 3.0
## Track-progress percentage (0..100) that ends the stage. 100 so the stage ends
## exactly as the car crosses the finish arch, which world.gd places at the end of
## the centerline (100% progress). TrackProgress samples the curve's far edge
## exactly, so _best_offset can reach the baked length — see track_progress.gd.
@export_range(0.0, 100.0) var stage_complete_percent := 100.0
## Show the top-right elapsed-time readout during the run (mirrors hud_enabled).
@export var hud_elapsed_enabled := true
## Show the permanent in-run standings readout under the run timer: the player's live
## position in the rival field ("P3/12") and the gap to the position above (or the
## cushion over P2 while leading). Only inside an active rally session, which is where
## an opponent field exists. Replaced the old every-few-turns "vs P1" pace popup.
@export var hud_position_enabled := true
## How long (seconds) a fresh multiplayer lobby round is HELD at the line before every
## client releases it — the join window that lets players who enter within it start
## together. All clients compute the same release instant from the shared round's
## started_at_ms plus this, on the server-corrected clock, so the start is synchronised
## with no extra coordination. 0 releases immediately (Phase A behaviour).
@export var lobby_start_hold_seconds := 30.0
## How long (seconds) after a lobby round ENDS until the next one starts — the
## intermission the post-stage countdown counts through. Written into the shared round
## document as the scheduled start, so every client agrees on the instant.
@export var lobby_intermission_seconds := 60.0
## How long (seconds) before the next round's scheduled start a client leaves the
## finished world and starts loading the next map, so generation (~15s) completes
## before GO rather than eating into the race.
@export var lobby_preload_lead_seconds := 30.0
## How long (seconds) a transient in-run HUD tag (the corner-cut flash) stays on screen
## before it fades out.
@export var hud_popup_show_seconds := 3.0
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
## Stagger (s) between successive cars launching, so the queue rolls off one after
## another (leader, then player, then trailer) rather than all at once.
@export var start_queue_stagger_seconds := 0.35
## Seconds each half (out, then back) of the fade-to-black transition takes.
@export var start_fade_seconds := 0.6
## Straight road (m) forced AHEAD of the start line on a staged run, so the leader
## has road to drive off down (the queue cars are axis-locked to a straight line).
@export var start_lead_in_ahead_m := 22.0
## Straight road (m) extended BEHIND the start line on a staged run, so the player
## (staged behind the three-car opponent grid) sits on paved road. Constraint:
## start_lead_in_behind_m >= 3 * start_queue_gap + ~4 m (a car length) — the player is
## staged three gaps back, so widening the gap needs a wider stub.
@export var start_lead_in_behind_m := 30.0
## Height (m) the start-line cars are seated ABOVE the road at spawn — the player and
## both queue cars (leader ahead, trailer behind) — so they settle onto their wheels
## instead of spawning clipped into the ground. Smaller than the general drop-in
## spawn_clearance: at the line the road height is known, so a gentle seat is enough.
@export var start_spawn_clearance := 0.5
## Field of view (degrees) of the start-line orbit camera during the reveal.
@export_range(30.0, 120.0) var start_orbit_fov := 70.0
## Seconds the camera takes to fly from the orbit idle pose to the anchored 3/4 reveal
## shot in front of the start line, once the player presses Start.
@export var start_reveal_fly_seconds := 1.2
## Reveal shot: camera distance (m) AHEAD of the start line (down the lead-in), so it
## looks back at the car on the line.
@export var start_reveal_cam_front_m := 6.0
## Reveal shot: lateral offset (m) from the centreline, giving the 3/4 angle.
@export var start_reveal_cam_side_m := 4.0
## Reveal shot: camera height (m) above the line — low to the ground.
@export var start_reveal_cam_height_m := 1.0
## Reveal shot: height (m) of the look-at point on the car (roughly its roofline).
@export var start_reveal_cam_look_height_m := 0.8
## Field of view (degrees) of the anchored reveal shot.
@export_range(30.0, 120.0) var start_reveal_cam_fov := 55.0
## Roll-up decel model divisor: a scripted queue car's braking distance is
## v*v / this (+ the reaction margin below), i.e. it assumes a deceleration of
## (this / 2) m/s² when deciding where to start braking. 28 ≈ 14 m/s² decel.
@export var start_roll_decel_divisor := 28.0
## Reaction margin (m) added to the computed braking distance so a roll-up car starts
## braking slightly before the pure decel model would — absorbs reaction lag.
@export var start_roll_brake_margin_m := 0.25
## Coast band (m): while the target is farther than brake_dist + this, the car rolls up
## at full throttle; inside it (but still beyond brake_dist) the car coasts into the
## brake point instead of powering to it.
@export var start_roll_coast_band_m := 1.0
## Creep threshold (m/s): while braking onto the target the foot brake stays pressed
## only while the car is still rolling faster than this; below it, throttle drops to
## zero so the auto box doesn't grab reverse against the held handbrake.
@export var start_roll_creep_speed := 1.5

@export_group("Damage")
# Per-car HP attrition (features/damage.md). Max HP is CarLibrary metadata
# (mass-keyed), NOT here; these are the global magnitudes that govern how impacts
# drain it and how a damaged car degrades. Tuning numbers are placeholders to be
# settled by playtest — this fixes the mechanism, not the values.
# Damage is keyed to the SPEED the car was travelling at when it hit something:
# nothing at a crawl, then a square-law (kinetic-energy) climb so a moderate-speed
# crash hurts far more than a low-speed nudge. See DamageModel.hp_loss_for_speed.
# Damage is UNIFIED on deceleration (features/damage.md): HP loss is keyed to how much
# velocity the car sheds in one physics tick, whatever caused it. A crash arrests the
# body in a single tick (tens of g); braking and clean landings stay under the
# braking-proof threshold below. See DamageModel.register_deceleration.
## Deceleration (in g) a single physics tick must exceed before it costs any HP. Tyres
## and brakes cap real deceleration at ~1-1.5 g, so ~2 keeps hard braking and clean
## wheel-landings free while any solid crash (tens of g) clears it easily; the small
## drag impulse of a brushed bush/crowd just tips over it for a light chip. Raise it if
## hard landings feel too twitchy. This is the single sensitivity knob.
@export_range(0.5, 20.0) var impact_threshold_g := 2.0
## Reference impact speed (km/h) — the velocity shed at which a hit costs
## impact_ref_hp_loss. HP loss grows with the SQUARE of the shed velocity (kinetic
## energy) up to here. For a full solid arrest the shed velocity ≈ the approach speed,
## so this maps to a real-world crash speed.
@export_range(1.0, 200.0) var impact_ref_speed_kmh := 60.0
## HP a reference-speed (impact_ref_speed_kmh) hit costs. With per-car max HP of
## ~800-1100, ~200 means most cars survive 4-5 such moderate hits; the square law
## then makes a 20 km/h hit cost only a small fraction of this (barely any damage).
@export_range(0.0, 2000.0) var impact_ref_hp_loss := 300.0
## Cap on the HP a SINGLE tick's deceleration can cost, as an absolute HP amount — so no
## one crash strips the whole pool (it survives a good few). Being a flat amount (not a
## fraction of max HP), a car's max_hp genuinely matters: a fragile car is gutted by
## fewer capped hits than a tough one. A pinned car sheds ~0 velocity/tick so grinding
## self-limits; a real multi-bounce tumble racks up several capped hits, so a long fall
## down a drop can still empty it.
@export_range(0.0, 2000.0) var impact_max_loss := 450.0
## Damage misfire: a damaged engine intermittently cuts fuel (EngineSim), losing
## power in stumbling bursts instead of a smooth derate — fully simulated (crank
## torque drops to friction) and audible (the synth ducks + crackles on the cut).
## The cut rate scales with the damage fraction and the engine's load. See
## features/damage.md.
## Health fraction (hp/max_hp) at/above which the engine is FULLY healthy — no misfire,
## full revs. Below it BOTH engine-damage effects ramp in together (DamageModel.damage_ramp),
## reaching their worst at 0 HP. So a lightly-damaged car runs clean; the stumble and the
## lowered rev ceiling only set in once it's properly hurt.
@export_range(0.0, 1.0) var damage_misfire_health_threshold := 0.5
## Worst misfire intensity, at 0 HP — the "certain point" past which damage stops weakening
## the engine. Below 1.0 on purpose: damage must never take the car out of the run, so even a
## 0 HP engine keeps firing often enough to drive to the finish, just badly.
@export_range(0.0, 1.0) var damage_misfire_level_max := 0.8
## Fraction of the engine's redline still usable at 0 HP — a damaged engine won't pull to the
## top end, so every gear runs out early and the car is slower everywhere (and audibly bounces
## off a lower limiter). Ramps down from 1.0 at damage_misfire_health_threshold. Also floored
## well above zero so the car always revs enough to drive. See features/damage.md.
@export_range(0.05, 1.0) var damage_rev_limit_min_fraction := 0.6
## Cuts per second at 0 HP under full load — the worst-case misfire frequency.
@export_range(0.0, 30.0) var damage_misfire_rate_max := 9.0
## How much the misfire fires INDEPENDENT of load (0..1): the cut rate is
## rate_max * damage_fraction * (this + (1-this) * load), where load blends throttle
## and rpm. 1 = load-independent; 0 = only ever cuts under full load/revs.
@export_range(0.0, 1.0) var damage_misfire_load_bias := 0.35
## Shortest / longest single fuel-cut a misfire lasts (seconds) — rolled per cut so
## the stumble has variety. Kept brief so the engine sputters rather than dies.
@export_range(0.01, 1.0) var damage_misfire_duration_min := 0.04
@export_range(0.01, 1.0) var damage_misfire_duration_max := 0.16
## Wheel-toe misalignment from impacts (radians). Each solid impact bends every
## wheel by a random amount/direction (DamageModel.nudge_wheels), permanently and
## per-car (persisted, eased back only by the free field repair). The bent wheels are rotated
## on the VehicleWheel3D nodes themselves, so the car's pull/crab comes from the
## physics alone — no synthetic steer bias. See features/damage.md.
## Toe (radians) a full-per-hit-cap impact adds to a wheel: the per-wheel nudge is
## this times (hp_loss / max_hp) times a random 0.5..1 magnitude, with a random sign.
@export_range(0.0, 0.5) var damage_wheel_toe_gain := 0.12
## Per-wheel clamp on accumulated toe (radians) — a wheel can't bend past this no
## matter how many hits it takes, so a heavily-crashed car stays (barely) drivable.
@export_range(0.0, 0.5) var damage_wheel_toe_max := 0.14
## Between-event pit repairs (Save.field_repair): at the START of every rally event
## after the first, the engineers patch the fielded car up a bit. This is the
## fraction of the HP LOST so far that gets restored — 0.2 means a car at 50%
## comes back to 60% (20% of the missing 50%). See features/damage.md.
@export_range(0.0, 1.0) var field_repair_hp_fraction := 0.2
## Between-event pit repairs: the fraction each wheel's misalignment is bent back
## toward straight — 0.5 halves every wheel's toe (a wheel bent 4° comes back to 2°).
## More generous than the HP patch so alignment recovers faster across a rally.
@export_range(0.0, 1.0) var field_repair_toe_fraction := 0.5
## Soft contacts (bushes, spectators) are NOT solid-obstacle impacts: they stay
## pass-through (a per-tick proximity check, not a solid collider), but instead of a
## flat HP loss they now apply a small speed-scaled DRAG IMPULSE to the car — the
## resulting deceleration then feeds the unified damage rule for a light chip. See
## BushField / SpectatorGroup / features/damage.md.
## Fraction of the car's horizontal speed a single bush graze sheds (small — bushes
## just scuff you). Tuned so it clears impact_threshold_g for a minor HP chip.
@export_range(0.0, 0.5) var bush_drag_strength := 0.04
## Yaw drag-torque coefficient a bush applies as it snags a corner of the car: the
## angular impulse is this times the car's speed (m/s) times sin(angle to the bush),
## so faster grazes tug harder and a head-on brush barely twists. Sign swings the
## nose toward the bush (the snagged corner drags back).
@export_range(0.0, 500.0) var bush_drag_torque := 120.0
## Below this speed (km/h) a bush neither damages nor tugs the car — a parked car
## sitting in a bush isn't dragged.
@export_range(0.0, 60.0) var bush_min_speed_kmh := 8.0
## Bush interaction radius as a fraction of the bush mesh's visual XZ radius (<1 gives
## the player leeway to clip the visible edge without being penalised).
@export_range(0.1, 1.0) var bush_hit_radius_frac := 0.8
## Fraction of the car's horizontal speed knocking a spectator sheds (a bit more than a
## bush — you shouldn't mow the crowd for free). The resulting deceleration feeds the
## unified damage rule; grouping is natural (a stopped car sheds ~0/tick).
@export_range(0.0, 0.5) var spectator_drag_strength := 0.08
## Show the in-run HP gauge (mirrors hud_enabled).
@export var hud_hp_enabled := true
## HP fraction below which the gauge flashes a low-HP warning.
@export_range(0.0, 1.0) var hud_low_hp_warn_frac := 0.25

@export_group("Recovery")
# Automatic stuck-car recovery (features/progress.md): with big cliffs/drops a car can
# get trapped INSIDE the lateral reset leash (nose-down in a pit, flipped, or pinned).
# TrackProgress runs a watchdog that teleports it back to the last on-road pose (free —
# no penalty) once it's been stationary and unable to self-recover for a short while.
## Master toggle for the stuck watchdog. Off ⇒ only the timed off-track reset runs.
@export var recovery_enabled := true
## Seconds the car must stay stuck (stationary + can't self-recover) before the
## auto-reset fires. Long enough not to interrupt a brief scrabble out of trouble.
@export_range(0.5, 15.0) var recovery_timeout_s := 3.0
## Speed (m/s) below which the car counts as "not moving" for the watchdog. While it's
## still moving (driving, falling, sliding) the stuck timer stays at zero.
@export_range(0.0, 5.0) var recovery_speed_mps := 0.7
## Metres below the road surface (at the car's progress point) that count as "fallen
## into a pit it can't climb out of" — a drop deeper than this auto-recovers even with
## no throttle input.
@export_range(0.5, 30.0) var recovery_depth_m := 3.0
## The car's up-vector · world-up below which it counts as flipped (rolled onto its
## side/roof). 0.3 ≈ tipped more than ~70° from upright.
@export_range(0.0, 1.0) var recovery_upright_dot := 0.3

@export_group("Mobile")
# On-screen touch controls (steer left / steer right / throttle / brake).
# Shown automatically on touch devices (DisplayServer.is_touchscreen_available()).
# Set this true to force them on for testing on a desktop/in the editor. Which of
# the six control schemes is shown is a per-player setting chosen on the title
# screen's Settings page (persisted in the save profile, not here).
@export var mobile_controls_force := false
## Show a small readout of the touch input path (which browser snapshot is feeding the
## overlay, how many fingers the BROWSER thinks are down, and what the overlay is
## holding) in the top-left corner. For diagnosing stuck on-screen buttons on a real
## phone, where nothing else is observable — see features/mobile-controls.md.
@export var mobile_controls_debug := false
## Tilt-steering sensitivity (TILT scheme): multiplier on the device roll. 1.0 maps
## a full 90° tilt to full lock; higher reaches full lock at a gentler tilt.
@export_range(0.5, 5.0) var tilt_sensitivity := 2.0
## Tilt-steering deadzone: device roll (as a fraction of 1 g) ignored around level,
## so a phone held roughly flat doesn't drift the steering.
@export_range(0.0, 0.9) var tilt_deadzone := 0.05
## Flip the tilt-steering direction. The intended mapping is "roll the phone like a
## steering wheel" — right-hand edge down steers right — but which sign a device
## reports its roll with is settled by the platform (see scripts/tilt_input.gd), so
## this is the one-flag fix if a phone turns out to steer backwards.
@export var tilt_invert := false

@export_group("Debug")
@export var debug_wheel_forces := false  # per-wheel arrows (toggle with H): green = suspension, red = friction, blue = aero downforce
## Length of the debug force arrows, in metres drawn per newton of force.
@export_range(0.00001, 0.01) var debug_force_arrow_scale := 0.00025
## Length of the combined steer-assist debug arrow (yellow, above the car,
## points left/right), in metres drawn per newton-metre of yaw-assist torque.
@export_range(0.0000001, 0.001) var debug_assist_arrow_scale := 0.0001
## Where a benchmark run POSTs its results JSON (features/benchmark.md → feedback
## loop). Empty = auto: on a web build, POST to "/bench" on the page's own origin
## (the serve_web.sh collector), so the LAN loop needs no config. On an installed
## APK set this to your dev machine, e.g. "http://192.168.1.50:8080/bench".
@export var bench_report_url := ""

@export_group("Camera")
@export var follow_distance := 2.5
## Chase camera height above the ground, expressed as a multiple of
## follow_distance (so a 1.0 ratio keeps height == distance). Scaling off the
## follow distance keeps the camera pitch stable when the distance changes.
@export var follow_height_ratio := 0.7
@export var smoothing := 5.0
## Bonnet (hood) camera local offset on the car. Front of the car is -Z, so a
## negative Z sits the camera over the bonnet; +Y raises it to eye height.
@export var bonnet_offset := Vector3(0.0, 0.7, -0.6)
## Field of view (degrees) for the bonnet camera.
@export_range(30.0, 120.0) var bonnet_fov := 85.0
## Base field of view (degrees) for the chase camera at a standstill.
@export_range(30.0, 120.0) var chase_fov := 90.0
## Extra FOV (degrees) added on top of chase_fov at chase_fov_speed and above, to
## sell a sense of speed. The FOV eases linearly from chase_fov (stationary) to
## chase_fov + chase_fov_speed_boost at chase_fov_speed (m/s).
@export_range(0.0, 100.0) var chase_fov_speed_boost := 100.0
## Speed (m/s) at which the full chase_fov_speed_boost is reached.
@export_range(1.0, 100.0) var chase_fov_speed := 55.0
## Extra FOV (degrees) added, on top of the speed boost, for as long as nitrous is
## actually DELIVERING (held + charged + combusting — EngineSim.nitrous_delivering, not
## merely the button held). A FIXED amount, not speed-scaled: the point is a punch at the
## moment of the boost, so it reads at any speed. Eases in and out at
## chase_fov_smoothing like every other FOV change. 0 disables it.
## See features/nitrous.md.
@export_range(0.0, 60.0) var chase_fov_nitrous_boost := 20.0
## Easing rate for chase FOV changes (1 - exp(-rate*dt)); higher snaps faster.
@export_range(0.1, 20.0) var chase_fov_smoothing := 2.0
## Dolly-zoom strength: how strongly the follow distance is pulled in to
## counteract the speed FOV so the car keeps its on-screen size. 0 = distance
## never changes (pure FOV zoom, the car grows with speed); 1 = full dolly zoom
## (distance ∝ 1/tan(fov/2), the car stays the same size). Values in between
## soften an over-eager pull-in.
@export_range(0.0, 1.0) var chase_dolly_mix := 0.5
## Where along the car the chase camera aims, as a multiple of the car's half
## length measured forward from the body origin (the wheelbase centre). 0 aims at
## the middle of the model; 1 aims at the nose. Because the aim point rides the
## car's FACING while the camera sits behind its direction of TRAVEL, a non-zero
## value makes the framing slide sideways as the car drifts — the nose swings out
## of centre — which adds motion the centred aim can't show.
@export_range(0.0, 2.0) var chase_look_ahead_ratio := 0.7
## G-force camera lean (chase only). The chase camera derives the car's
## acceleration each frame and leans into it: lateral g rolls the view, forward
## g pitches it (brake dips the nose, throttle lifts it). Gains are degrees of
## tilt per m/s² of acceleration on that axis; a negative gain inverts that axis.
## The result is clamped to ±chase_tilt_max_deg and eased at chase_tilt_smoothing
## (higher = snappier; the same 1-exp(-rate·dt) idiom as the orbit/FOV smoothing),
## so the tilt decays back to level once the g-forces drop.
@export_range(-2.0, 2.0) var chase_tilt_roll_gain := -0.4
@export_range(-2.0, 2.0) var chase_tilt_pitch_gain := 0.0
@export_range(0.0, 30.0) var chase_tilt_max_deg := 4.0
@export_range(0.1, 20.0) var chase_tilt_smoothing := 6.0
## CAMERA SHAKE (chase only). One shared amplitude that every source below pushes into, applied
## as ROTATION after the camera has aimed — never as position, which would break the dolly-zoom
## framing. See features/camera.md → "Camera shake".
##
## Peak shake amplitude (degrees) at full intensity, on each of pitch / yaw / roll. The single
## "how violent" dial: 0 disables shake outright, and every gain below is a share of it.
@export_range(0.0, 10.0) var shake_max_deg := 0.5
## Oscillation rate (Hz). Layered at three incommensurate multiples of this so the shake never
## reads as a clean wobble. Keep it well under half the physics rate or it aliases into a slow
## sway instead of a vibration.
@export_range(0.5, 30.0) var shake_frequency := 13.0
## How fast an IMPULSE (a crash, a landing, a clipped bush) decays, as the usual
## 1-exp(-rate·dt) weight. Higher = a sharper, shorter jolt.
@export_range(0.1, 30.0) var shake_decay := 7.0
## G-FORCE source — the one that covers every impact. The car's acceleration magnitude in g;
## anything above this threshold shakes, scaled by the gain (shake per g of excess). The
## threshold keeps ordinary cornering, braking and free-fall (a steady ~1 g) quiet, the same way
## impact_threshold_g keeps them free of damage — see features/damage.md.
@export_range(0.0, 20.0) var shake_g_threshold := 2.5
## Intensity added per g of acceleration above shake_g_threshold. 1.0 means ~1 g of excess
## already reaches full amplitude.
@export_range(0.0, 6.0) var shake_g_gain := 0.0
## SPEED source: intensity added at chase_fov_speed and above (the same reference speed the FOV
## ramp uses, so the two "sense of speed" effects cannot disagree), ramping linearly from 0.
## A constant low-level buzz — keep it small.
@export_range(0.0, 1.0) var shake_speed_gain := 0.5
## WHEELSPIN source: intensity added per 1.0 of fore/aft breakaway past peak on the worst DRIVEN
## tire (Drivetrain.drive_wheelspin_excess). Only driven wheels count — a locked undriven wheel
## already reaches the camera through the g-force term.
@export_range(0.0, 2.0) var shake_wheelspin_gain := 0.0
## NITROUS source: intensity added for as long as nitrous is DELIVERING, on top of the FOV punch
## (chase_fov_nitrous_boost). Flat, like that boost, and for the same reason.
@export_range(0.0, 1.0) var shake_nitrous_gain := 0.25
## Replay WHEEL shot: lateral clearance (m) kept OUTSIDE the target car's half-width
## when mounting the onboard wheel-cam rig. The rig sits at (car half-width +
## this margin) out from the body centreline, so it never lands inside — or right on
## the surface of — a wide car's body mesh. See replay_camera.gd (Shot.WHEEL).
@export_range(0.0, 1.0) var wheel_cam_lateral_clearance := 0.2
## Replay WHEEL shot: fallback lateral offset (m) used only when the replay target
## doesn't expose half_width() (e.g. a flat test fixture) — mirrors the old fixed rig
## position so behaviour is unchanged for targets with no known body width.
@export var wheel_cam_fallback_lateral := 0.95
## Replay camera base FOV (degrees), used by the shots that sit at a FIXED offset from the
## car (ORBIT / FLYBY / WHEEL) — their distance never changes, so they need no zoom
## compensation. See replay_camera.gd (_target_fov).
@export_range(30.0, 120.0) var replay_fov := 75.0
## CONSTANT-SUBJECT-SIZE FRAMING — the replay ROADSIDE and HIGH_WIDE shots. Both watch the
## car from a distance that changes a lot (the planted roadside cam sees it come from far
## up the road, sweep past and shrink away; the high "helicopter" shot sits well back and
## up), so instead of a fixed lens they pick their FOV from the current distance to keep the
## car about the same size on screen — zoomed in when it's far, widening as it arrives.
##
## Nominal subject size (m) the framing aims to fit — roughly a car's length. Bigger =
## every framed shot zooms in more (a bigger subject needs a longer lens to fit the same
## share of the frame).
@export_range(0.5, 20.0) var replay_frame_subject_size := 4.2
## Share of the VIEWPORT HEIGHT that subject should span. Higher = tighter framing (the car
## fills more of the screen); lower = looser.
@export_range(0.02, 1.0) var replay_frame_screen_fraction := 0.32
## Lens limits (degrees) for the framed shots: the long end (how far it may zoom in when the
## car is distant) and the wide end (how wide it may open as the car sweeps past, where the
## exact framing stops mattering because the car fills the frame regardless).
@export_range(5.0, 120.0) var replay_frame_fov_min := 14.0
@export_range(5.0, 120.0) var replay_frame_fov_max := 75.0
## Easing rate for replay FOV changes (1 - exp(-rate*dt)); higher tracks the framing more
## tightly, lower drifts behind it like a hand on a zoom rocker. A CUT (shot change or a
## roadside re-plant) always snaps, never eases. 0 disables easing entirely (snap always).
@export_range(0.0, 20.0) var replay_fov_smoothing := 5.0

@export_group("Menu / HQ")
## Seconds the HQ menu camera takes to ease into framing the focused car
## (todo/diegetic-hq.md). 0 snaps instantly.
@export var menu_camera_move_time := 0.6
## HQ menu camera position relative to the focused car (WORLD space — added to the
## car's position). The parked cars face +Z (nose toward the courtyard / camera), so
## a positive +Z offset sits the camera IN FRONT of the car looking back past it at
## the garage (-Z), with a +X side-step + eye-height lift for a front-3/4 hero shot.
@export var menu_camera_offset := Vector3(2.6, 1.5, 6.2)
## Height (m) above the car's origin that the HQ menu camera looks at.
@export var menu_camera_look_height := 0.7
## Camera position (relative to the car, WORLD space) for the COSMETIC WHEEL view — the
## solo car-park mode where the player tries wheels on (features/wheel-customization.md).
## Replaces menu_camera_offset while that mode is open. Low and side-on (+X, small +Z) so
## the settled car's flank and BOTH wheels fill the frame — wheels are judged by stance,
## which is why this view uses the car park (car resting on its suspension) and not the
## tuning lift (car raised off the ground).
@export var hq_wheel_cam_offset := Vector3(6.4, 0.9, 0.6)
## Height (m) above the car's origin the wheel-view camera looks at. Lower than
## menu_camera_look_height so the shot sits at wheel height, not window height.
@export var hq_wheel_cam_look_height := 0.45
## Width (m) of one parking bay in the HQ car park — the spacing between parked cars
## along the lot's X, and the period of the painted bay markings (_build_carpark).
@export var menu_car_spacing := 3.4
## Front-to-back depth (m) of a parking bay: the length of the painted bay surface
## along Z, sized to comfortably hold a car parked nose-out toward the courtyard.
@export var menu_carpark_bay_depth := 5.4
## Number of painted parking bays in the car-park lot — i.e. how many cars show on
## one PAGE of any car-park screen. The player's collection is unbounded; the car park
## pages through it `carpark_page_size` at a time (see scripts/car_list.gd / hq.gd's
## car park). NOT an ownership cap.
@export var carpark_page_size := 10
## Car-park lineup placement. The lot centre is shifted this far off the world centre
## (m, along +X). The bays run as a centred row ALONG X at hq_carpark_origin, each car
## parked nose-out toward the courtyard / camera (+Z) in its own painted bay, so the
## front-3/4 menu camera frames the focused car with the garage behind it. The
## exterior/title camera is shifted by the same offset so it stays centred on the row.
@export var menu_car_park_offset := 0.0
## Minimum horizontal pointer drag (px) in the car-park lineup for the
## gesture to count as a SWIPE to the prev/next car (hq.gd _lineup_pointer_input).
## Must also out-measure the vertical component so a sloppy vertical drag doesn't pan.
@export var menu_swipe_min_px := 60.0
## Maximum total pointer travel (px) between press and release for the gesture to
## count as a TAP on a parked car (raycast pick + focus). Between this and
## menu_swipe_min_px the gesture is neither and does nothing.
@export var menu_tap_max_px := 14.0

# --- Podium / reward-reveal sequence (podium.gd) ------------------------------
## Height (m) of the 1st-place podium step; 2nd/3rd are scaled down from it.
@export var podium_step_height := 0.9
## Spacing (m) between the three podium steps (along X). The winner is centred.
@export var podium_step_spacing := 3.6
## Seconds the slot-machine reveal (car / upgrade) spins before locking onto the
## won item. The Continue button is hidden until it finishes. 0 = instant.
@export var podium_slot_spin_time := 2.2
## Degrees/second the won car rotates on the showroom turntable in the reveal.
@export var podium_showroom_spin_dps := 32.0
## Half-size (m) of each square tarmac pad on the podium floor (one under the
## podium, one under the showroom turntable). The rest of the floor is grass.
@export var podium_tarmac_pad_half := 9.0
## Width (m) of the grass↔tarmac feather band ramping each pad into the grass,
## the same crossfade the generated road uses (shaders/ps1_models.gdshader).
@export var podium_tarmac_feather_m := 3.0
## Decorative trees scattered in a ring around the podium + showroom (visual
## dressing only — no collision; skipped in headless test runs).
@export var podium_scenery_tree_count := 40
## Decorative bushes scattered on the grass around the podium + showroom.
@export var podium_scenery_bush_count := 60
## Roadside-style spectators standing in an arc facing the podium (+ a small
## cluster at the showroom). Static dressing — no steering/ragdoll AI.
@export var podium_spectator_count := 26
## Seconds between each row appearing as the podium's ranked leaderboard fills in
## top-to-bottom (Podium._reveal_standings / _reveal_stars — the star row uses the same
## cadence). Deliberately its own field rather than sharing standings_reveal_step: the
## podium reveals ONE list at a time, where the between-event standings screen stacks TWO
## sections (stage + overall) and was given a shorter step so the whole reveal still lands
## in about the same couple of seconds.
@export var podium_reveal_step := 0.5
## Seconds between each row appearing as the between-event standings screen's two stacked
## leaderboards (stage result + overall) fill in (Standings._reveal_standings). See
## podium_reveal_step for why the two screens keep separate fields.
@export var standings_reveal_step := 0.3
## Inner / outer radius (m) of the tree+bush scatter ring around each focal area.
@export var podium_scenery_ring_inner := 14.0
@export var podium_scenery_ring_outer := 34.0

# --- Diegetic HQ: one 3D space the camera flies through (todo/diegetic-hq.md).
# Camera "stations" are an eye position + a look target (world space); the camera
# tweens between them over menu_camera_move_time. The exterior is the boot/title
# shot (block buildings + the car park); Start flies into the garage (the map table
# + the tuning lift); tapping the table drops to a near-top-down view of the 3D map.
## Exterior/title camera: eye, then look target, both given as OFFSETS from the first
## (leftmost) parked car's ground position (see hq.gd _station_xform / _first_car_anchor).
## A low, near-ground front-3/4 hero shot: sits just in front of (+Z) and beside the lead
## car, ~45° off its front, looking diagonally down the line (+X) past it to reveal the
## rest of the parked lineup. Anchoring to the first car keeps this framing as the centred
## lineup grows and its leftmost car slides toward −X (more cars owned). Cars face +Z.
@export var hq_exterior_cam_eye := Vector3(-4.5, 1, 4.5)
@export var hq_exterior_cam_look := Vector3(3.0, 0, -1.0)
## Garage interior camera (sees the map table + tuning lift).
@export var hq_garage_cam_eye := Vector3(0.0, 4.6, 13.0)
@export var hq_garage_cam_look := Vector3(0.0, 1.1, 0.0)
## Map-table camera: a steep, near-top-down look down onto the table's 3D map, close
## in so the map fills the screen; drag to pan across it (clamped to the map extents).
## (Keep a small Z offset between eye and look so looking_at doesn't go degenerate at
## a perfectly vertical angle.)
@export var hq_table_cam_eye := Vector3(-3.0, 2.6, 0.4)
@export var hq_table_cam_look := Vector3(-3.0, 0.95, -0.3)
## Map-table drag gain. **1.0 means the map tracks the finger EXACTLY** — the drag delta is
## measured by projecting the pointer onto the map plane (hq.gd `_map_drag_delta`), so there
## is no metres-per-pixel constant to keep in step with the camera pose or the viewport size.
## This is a deliberate multiplier on top of that, and anything other than 1.0 reintroduces
## the bug it replaced: the map slides out from under the finger, so a pin you started the
## drag beside is nowhere near it when you let go. Retune only with that in mind.
@export_range(0.25, 4.0, 0.05) var hq_table_pan_gain := 1.0
## Map-table keyboard/gamepad glide speed: world metres/second the camera slides while
## a direction is held. Selection tracks whichever rally/arrow sits nearest the centre.
@export var hq_table_pan_glide := 2.5
## New-rally reveal (hq_table.gd `_run_reveal_sequence`): when rallies become enterable, the
## map camera pans to each in turn and flips its pin from the locked to the unlocked look.
## `pan_time` is the beat spent travelling/settling on a pin before it flips, `hold_time`
## how long the revealed pin is held before moving on (a special gets a longer beat), and
## `max_queue` caps how many pins one opening parades (the rest are banner'd as "+N more"
## and marked seen anyway). Any input skips the whole queue. See features/menus.md.
@export var hq_reveal_pan_time := 0.7
@export var hq_reveal_hold_time := 1.1
@export_range(1, 20) var hq_reveal_max_queue := 4
## Where the car-park lineup sits (outside, in front of the garage). Cars row along X.
@export var hq_carpark_origin := Vector3(0.0, 0.0, 26.0)
# --- WORLD-SPACE MENUS -------------------------------------------------------
# Everything tunable for the diegetic 3D menus lives in ONE run, in ONE inspector group, because
# these values are tuned TOGETHER and against each other (a panel offset only makes sense next to
# its station camera shift). See features/world-panel.md -> "Tuning it live" for the F8 loop, and
# the framing harness that prints the exact corrections rather than making you guess.
#
# NOT MOVED HERE, on purpose: each station's BASE camera pose, because both the flat and the
# world-space menus are framed by it, and filing it under "World-space menus" would misplace a value
# that also controls the shipped game. They stay in "Menu / HQ" above/below:
#   car park  menu_camera_offset / menu_camera_look_height
#   lift      hq_lift_cam_eye / hq_lift_cam_look
#   garage    hq_garage_cam_eye / hq_garage_cam_look        (also frames the challenge modal)
#   table     hq_table_cam_eye / hq_table_cam_look          (also frames the rally detail)
#   title     hq_exterior_cam_eye / hq_exterior_cam_look
# The *_camera_look_shift / *_camera_eye_shift fields in THIS group are added to those poses and
# apply only while world menus are on, which is why they belong here and the base poses do not.
@export_group("World-space menus")
## WORLD-SPACE MENUS (world_panel.gd, features/world-panel.md). While on, the car-park
## overlay is hosted on a panel welded to the focused car's flank instead of on a flat
## CanvasLayer over the frame. Off by default: this is the spike toggle, kept so the two
## can be A/B'd in place. In a debug build it also flips live with the
## `toggle_world_menus` action (F7) — same pattern as debug_wheel_forces / H.
@export var world_space_menus := false
## Where the car-park panel sits relative to the focused car, in the car MARKER's local
## space. MIND THE SIGNS: lineup markers are built with `rotation.y = PI` so the car parks
## nose-out toward the camera (hq_carpark.gd::_render_lineup_page), which flips X and Z
## against the world — in this space **−Z is the car's nose** and **−X is the car's left**
## (world +X, which is screen-right from the menu camera).
##
## The default puts the panel at the car's front-left corner, pushed forward and about one
## `menu_car_spacing` to the left, so it stands IN FRONT OF the neighbouring car on that
## side rather than on top of the focused one.
@export var world_panel_car_offset := Vector3(-2.16, 2.1, -2.31)
## Yaw about Y, in degrees, in that same marker space. 180 turns the panel to face the
## camera side (world +Z), which makes its plane PERPENDICULAR TO THE CAR'S DIRECTION and
## its width run ALONG THE ROW of parked cars. Note this is still read off-square: the menu
## camera is a front-3/4 shot (menu_camera_offset), so the angle comes from the CAMERA's
## pose, not from skewing the panel — which is the whole point of the design.
@export_range(-180.0, 180.0) var world_panel_car_yaw_deg := 180.0
## Panel height in metres; the width follows the 16:9 logical menu canvas. Pure look.
@export_range(0.2, 8.0) var world_panel_height := 3.8
## HOW BIG THE UI READS ON THE PANEL, independent of how big the panel is. The menu is
## laid out on a canvas this many times SMALLER than the normal logical frame and then
## scaled to fill the panel, so 2.0 makes every widget twice the size relative to the
## panel. This — not world_panel_height — is the dial for "the menu is too small to read";
## enlarging the panel scales the whole thing on screen, this scales the UI within it.
## Trade-off: a smaller canvas FITS LESS, so pushed far enough a screen needs its content
## trimmed or scrolled rather than just scaled up.
@export_range(0.5, 4.0, 0.1) var world_panel_ui_scale := 1.8
## Fallback (height_m, ui_scale) a WorldPanelHost builds its panel at when its station
## supplies no `spec` Callable at all — every shipped station DOES supply one (reading its
## own world_panel_*_height/*_ui_scale pair above), so this is a defensive default rather
## than a live look value. WorldPanel's own constructor keeps separate DEFAULT_HEIGHT_M /
## DEFAULT_UI_SCALE consts for its `_init` default parameters — GDScript default-argument
## values must be compile-time constants, so they cannot read this config field directly —
## but the runtime no-spec fallback path (WorldPanelHost._spec_now) reads THIS, not those,
## so a designer retuning this field actually changes the one case it can affect.
@export_range(0.2, 8.0) var world_panel_fallback_height := 2.2
@export_range(0.5, 4.0, 0.1) var world_panel_fallback_ui_scale := 1.6
## THE WHEEL-FITTING VIEW needs its own placement, because it is the one car-park mode that swaps the
## CAMERA out from under the panel: CarparkMode.WHEELS uses a low SIDE-ON framing (hq_wheel_cam_offset)
## so the settled car's flank and both wheels fill the frame, where every other mode uses the
## front-3/4 menu_camera_offset. A panel welded for the front-3/4 shot is edge-on or off-frame in that
## one, so the offset/yaw/height below replace the car-park values while it is open.
##
## Same marker space as world_panel_car_offset — signs are FLIPPED (−Z is the car's nose, −X its left).
@export var world_panel_wheels_offset := Vector3(-2.2, 1.6, 0.4)
@export_range(-180.0, 180.0) var world_panel_wheels_yaw_deg := 90.0
@export_range(0.2, 8.0) var world_panel_wheels_height := 2.4
## Added to the car park camera's LOOK TARGET while world-space menus are on, so the shot
## pans over to fit the floating panel in frame. The camera's POSITION is deliberately left
## alone (menu_camera_offset): moving the eye changes the whole composition and the
## car's framing with it, where panning the aim just brings the panel into shot. +X aims
## toward the panel's side (screen-right). Applied only in that mode, so the default flat
## car-park framing is untouched by this feature.
@export var world_panel_camera_look_shift := Vector3(2.1, 0.7, 0.0)
## Added to the car park camera's EYE while world-space menus are on — the car-park counterpart of
## world_panel_lift_camera_eye_shift. Prefer the LOOK shift above when it will do: panning the aim
## brings the panel into frame from the same viewpoint, where moving the eye recomposes the whole shot
## and moves the car within it. Reach for this when panning cannot solve it — most often because the
## panel needs more DISTANCE (pull back on +Z) to stop overflowing the frame, or because something is
## occluding it, which no aim change fixes.
##
## Applies to the standard lineup shot only, NOT the side-on wheel-fitting view (that mode swaps the
## camera out entirely — see world_panel_wheels_offset).
@export var world_panel_camera_eye_shift := Vector3(0.0, 0.0, 0.0)
## THE TUNING LIFT's world panel (migration step 2). Its anchor is hq_lift_pos in WORLD
## space — unlike the car park there is no per-car marker to hang off, so no axis flip
## applies here: +X is world +X, and the lift car noses −Z. Yaw 180 keeps the car-park
## convention (plane perpendicular to the car, width along the row).
##
## The garage is a MUCH tighter space than the open car park: the bay is enclosed and the
## lift camera sits close, so this panel wants to be smaller and its shot nudged more than
## the car park's. Expect to eyeball all four.
## The z here is pulled back toward the garage rather than out toward the lift camera: the
## bay camera sits only ~2.3 m off the bay, and at that range the panel's angular size is
## most of the frame — a little more distance buys a lot of fit.
##
## X IS BOUNDED BY THE CAR. The car is centred on the lift at x=4 and is ~1.8 m wide, so the
## panel's near edge must stay clear of x≈3.1 or it intersects the bodywork — the panel cannot
## be centred on the lift, because the car is what's standing there. Shrinking
## world_panel_lift_height is what buys room here: the aspect is fixed, so a shorter panel is
## also narrower.
##
## THE SAME PLACEMENT AS THE CAR PARK — the car's FRONT-LEFT CORNER, just past the nose. The
## lift car noses −Z and its left is −X (facing −Z with +Y up puts +X on its right), so that
## corner is −Z and −X of the lift: this default sits ~0.5 m ahead of the nose and 2.2 m out to
## the left, clear of the bodywork in both axes.
##
## Being ahead of the nose is what fixes the OCCLUSION, not just the framing: the car's nose
## sits ~1.2 m from the bay camera, so the near car covers a wide wedge of screen and was
## hiding a panel placed level with or behind it. Forward of the nose plus a pulled-back eye
## (world_panel_lift_camera_eye_shift) is what separates the two.
@export var world_panel_lift_offset := Vector3(-3.17, 1.39, -2.77)
@export_range(-180.0, 180.0) var world_panel_lift_yaw_deg := 180.0
## THE SIZE KNOB for this screen. A panel's on-screen size is its metre height over its distance from
## the camera, and NOTHING else — ui_scale only changes how big the UI reads WITHIN the panel, and on
## this screen it is already pinned at its ceiling (~1.77, set by the 401 px minimum width of the
## Back / Upgrades / Tuning / Test Drive row, which cannot wrap). So if the lift menu looks small,
## this is the value to raise; raising ui_scale does nothing.
@export_range(0.2, 8.0) var world_panel_lift_height := 3.0
## The lift gets its OWN ui_scale rather than sharing world_panel_ui_scale, because its
## content is WIDER than the car park's: the selector row (‹ / name / › / Repair) and the hub
## row (Back / Upgrades / Tuning / Test Drive) are HBoxes of buttons, and unlike a label an
## HBox cannot wrap — so on too narrow a canvas the row simply runs off the panel's right edge
## and "HEALTH 100%" / "TEST DRIVE" get cut in half. A lower scale = a WIDER canvas = the rows
## fit. If this screen's rows grow again, this is the dial, not the panel size.
@export_range(0.5, 4.0, 0.1) var world_panel_lift_ui_scale := 1.25
## Pans the bay shot toward the panel, which stands off the lift car's −X side (as does the
## map table, so one shift serves both). The eye is untouched — see _station_xform's LIFT
## branch on why this pans rather than moves.
##
## THIS VALUE IS A BALANCE, not "as far as possible". The panel needs ~±27° of frame at this
## range, against a horizontal half-FOV of roughly 54° (the 75° `fov` is VERTICAL; the
## horizontal extent is much wider, which is why a panel that overhangs the frame vertically
## can still fit across it). Aim much further −X and the panel centres up beautifully while
## the CAR leaves the frame — on a screen whose entire job is tuning the car in front of you.
##
## Tuned WITH world_panel_lift_offset and the eye shift below, not independently. At the
## current set the panel spans roughly −14°..+48° of frame and the car −17°..+3°, with the panel
## much the nearer of the two — so it reads as standing in front of the car's front corner,
## exactly as the car-park panel stands in front of its neighbour.
@export var world_panel_lift_camera_look_shift := Vector3(-2.24, 0.2, -1.0)
## Added to hq_lift_cam_eye while world menus are on — the ONE place a world panel moves the
## camera's position rather than just its aim, and only because the bay is genuinely too tight
## otherwise: the car's nose sits ~1.2 m from the eye, so it covers a wide wedge of screen and
## no amount of panning stops it hiding a panel behind it. Pulling back shrinks the car's
## angular size and buys room for both.
##
## −Z here moves AWAY from the garage (whose footprint starts at z=0, HQEnvironment._build_garage)
## and out into the open, so pulling back does not push the camera through a wall. Going the
## other way would.
@export var world_panel_lift_camera_eye_shift := Vector3(0.0, 0.15, -1.4)

## THE GARAGE AND TITLE PANELS.
##
## These four are anchored differently from the car park and lift, and the difference is
## deliberate: rather than welding to a car and then panning the camera to find the panel
## (which cost several tuning passes per station), each is placed relative to ITS STATION'S
## EXISTING CAMERA LOOK TARGET, so it starts out already in shot and needs no camera shift at
## all. `offset` is from that look target, in world axes.
##
## PITCH IS NEW HERE and is not decoration. The map-table camera sits ~1.8 m from the table
## looking steeply DOWN at it (hq_table_cam_eye / _look), so an upright panel would be read
## almost edge-on. A pitched panel lies back toward the camera — which also reads better: a
## briefing sheet angled on the table rather than a screen standing on it.
##
## Each station gets its own HEIGHT because their camera distances differ enormously — the
## garage shot is ~8 m out while the table camera is under 2 m, and the same panel size cannot
## serve both. `ui_scale` stays the shared world_panel_ui_scale until a station proves it needs
## its own (as the lift's unwrappable button rows did).
@export var world_panel_garage_offset := Vector3(0.0, 2.29, 8.52)
@export_range(-180.0, 180.0) var world_panel_garage_yaw_deg := 0.0
@export_range(-90.0, 90.0) var world_panel_garage_pitch_deg := -15.0
@export_range(0.2, 8.0) var world_panel_garage_height := 4.95
## The garage gets its OWN ui_scale for the same reason the lift does: its content is a ROW OF
## BUTTONS (Back / Career / Garage / Mystery Box / Online), and an HBox cannot wrap — so on too
## narrow a canvas the row runs off the panel's right edge and the last button is cut in half
## instead of reflowing. A LOWER scale gives a WIDER canvas and the row fits.
##
## Starts a little lower than the lift's 1.25 because this row is the longer of the two (up to five
## buttons, since Mystery Box only appears when one is held — so the row's width CHANGES with save
## state, and the value has to fit the widest case, not the one on screen when you tuned it).
@export_range(0.5, 4.0, 0.1) var world_panel_garage_ui_scale := 1.15
@export var world_panel_title_offset := Vector3(-5.9, 1.19, 4.32)
@export_range(-180.0, 180.0) var world_panel_title_yaw_deg := -53.7
@export_range(-90.0, 90.0) var world_panel_title_pitch_deg := -6.0
@export_range(0.2, 8.0) var world_panel_title_height := 2.14
## The title screen gets its own ui_scale for the same reason the lift and garage do: its content is
## a ROW OF BUTTONS (Exit Game / Free Roam / Settings / Start) and an HBox cannot wrap, so on too
## narrow a canvas the row runs off the panel's right edge — "START" was being cut in half. A LOWER
## scale gives a WIDER canvas and the row fits. Note the row's width is PLATFORM-DEPENDENT: Exit Game
## is skipped on web, so tune against the desktop (4-button) case, which is the wider one.
## 1.0 gives a canvas the full 16:9 of the logical height — ~711 px wide against the real screen's
## 618 (the anamorphic stretch narrows the screen, not this canvas), so the row has ~15% MORE room
## here than it does flat. At 1.15 the canvas is exactly screen width, which left no headroom and
## "START" was still being cut off.
@export_range(0.5, 4.0, 0.1) var world_panel_title_ui_scale := 1.0

@export_group("Menu / HQ")
## Garage interior footprint (m): floor X/Z extent; walls + roof are built from it.
@export var hq_garage_size := Vector2(14.0, 12.0)
## Grey concrete apron under the garage + car park: centre (XZ) and size (X, Z). Laid
## over the grass-textured ground so the lot reads as paved and the rest as field.
@export var hq_concrete_center := Vector3(0.0, 0.0, 13.0)
@export var hq_concrete_size := Vector2(48.0, 44.0)
## Scenery scatter framing the HQ clearing (HQEnvironment._build_trees / _build_bushes):
## how many billboard trees / bushes to seed in the annulus around the lot. Pure look —
## bigger = a denser clearing (and more instances per HQ build). Tests trim these to keep
## the many HQ scene builds cheap.
@export_range(0, 1000) var hq_tree_count := 320
@export_range(0, 1000) var hq_bush_count := 320
## Map table: centre position, block size, and the 3D map plane laid on its top.
@export var hq_table_pos := Vector3(-3.0, 0.0, -0.2)
@export var hq_table_size := Vector3(4.6, 0.9, 4.6)
@export var hq_map_plane_size := Vector2(4.2, 4.2)
## How close (metres, on the map plane) the view centre has to be to a pin for that pin to
## count as SELECTED. Past this the cursor holds nothing and Enter does nothing.
##
## Without a limit the cursor always snapped to the nearest pin however far away it was, so
## pressing Enter over empty ocean opened whichever rally happened to be least distant —
## a menu the player did not ask for, for a place they were not looking at.
@export_range(0.05, 3.0, 0.05) var map_select_radius_m := 0.55
## Opacity of the dotted lines drawn between rallies that unlock one another on the map
## table. 0 hides them entirely.
@export_range(0.0, 1.0, 0.01) var map_link_alpha := 0.85
## Colour of those lines (RGB only — map_link_alpha supplies the opacity).
@export var map_link_color := Color(1.0, 0.96, 0.86)
## Dash and gap length (metres, on the map plane) of those lines.
@export_range(0.005, 0.2, 0.005) var map_link_dash_m := 0.035
@export_range(0.005, 0.2, 0.005) var map_link_gap_m := 0.030
## WIDTH of the dashes, in metres on the map plane. This is the knob that actually governs
## whether the graph is readable: the links used to be drawn as PRIMITIVE_LINES, which are
## one PIXEL wide no matter the camera distance, so on a 400-px-tall render target they were
## a shimmering hairline. They are triangle strips now and have a real world width.
@export_range(0.002, 0.06, 0.001) var map_link_width_m := 0.011
## A darker line drawn UNDER each dash, slightly wider, purely for contrast. The map plane
## is a full-colour world texture at full brightness where explored, so a light line has
## nothing to separate it from pale terrain; the outline gives it an edge everywhere. Set
## the width to 0 to drop the outline pass entirely.
@export_range(0.0, 0.08, 0.001) var map_link_outline_width_m := 0.020
## Colour AND opacity of that outline (alpha is used here, unlike map_link_color).
@export var map_link_outline_color := Color(0.03, 0.02, 0.0, 0.55)
## How bright the UNEXPLORED map reads, as a fraction of its lit colour (0 = black,
## 1 = no fog at all). The terrain stays legible through it on purpose: the world should
## look like somewhere you have not been yet, not a hole in the table — the player is meant
## to be able to make out the coastline they are heading for.
@export_range(0.0, 1.0, 0.01) var map_fog_unlit_brightness := 0.4
## Width of the falloff at a lit circle's edge, in normalised map units. Softens the rim so
## the frontier reads as fog thinning out rather than a cut line.
@export_range(0.0, 0.5, 0.005) var map_fog_edge_softness := 0.05
## Map exploration (features/map-exploration.md): how far a lit source reaches, in
## NORMALISED map units (the same 0..1 space as a rally's map_pos), so the radius is
## independent of the plane's metre size. Every rally the player has completed lights a
## circle of this radius around its OWN map_pos — as does their opening rally, completed or
## not — and a rally is revealed when it falls inside any lit circle. HQ itself lights
## NOTHING (see map_hq_reveal_radius). A rally may author its own `reveal_radius` to open a
## wider frontier than this default. Bigger = the world opens faster and in bigger jumps.
@export_range(0.01, 1.0, 0.005) var map_reveal_radius := 0.16
## The radius HQ itself lights, independently of any rally. SHIPPED AT 0.0 — HQ lights
## NOTHING, and is not drawn on the map at all.
##
## It used to be 0.16, which opened the handful of pins nearest the middle on a fresh
## profile. That existed because the player had to start somewhere; they now start inside
## their own OPENING RALLY (todo/opening-rally.md), which is a starting point they drove to
## rather than one the map granted, so the pins beside HQ unlock the ordinary way like
## every other.
##
## Kept as a tunable rather than deleted: "how much does home light" is a real design
## question that may be worth revisiting, and the map tests use it to light a whole
## synthetic roster without having to complete anything. Any value above 0 puts the circle
## back — and would also want an HQ landmark on the table again: `scripts/map_house.gd`
## builds one and is kept for exactly that, currently unreferenced.
## Radius of the circle HQ itself lights, in normalised map units. 0 = HQ lights nothing.
##
## SHIPS SMALL AND NON-ZERO, which is a change from the 0.0 this had while the HQ table was the
## only hub. It went to 0 because the player used to begin INSIDE their opening rally, so the
## middle of the map was ordinary fogged ground and lighting it opened the nearest pins for
## nothing. The OVERWORLD changed that premise: the player now starts standing at the garage and
## picks their first car there, so the middle is "somewhere they already are" — the same
## justification RallyLibrary.lit_sources gives for lighting the opening rally. Left at 0 the
## fog veil darkens the screen and the frontier push shoves the car while the player is choosing.
##
## It is kept DELIBERATELY SMALL: big enough to cover the garage pad
## (overworld_pad_garage_radius_m) and no bigger, so no rally pin falls inside it and nothing is
## unlocked unearned. test_rally_library.gd pins that relationship — raise this and it fails.
@export_range(0.0, 1.0, 0.005) var map_hq_reveal_radius := 0.03
## Tuning lift: centre position + overall footprint (posts span this width; also
## the pickable click volume).
@export var hq_lift_pos := Vector3(4.0, 0.0, -1.0)
@export var hq_lift_size := Vector3(3.0, 0.35, 3.0)
## The raised beam the car actually rests on: spans the full lift width post to
## post (X = hq_lift_size.x) but is short along the car's length (Z), so it tucks
## into the gap between the front and rear wheels under the car.
@export var hq_lift_platform_size := Vector3(3.0, 0.08, 1.2)
## Height (m) the selected car is raised to on the lift (wheels hanging, as on a
## real ramp). Above the platform top.
@export var hq_lift_car_height := 1.3
## Seconds the lift takes to raise/lower the car (the slow ramp animation). 0 snaps.
@export var hq_lift_raise_time := 1.6
## Tuning-lift camera: frames the raised car off to one side so the tuning menu
## (anchored to the other side of the screen, hq.gd) doesn't cover the car. eye,
## then look target — the look is offset toward +X of the car so it sits LEFT of
## frame, leaving the right side clear for the menu panel.
##
## A FRONT THREE-QUARTER shot (it used to be the rear three-quarter). The lift car sits
## at hq_lift_pos nosing −Z, so the eye moves round to −Z — in FRONT of the car — about
## 35° off that nose axis, which shows the face and the near flank together. The front
## is the readable end of a car: it carries the grille, lights and stance that say which
## car this is, and the bay is where you choose one (the selector chevrons).
##
## It stays on the −X side because +X leaves only ~0.7 m to the garage's side wall, and
## sits ~1.7 m clear of the back wall (garage is hq_garage_size, centred on origin). The
## sight line passes OUTSIDE the front-left lift post (posts at
## x = hq_lift_pos.x ± hq_lift_size.x/2, z = hq_lift_pos.z ± the same).
@export var hq_lift_cam_eye := Vector3(1.75, 1.5, -4.3)
@export var hq_lift_cam_look := Vector3(4.0, 1.0, -1.0)

@export_group("Free Roam")
## Free roam (Test Drive) generation settings — hq.gd's _prepare_free_roam writes
## these into the live Config before the scene change. The three shape values are
## fixed ("neutral" track); the water level and layer-1 relief are rolled per entry
## inside the min/max bands below, so every entry gets a fresh landscape.
@export_range(0.0, 1.0) var free_roam_straightness := 0.5
@export_range(0.0, 1.0) var free_roam_forestiness := 0.5
@export_range(0.0, 1.0) var free_roam_tarmac_fraction := 0.5
## Random lake depth band (world Y) rolled per free-roam entry.
@export var free_roam_water_level_min_m := -15.0
@export var free_roam_water_level_max_m := -5.0
## Random large-scale relief band (terrain layer-1 amplitude) rolled per entry.
@export_range(0.0, 100.0) var free_roam_relief_min := 10.0
@export_range(0.0, 100.0) var free_roam_relief_max := 35.0

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
## Margin (m) the static backdrop extends past the reachable corridor bounds.
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

## Flat overcast grey used as background_color / fog_light_color / horizon on a
## wet stage (weather == RallyLibrary.WEATHER_RAIN). Applied by the weather look
## override, layered after the region look so rain wins. See features/weather.md.
@export var rain_background_color := Color(0.55, 0.55, 0.58)
## Dimmer, cooler ambient sky colour (upward-facing surfaces) on a wet stage.
@export var rain_sky_color := Color(0.4, 0.4, 0.44)
## Knocks the sun back on a wet stage — scales sun energy.
@export_range(0.1, 1.0) var rain_sun_energy_mult := 0.6
## Thickens the haze on a wet stage — scales fog_density.
@export_range(1.0, 4.0) var rain_fog_density_mult := 1.5
## How far the fog tints the sky on a wet stage (overrides fog_sky_affect so the
## panorama washes out into a featureless overcast dome instead of punching through).
@export_range(0.0, 1.0) var rain_fog_sky_affect := 0.9
## Darkens the road/ground albedo on a wet stage (multiplies the ground/road colour).
@export_range(0.1, 1.0) var rain_road_darken := 0.75
## Rain quads alive at once in the camera-parented particle system on a wet stage.
## Only instantiated when wet, so a dry stage carries zero added per-frame cost.
@export_range(0, 2000) var rain_particle_count := 300

## Flat dusty-tan background/fog colour on a sandstorm stage (weather ==
## RallyLibrary.WEATHER_SANDSTORM, authored only onto region == "greece" events).
## Applied by the same weather look override as rain, layered after the region
## look. See features/weather.md.
@export var sand_background_color := Color(0.72, 0.6, 0.42)
## Warm, muted ambient sky colour (upward-facing surfaces) on a sandstorm stage.
@export var sand_sky_color := Color(0.6, 0.5, 0.35)
## Knocks the sun back on a sandstorm stage — scales sun energy.
@export_range(0.1, 1.0) var sand_sun_energy_mult := 0.7
## Thickens the haze on a sandstorm stage — scales fog_density.
@export_range(1.0, 4.0) var sand_fog_density_mult := 2.0
## How far the fog tints the sky on a sandstorm stage (overrides fog_sky_affect so
## the panorama washes out into a featureless dust haze instead of punching through).
@export_range(0.0, 1.0) var sand_fog_sky_affect := 0.9
## Tints the road/ground albedo toward the dust colour on a sandstorm stage
## (lerped onto the ground/road colour, unlike rain's plain darkening multiply).
@export_range(0.0, 1.0) var sand_road_tint := 0.4
## The dust colour the road/ground albedo is LERPED toward on a sandstorm stage (by
## sand_road_tint). Named by the condition's road_tint block in WeatherLibrary, so
## the tint colour is authored data like every other weather value rather than a
## literal in world.gd — a future condition tinting toward snow-white needs no code.
@export var sand_road_tint_color := Color(0.62, 0.5, 0.32)
## Global tyre μ multiplier on a sandstorm stage (Drivetrain.surface_tire_params),
## applied the same way as rain_grip_mult so the AI field and the player agree.
## Changing this value moves every rival time (the field is generated live).
@export_range(0.1, 1.0) var sand_grip_mult := 0.9
## Dust quads alive at once in the camera-parented particle system on a sandstorm
## stage. Only instantiated when sandstorm, so a non-sandstorm stage carries zero
## added per-frame cost.
@export_range(0, 2000) var sand_particle_count := 250
## Wind speed (m/s) dust is blown at, roughly horizontally, past the camera.
@export_range(1.0, 60.0) var sand_wind_speed := 10.0
## Compass-style wind heading in degrees (0 = world +X, 90 = world +Z) the dust
## blows toward. A single fixed direction, not per-event, so "one wind direction"
## reads consistently for the whole stage regardless of which way the car is facing.
@export_range(0.0, 360.0) var sand_wind_dir_deg := 45.0

# --- Fog (weather == RallyLibrary.WEATHER_FOG) --------------------------------
# Prefixed `mist_` rather than `fog_` purely to avoid colliding with the BASE
# environment knobs `fog_density` / `fog_sky_affect` above, which every stage uses.
# Fog is a VISIBILITY condition only: it authors NO grip multiplier (so μ is exactly
# 1.0, as dry) and NO road tint (a foggy road is dry). See features/weather.md.
## Pale, LUMINOUS grey used as background_color / fog_light_color / horizon on a
## foggy stage. Deliberately BRIGHTER than rain's flat overcast — mist glows; the
## common mistake is authoring it dark enough to read as dusk.
@export var mist_background_color := Color(0.86, 0.87, 0.88)
## Bright, near-white ambient sky colour (upward-facing surfaces) on a foggy stage.
@export var mist_sky_color := Color(0.78, 0.79, 0.82)
## Sun energy on a foggy stage. Barely reduced — diffuse glare is what sells mist,
## so this stays near 1.0 while the density does the work.
@export_range(0.1, 1.0) var mist_sun_energy_mult := 0.95
## The DOMINANT fog parameter — scales fog_density hard. This is the whole effect.
@export_range(1.0, 12.0) var mist_fog_density_mult := 6.0
## How far the fog tints the sky on a foggy stage (high, like rain, so the panorama
## washes out into a featureless white dome instead of punching through the murk).
@export_range(0.0, 1.0) var mist_fog_sky_affect := 0.95

# --- Storm (weather == RallyLibrary.WEATHER_STORM) ----------------------------
# Rain's look and rain's particle kind, authored heavier, plus a crosswind and an
# occasional lightning flash. See features/weather.md.
## Global tyre μ multiplier on a storm stage — a storm is wetter than plain rain, so
## this is normally the lower of the two. Applied exactly like rain_grip_mult, so the
## AI field and the player agree. Changing it moves every rival time (the field is
## generated live).
@export_range(0.1, 1.0) var storm_grip_mult := 0.72
## Flat, dark storm-grey background/fog colour on a storm stage.
@export var storm_background_color := Color(0.42, 0.43, 0.47)
## Dim, cool ambient sky colour (upward-facing surfaces) on a storm stage.
@export var storm_sky_color := Color(0.3, 0.31, 0.36)
## Knocks the sun back on a storm stage — heavier than rain's.
@export_range(0.1, 1.0) var storm_sun_energy_mult := 0.45
## Thickens the haze on a storm stage — scales fog_density.
@export_range(1.0, 4.0) var storm_fog_density_mult := 2.2
## How far the fog tints the sky on a storm stage.
@export_range(0.0, 1.0) var storm_fog_sky_affect := 0.95
## Darkens the road/ground albedo on a storm stage (a soaked road, darker than rain's).
@export_range(0.1, 1.0) var storm_road_darken := 0.65
## Rain quads alive at once on a storm stage — heavier downpour than plain rain.
@export_range(0, 2000) var storm_particle_count := 500
## Base lateral crosswind on a storm stage: an ABSOLUTE force in newtons, applied to
## the car body (car.gd::_apply_crosswind → apply_central_force) with no mass term.
## A heavier car is therefore shoved less for free — the same force is a smaller
## acceleration — e.g. ~0.75 m/s² on a 1200 kg car, ~0.375 on a 2400 kg one.
@export_range(0.0, 4000.0) var storm_wind_strength := 900.0
## Peak ADDITIONAL gust force (newtons, as above) layered on storm_wind_strength.
@export_range(0.0, 4000.0) var storm_wind_gust := 700.0
## Compass-style heading in degrees (0 = world +X, 90 = world +Z) the storm blows
## TOWARD. Shared by the crosswind force and the rain particles' wind direction, so
## the drops visibly stream the same way the car is being pushed.
@export_range(0.0, 360.0) var storm_wind_dir_deg := 200.0
## Peak brightness multiplier of a lightning flash, applied to the storm fog/sky
## colour for storm_lightning_duration_s. Purely cosmetic (no light node exists —
## see features/rendering.md). Keep it modest: a flash that blanks the screen
## mid-corner is a gameplay event, not an effect.
@export_range(1.0, 3.0) var storm_lightning_flash := 1.45
## How long one flash takes to rise and fall, in seconds. Short.
@export_range(0.02, 1.0) var storm_lightning_duration_s := 0.18
## Shortest gap between flashes, in seconds.
@export_range(1.0, 300.0) var storm_lightning_interval_min_s := 18.0
## Longest gap between flashes, in seconds. Infrequent on purpose.
@export_range(1.0, 300.0) var storm_lightning_interval_max_s := 45.0
## Headlight-cone strength on a storm stage, 0..1 — the same knob night uses
## (night_headlight_amount), named by the storm entry's `headlights` key. A storm is
## dark enough that a driver would switch the lights on, but it is NOWHERE NEAR as
## dark as night: storm_sun_energy_mult leaves a real daytime bake underneath, and the
## cone is ADDED on top of that light term, so pushing this toward 1.0 blows the lit
## pool out to white. Keep it well below the night value — the cone should read as
## headlights visible through the murk, not as a second sun.
@export_range(0.0, 1.0) var storm_headlight_amount := 0.35

## SNOWFALL (features/weather.md). Prefixed `snowfall_` rather than `snow_` so it
## cannot collide with the snow REGION's `snow_*_grip` block above — the same
## collision-avoidance that made fog's fields `mist_*`.
##
## Deliberately authors NO grip multiplier. The snow region already owns grip in the
## corner these stages sit in; a weather multiplier on top would be a second, redundant
## lever over the same variable, and would make a snowfall stage arbitrarily slipperier
## than a dry one in the same region. Consequence: snowfall contributes nothing to
## WeatherLibrary.physics_fields, so it never re-keys the opponent cache — correct,
## since it changes no lap time.
##
## Flat, bright overcast: like fog, the common mistake is authoring snow dark enough to
## read as dusk. It is a WHITE-OUT, so these stay light.
@export var snowfall_background_color := Color(0.78, 0.80, 0.84)
@export var snowfall_sky_color := Color(0.82, 0.84, 0.88)
## Barely knocked back — a snowy sky is bright, the diffuse glare is the point.
@export_range(0.0, 2.0) var snowfall_sun_energy_mult := 0.85
## Thickens the haze into falling-snow murk. Between rain's and fog's.
@export_range(0.1, 20.0) var snowfall_fog_density_mult := 4.0
## High, so the panorama washes into a featureless white dome.
@export_range(0.0, 1.0) var snowfall_fog_sky_affect := 0.9
## Fresh snow SETTLES white on the road, so this lerps the albedo toward a colour
## (like sandstorm's dust caking) rather than darkening it the way rain does.
@export_range(0.0, 1.0) var snowfall_road_tint := 0.35
@export var snowfall_road_tint_color := Color(0.88, 0.90, 0.93)
## Flakes alive at once in the camera-parented field; only built on a snowfall stage.
@export_range(0, 4000) var snowfall_particle_count := 900
## Metres per second the flakes fall. Much slower than rain — this, more than the
## quad size, is what separates snow from grey streaks.
@export_range(0.1, 30.0) var snowfall_particle_speed := 2.4
## Fixed world-space heading the snow drifts toward (0 = +X, 90 = +Z).
@export_range(0.0, 360.0) var snowfall_wind_dir_deg := 200.0

# --- Night (weather == RallyLibrary.WEATHER_NIGHT) ----------------------------
# A DARK stage re-lit only by a fake headlight cone in front of the player's car
# (todo/night-weather-and-headlights.md). Two halves:
#   1. The LOOK block below — the same five environment knobs every other condition
#      authors. The darkening comes entirely from night_sun_energy_mult, which scales
#      the sun the terrain bakes into its vertex colours; no shader darkens anything.
#   2. The CONE fields — pushed to the shaders as global shader parameters. Its SHAPE
#      (colour, range, angles, offset, pitch, separation) is shared by every condition
#      that switches the lights on and is not in the weather table at all; only its
#      STRENGTH is per-condition, named by the table's `headlights` key.
# Night authors no grip multiplier and no wind: it is purely a look, so it changes no
# lap time. See features/weather.md.
## Near-black background / fog / horizon colour on a night stage. Not pure black —
## a slight blue lift keeps the horizon from reading as a hole in the frame, and the
## PS1 post-process quantises hard down here (banding is the known risk).
@export var night_background_color := Color(0.04, 0.05, 0.09)
## Very dim, cool ambient sky colour (upward-facing surfaces) on a night stage. This
## is the floor everything outside the headlight cone is lit by, so it must not be
## zero or unlit geometry becomes an unreadable silhouette.
@export var night_sky_color := Color(0.06, 0.07, 0.12)
## Sun energy on a night stage. THE dominant knob: this is what actually makes the
## world dark, and the cone's additive re-lighting is only readable against a low
## value here. Its range starts at 0.0 (unlike the daytime conditions, which never
## want to go this low) because night lives at the bottom of it.
@export_range(0.0, 1.0) var night_sun_energy_mult := 0.12
## Scales fog_density on a night stage. Kept LOW on purpose: fog is environment-side
## (fog_light_color), so the headlight cone cannot light it — thick haze at night
## gives a lit pool of ground under a flat grey sheet. Raise this only carefully.
@export_range(0.1, 4.0) var night_fog_density_mult := 0.8
## How far the fog tints the sky on a night stage. High, so the panorama sinks into
## the dark rather than punching a lit horizon through it.
@export_range(0.0, 1.0) var night_fog_sky_affect := 0.9
## Darkens the road/ground albedo on a night stage (albedo × amount, like rain's — a
## night road is not tinted toward a new colour, just unlit).
@export_range(0.1, 1.0) var night_road_darken := 0.7
## The sky panorama a night stage swaps in, overriding whatever the REGION chose.
## Named by the night entry's `sky_panorama` key in WeatherLibrary, so a condition
## that wants its own sky is authored data rather than a branch in world.gd. Empty
## string = keep the region's sky.
@export_file("*.jpg", "*.png") var night_sky_panorama := "res://textures/sky-night.jpg"
## The sky every stage falls back to when its region does not name one (home and
## home_coast do not). Re-seeded on every stage boot BEFORE the region and weather
## looks are layered on, for the same reason `albedo_color` and `tarmac_color` are:
## the PanoramaSkyMaterial is a shared sub-resource of main.tscn with no
## resource_local_to_scene, so without a re-seed a Greece or night sky would follow
## the player into the next home stage.
@export_file("*.jpg", "*.png") var default_sky_panorama := "res://textures/sky_field.png"

# Headlight cone. The SHAPE fields below do NOT go through the weather table: they are
# uploaded once per frame as GLOBAL SHADER PARAMETERS (hl_pos / hl_dir /
# headlight_amount and friends) and evaluated analytically in the shaders — there is no
# light node anywhere in this renderer (features/rendering.md). The cone's STRENGTH is
# the exception: it is per-condition, so each condition that switches the lights on
# names its own field through the table's `headlights` key (night_headlight_amount
# below, storm_headlight_amount above).
## Headlight-cone strength on a NIGHT stage, 0..1 — named by the night entry's
## `headlights` key. Night is the darkest condition in the table, so this is the top
## of the range; every other condition that lights up authors a lower value. At
## exactly 0 the shaders' `lit` term is exactly 0, making every cone uniform a
## BIT-FOR-BIT NO-OP — which is what lets the cone ship in shaders that every unlit
## stage, the podium and the HQ also use. The per-frame driver early-outs when no
## condition authors a cone at all, and the strength is reset to 0 unconditionally
## when entering any non-stage scene (shader globals persist across scene changes).
@export_range(0.0, 1.0) var night_headlight_amount := 1.0
## Colour the cone ADDS to the light term (ALBEDO = surface * (baked + this * lit)).
## Additive, never a multiply: the bake is already near-black, so a multiplicative
## cone could not re-light it. Warm-white reads as headlights against the cool dark.
@export var headlight_color := Color(1.0, 0.94, 0.78)
## How far the cone reaches, in metres, before it attenuates to nothing. Sets how far
## ahead the player can read the road, so it is a genuine difficulty knob.
@export_range(1.0, 200.0) var headlight_range_m := 45.0
## HALF-angle in degrees of the cone's fully-lit core. Converted to a cosine before
## upload (the shader compares against dot(dir, to_fragment), never an angle).
@export_range(1.0, 89.0) var headlight_inner_deg := 12.0
## HALF-angle in degrees where the cone has faded to nothing; the falloff runs from
## the inner half-angle to this one. Also uploaded as a cosine. Must be larger than
## headlight_inner_deg or the cone has no soft edge.
@export_range(1.0, 89.0) var headlight_outer_deg := 26.0
## Offset from the car's origin to the cone's emission point, in the car's own space:
## X = right, Y = up, Z = FORWARD (the driver notes: the car's forward is -basis.z, so
## the driver adds this Z along forward, not along +Z). Puts the origin on the bonnet
## line rather than the car's centre, so the cone does not light the car's own nose.
@export var headlight_offset_m := Vector3(0.0, 0.6, 1.8)
## Downward aim of the cone, in degrees below horizontal. THIS is the knob that sets
## how far ahead the lit pool starts, and it matters more than it looks: with a
## perfectly horizontal cone the ground only enters it where the OUTER edge finally
## drops to ground level — about headlight_offset_m.y / tan(outer) metres past the
## apex, with the bright inner core starting further out still — which reads as the
## light starting several metres in front of the bumper. Real headlights are aimed
## down for exactly this reason. Raise it to pull the pool toward the car, lower it
## to throw the light further down the road.
@export_range(0.0, 45.0) var headlight_pitch_deg := 7.0
## Distance between the two headlamps, as a FRACTION OF THE FIELDED CAR'S WIDTH —
## not an absolute figure, so a wide GT throws a visibly wider pair than a kei car
## and the lights always sit in a believable place on whatever body is fielded. The
## driver multiplies this by the car's own width (`car.gd` → `half_width`, doubled),
## the same body dimension the replay wheel-cam rig measures its clearance from.
## Around 0.6 puts the lamps inboard of the corners, where headlights actually live.
##
## The pair shares aim, range, angles and colour — only the apex differs — and the
## two cones are combined with max() rather than added, so the overlap straight
## ahead stays at lamp brightness instead of reading as a third, brighter light.
##
## SET TO 0 for a single cone: the shader then skips the second cone entirely, on a
## branch taken uniformly across the whole draw. So this is both the look knob and
## the cost knob — 0 is measurably cheaper on terrain, which is the only surface that
## evaluates the cone per-fragment.
@export_range(0.0, 1.5) var headlight_separation_frac := 0.62

@export_group("Terrain Layers")
# Three stacked perlin noise layers: wavelength in metres, amplitude in metres.
## Layer 1 wavelength (m): spacing of the largest, rolling hills.
@export_range(1.0, 1000.0) var terrain_layer1_wavelength := 100.0
## Layer 1 amplitude (m): height of the largest, rolling hills.
@export_range(0.0, 100.0) var terrain_layer1_amplitude := 10.0
## Layer 2 wavelength (m): spacing of the mid-scale undulations.
@export_range(1.0, 200.0) var terrain_layer2_wavelength := 50.0
## Layer 2 amplitude (m): height of the mid-scale undulations.
@export_range(0.0, 10.0) var terrain_layer2_amplitude := 0.0
## Layer 3 wavelength (m): spacing of the finest surface bumps.
@export_range(1.0, 200.0) var terrain_layer3_wavelength := 3.0
## Layer 3 amplitude (m): height of the finest surface bumps.
@export_range(0.0, 10.0) var terrain_layer3_amplitude := 0.0

@export_group("PS1 Look")
## Logical render height of the WHOLE frame (3D and UI): a positive value renders
## at that fixed height; 0 follows the window height (device-native). Crisper
## image at higher values / native; UI/HUD/touch controls are laid out in logical
## units so they draw smaller as this rises. Applied by DisplayStretch
## (scripts/display_stretch.gd); a benchmark's explicit resolution-sweep override
## still wins while a benchmark is active. NOTE: the UI is authored against the
## original 400-tall canvas and re-inflated by UITheme.UI_SCALE — keep that
## constant equal to render_height / 400 when retuning this (see
## scripts/ui_theme.gd → "UI scale", then re-run tools/build_ui_theme.gd).
@export var render_height := 0
@export var virtual_resolution := Vector2(480, 360)  # independent LOOK value (PS1 dither grid), deliberately decoupled from the window/viewport height (DisplayStretch.DESIGN_HEIGHT reads display/window/size/viewport_height) — do not "fix" this to match it
## Purely stylistic horizontal (anamorphic) stretch of the WHOLE frame — world
## and UI alike. 1.0 = off; 1.2 draws everything 20% wider than reality. Applied
## globally by the DisplayStretch autoload (scripts/display_stretch.gd).
@export_range(0.5, 2.0) var horizontal_stretch := 1.15
@export var chassis_color := Color(0.85, 0.2, 0.15)
@export var cabin_color := Color(0.25, 0.3, 0.4)
@export var wheel_color := Color(0.12, 0.12, 0.12)

# Colour grade over the stage's 3D frame — the Race Driver: GRID look (less
# saturated, more contrasty, tinted a light warm brown). Pushed onto
# shaders/ps1_post_process.gdshader by world.gd's _ready, and applied there
# BEFORE the dither/quantise so the 5-bit banding lands in the graded palette.
# Grades the world, props and sky ONLY: the HUD/menus sit on CanvasLayers drawn
# after the post-process pass, and so do the speed lines. No per-target variants
# (unlike virtual_resolution) — a grade is resolution-independent.
## Master strength of the whole grade. 0 = off (exact passthrough, vignette
## included), 1 = full. Retuning any value below needs a stage restart.
@export_range(0.0, 1.0) var grade_amount := 0.5
## 1 = colours untouched, 0 = fully greyscale.
@export_range(0.0, 1.0) var grade_saturation := 0.7
## Contrast around mid-grey. 1 = untouched. Pushing this hard makes the 5-bit
## banding visible in the sky gradient and on flat terrain (the dither only
## masks so much).
@export_range(0.5, 2.0) var grade_contrast := 1.15
## Tint pushed into the dark end of the image — a desaturated brown gives GRID's
## muddy warm blacks. Only the HUE matters: the shader divides out the tint's own
## luminance so it can't change overall brightness.
@export var grade_shadow_tint := Color(0.62, 0.52, 0.40)
## Tint pushed into the bright end — a warm cream for GRID's yellowed highlights.
@export var grade_highlight_tint := Color(1.0, 0.94, 0.78)
## Corner darkening strength. 0 = no vignette.
@export_range(0.0, 1.0) var grade_vignette_strength := 0.25
## Normalised radius (1.0 = the edge midpoints) at which the corner darkening
## starts to ramp in; it reaches full strength in the corners.
@export_range(0.0, 1.5) var grade_vignette_radius := 0.75

@export_group("Speed Lines")
# Anime "edge speed lines" overlay (features/rendering.md): black streaks
# radiating inward from the screen edges, ramping in with the car's speed.
# Driven by scripts/speed_lines.gd over shaders/speed_lines.gdshader.
## Master switch for the speed-lines overlay.
@export var speed_lines_enabled := true
## Streak colour. Black is the standard manga look.
@export var speed_lines_color := Color(0.0, 0.0, 0.0, 1.0)
## Speed (km/h) at which the streaks start to appear. ~80 km/h is realistically
## flat out in this game, so the ramp is tuned to fill across that band.
@export_range(0.0, 300.0) var speed_lines_start_kmh := 60.0
## Speed (km/h) at which the streaks reach full strength (≈ the car's top speed).
@export_range(0.0, 400.0) var speed_lines_full_kmh := 78.0
## Cap on overall strength (alpha) at and above speed_lines_full_kmh. Kept well
## below 1.0 so the streaks stay translucent and never fully obscure the screen.
@export_range(0.0, 1.0) var speed_lines_max_intensity := 0.2
## How many angular streaks ring the screen; higher = more, finer lines.
@export_range(8.0, 256.0) var speed_lines_density := 28.0
## Innermost normalised screen radius a streak can reach — higher keeps more of
## the centre clear (shorter streaks). Streaks run solid from here out to the edge.
@export_range(0.0, 2.0) var speed_lines_inner_radius := 0.55
## Outermost start radius — streaks start somewhere in [inner, outer], so the gap
## between the two sets how much the streak lengths vary.
@export_range(0.0, 2.0) var speed_lines_outer_radius := 0.9
## Per-streak flicker rate (discrete steps/sec): each streak jumps to a new random
## brightness this many times a second, giving a choppy hand-drawn flicker rather
## than a smooth pulse.
@export var speed_lines_flicker_speed := 14.0
## Ease rate of the intensity ramp (per second); higher snaps in/out faster.
@export_range(0.5, 30.0) var speed_lines_response := 6.0

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
## 0 = flat (unlit), 1 = full shading. Strength on billboard trees. Independent
## of terrain_light_amount but conventionally kept equal so trees match the ground.
@export_range(0.0, 1.0) var foliage_light_amount := 1.0
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
## Bias toward straighter, easier turns during track generation, in [0, 1]. 0 = no
## bias (corners chosen freely, the default for free-roam); higher favours gentler
## corners and longer connecting straights, yielding a less twisty stage. Set per
## rally event by RallyLibrary.event_straightness — earlier-game events run higher
## so their stages are easier. Changes the generated SHAPE, so opponent target times
## are derived with the same value (RallySession._compute_event_data).
@export_range(0.0, 1.0) var track_straightness := 0.0
## Length (m) of the straight runoff road appended AFTER the finish line, so the
## car has room to skid to a stop past the arch. Treated as a real road piece: it is
## collision-checked in the track generator (the finish corner backtracks if the
## runoff won't fit) and baked into the terrain like the rest. The finish line/arch
## and 100% progress stay at the END of the generated track, NOT the end of this
## runoff. 0 disables it.
@export var track_runoff_m := 20.0
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
## Neutral multiplier over the ground texture — the floor material's `albedo_color`
## BASELINE. Re-seeded onto the material on every stage boot (world.gd._ready), which
## is what makes the weather road tint idempotent: it always modifies the authored
## value rather than the previous stage's already-tinted result. A region may override
## it with a "terrain_tint" look key.
@export var terrain_tint := Color(1, 1, 1)
## Lateral distance from the road centerline, in metres, within which track
## progress accrues. Generous on purpose — you can run wide onto the verge / cut
## across rough ground (rally!) and still bank the metres. The distance is measured
## against a LOCAL window of the centerline (TrackProgress._local_closest_offset),
## so this is independent of `track_clearance` and won't snap onto a different
## track section. NOT a reset trigger — the off-track reset is time-based
## (`off_road_reset_timeout_s`). It does still size the precomputed terrain
## corridor (TerrainManager.corridor_coords), which is why it stays modest.
@export var track_progress_max_dist_m := 50.0
## Master switch for the off-track auto-reset. Progress tracking (for the HUD)
## runs regardless; this only gates the snap-back-onto-road behaviour.
@export var off_track_reset_enabled := true
## Extra metres beyond the road EDGE (`track_width * 0.5`) the car must be before
## it counts as off the road and the reset clock starts. The road is a fixed width,
## so "off the road" is a clean geometric test; this margin keeps a wheel clipping
## the verge, or a slide that hangs the tail out, from starting the clock.
@export_range(0.0, 20.0) var off_road_margin_m := 2.0
## Seconds the car may stay CONTINUOUSLY off the road (past the edge + margin above)
## before it is snapped back to the last on-road pose. This is the off-track reset:
## it is driven by time, not by how far out the car gets, so a car bogged in a ditch
## a couple of metres off the verge — which can neither drive back on nor get far
## enough out to trip a distance leash — always recovers. Returning to the road
## zeroes the clock, so a quick cut across the inside costs nothing.
@export_range(1.0, 30.0) var off_road_reset_timeout_s := 6.0
## Seconds off the road before the HUD shows the OFF TRACK warning + countdown.
## A grace period: brief excursions (running wide, a jump landing on the verge)
## are normal rally driving and shouldn't flash a warning every corner. Must be
## below `off_road_reset_timeout_s` or the warning never appears before the reset.
@export_range(0.0, 30.0) var off_road_warning_after_s := 2.0
## Absolute world Y below which the car is considered to have fallen off the
## world entirely (a void with no water plane) and is snapped back to the last
## on-road pose (TrackProgress._best_reset), regardless of lateral distance from
## the road. Used as a fallback floor; on tracks with water (`water_enabled`),
## the per-track `track_water_level_m` (below) is the primary trigger instead,
## since a track's flood height varies per rally event and can sit well above
## this fixed floor.
@export var fell_off_world_y := -50.0
## Master switch for the corner-cutting time penalty (features/corner-cutting.md).
## When off, cuts are never billed and cut_penalty_s() is always 0.
@export var cut_penalty_enabled := true
## Metres of along-track progress in a SINGLE tick above which the tick counts as
## a corner cut. The car's nearest point on the centerline can only advance about
## as far as the car moved that tick (~1-2 m even flat out), so normal driving
## never approaches this; cutting across the neck of a corner flips the nearest
## point to the far leg and jumps the progress tens of metres in one tick. Sits
## in the dead zone between the two. Metres beyond this are billed as stolen.
@export_range(2.0, 50.0) var cut_jump_threshold_m := 5.0
## Fixed reference speed (m/s) that converts stolen metres to seconds:
## penalty_s = stolen_m / this. Fixed (not the car's live speed) so braking
## mid-cut can't shrink the penalty.
@export_range(1.0, 100.0) var cut_reference_speed_mps := 25.0

@export_group("Water")
## Master on/off for roadside lakes (features/lakes.md). Off ⇒ no water is built
## and the track generator ignores water entirely (existing events unaffected).
@export var water_enabled := false
## Flood height (world Y): terrain below this fills with water. Set per rally event
## by event["water_level"]. Higher ⇒ more/bigger lakes in the same valleys.
@export var track_water_level_m := 0.0
## Small vertical margin (m) above the water level a cell must clear to carry road
## or the start — keeps the road just off the waterline rather than skimming it.
## Kept small: it's ADDED to water_level in the reject test, so a large value would
## exclude most of the (low-amplitude) terrain and starve the track search.
@export_range(0.0, 2.0) var water_shore_clearance_m := 0.3
## Depth (m) below the per-track `track_water_level_m` at which the car is
## considered to have fallen INTO the water (submerged, not just splashing at
## the shore/surface) and is snapped back to the last on-road pose. Only
## checked while `water_enabled` is on, since `track_water_level_m` is
## meaningless otherwise.
@export var water_submersion_reset_depth_m := 3.0
## Extra linear drag applied to the chassis while in water (soft hazard — the car
## slows but can still drive out; no reset).
@export_range(0.0, 30.0) var water_drag := 6.0
## Deep-water colour (flat, opaque — the surface is a solid PS1 colour block).
@export var water_color := Color(0.16, 0.32, 0.5)
## Shore/highlight colour blended in by the faint ripple.
@export var water_shore_color := Color(0.32, 0.52, 0.62)
## Speed of the scrolling ripple animation on the water surface.
@export_range(0.0, 2.0) var water_ripple_speed := 0.15
## Strength of the faint moving sparkle band on the water surface.
@export_range(0.0, 1.0) var water_sparkle_strength := 0.25

@export_group("Cliffs")
## Master toggle for track-side cliffs & drops (features/terrain.md). Off ⇒ the
## terrain bake skips the cliff pass entirely (identity behaviour, zero cost).
@export var cliff_enabled := true
## Along-track period, in metres, of the 1-D camber noise that drives the cliffs —
## how quickly a cliff swaps sides. GLOBAL (same for every event); only the height
## is scaled per event (cliff_amount / RallyLibrary.event_cliffiness).
@export_range(5.0, 500.0) var cliff_wavelength_m := 100.0
## Scales the raw camber noise before the [-1, 1] clamp. Higher ⇒ the signal spends
## more time saturated at ±1 (frequent full-height cliffs); lower ⇒ mostly gentle.
@export_range(0.1, 5.0) var cliff_gain := 1.6
## Global height ceiling, in metres: the cliff height (and equal drop depth) at
## |camber| = 1 for a maximally cliffy event (cliffiness = 1). Scaled down per event
## by cliff_amount.
@export_range(0.0, 40.0) var cliff_max_height_m := 12.0
## Horizontal run, in metres, from the road-edge band out to full height. Small ⇒
## steep near-walls; large ⇒ gentle banks. (Heightfield terrain → no true overhangs.)
@export_range(0.5, 40.0) var cliff_run_m := 2.0
## Horizontal run, in metres, from full height back to natural grade, so the feature
## is a localized berm/ditch that returns to grade (no backdrop seam), not a shelf.
@export_range(0.5, 40.0) var cliff_fade_m := 30.0
## Radius, in metres, of the post-bake morphological "open" that knocks down thin tall
## cliff walls (e.g. the wall a hairpin's inner crook would leave). Walls narrower than
## ~2× this in either axis are removed; wider cliffs/drops survive. 0 disables.
@export_range(0.0, 20.0) var cliff_open_radius_m := 4.0
## Runtime per-event scale on cliff_max_height_m, in [0, 1]. Written by RallySession
## from the event's cliffiness; the value shipped here is only the fallback for
## standalone/editor main.tscn runs.
@export_range(0.0, 1.0) var cliff_amount := 1.0

@export_group("Road Markings")
## Painted lane lines (two solid edge lines + a dashed centre line) laid along the
## TARMAC sections of the track so tarmac reads as tarmac (gravel stays bare). A
## static unshaded mesh built once at generation; see scripts/road_markings.gd.
@export var road_markings_enabled := true
## Paint colour — a slightly weathered off-white rather than pure white so the
## lines sit in the scene instead of glowing. Tinted per-vertex by the same baked
## terrain light as the floor, so tune it against the lit road in-game.
@export var road_marking_color := Color(0.82, 0.82, 0.78)
## Width of each painted stripe, in metres.
@export_range(0.05, 0.5) var road_marking_width_m := 0.12
## How far inside each road edge (half the track width) the edge lines sit, in
## metres. Keep it above road_marking_width_m * 0.5 so the stripe stays fully on
## the road rather than spilling onto the verge.
@export_range(0.1, 1.5) var road_marking_edge_inset_m := 0.4
## Painted length of each centre-line dash, in metres.
@export_range(0.2, 10.0) var road_marking_center_dash_m := 1.5
## Unpainted gap between centre-line dashes, in metres.
@export_range(0.2, 10.0) var road_marking_center_gap_m := 3.0
## Height the paint is laid above the road surface, in metres — just enough to
## avoid z-fighting with the (near-flat) road mesh without looking like it floats.
@export_range(0.0, 0.5) var road_marking_height_m := 0.05
## Minimum tarmac weight (0 = gravel, 1 = tarmac) a point needs before it is
## painted, so the lines appear only on the tarmac side of the surface switch.
@export_range(0.0, 1.0) var road_marking_tarmac_threshold := 0.5
## Arc-length step, in metres, at which the centerline is sampled to build the
## paint mesh. Smaller = smoother lines on tight corners at more vertices.
@export_range(0.1, 2.0) var road_marking_sample_step_m := 0.4

@export_group("Tire Marks")
## Gravel ruts laid behind the wheels while driving on the road (features/tire-marks.md).
@export var tire_marks_enabled := true
## BOTH MARK COLOURS ARE PURE BLACK, AND THE ALPHA IS THE KNOB. A mark is a black
## ribbon laid at partial opacity, so what the player sees is the ground DARKENED rather
## than a fixed grey painted over it. That is the whole point: these materials are
## unshaded (nothing dims for free — see weather_lit), so a constant authored grey stayed
## exactly as bright at night and on snow as it was on a sunlit gravel road, and read as
## a stripe of paint sitting on top of the world instead of a scuff in it. Black at a
## fraction of opacity tracks whatever is underneath it for free, in every condition,
## with no per-weather plumbing at all.
##
## So the RGB carries no information any more and should stay (0, 0, 0): the alpha below
## is the per-surface CEILING — how dark a fully-worked tire can ever get on this
## surface. tire_marks.gd multiplies it by the segment's own strength (gravel by tire
## FORCE, tarmac by GRIP USAGE — unchanged, and still the two different questions those
## surfaces ask), so the ceiling sets the top of that range and the strength picks a
## point in it.
##
## Gravel is the shallower of the two because a rut is displaced surface, while a tarmac
## skid is deposited rubber and goes darker at its worst.
@export var tire_mark_color := Color(0.0, 0.0, 0.0, 0.5)
## Tarmac skidmark ceiling — laid only where a driven wheel spins on the tarmac (the
## gravel ruts use tire_mark_color instead). Black like the above; see its note.
@export var tire_mark_tarmac_color := Color(0.0, 0.0, 0.0, 0.6)
## FALLBACK width of a wheel's mark ribbon, in metres. A mark is normally exactly as wide as
## the tyre that laid it — `wheel_width_front` / `wheel_width_rear` above, which car.gd writes
## from the fielded car's spec, so a staggered car leaves wider rear marks than front ones. This
## value is used only where that width is unavailable (a spec authoring none, or a flat test
## fixture). See tire_marks.gd -> _tire_width_of.
@export var tire_mark_width_m := 0.22
## Don't lay marks below this car speed (m/s) — keeps the countdown/parked car clean.
@export var tire_mark_min_speed_mps := 2.0
## Distance the wheel must travel before a new ribbon segment is added, in metres.
@export var tire_mark_segment_step_m := 0.5
## Tire-mark segment spacing on a web TOUCH device. Each segment is an emit plus an
## eventual ArrayMesh surface rebuild, so doubling the spacing halves both. This
## composes with the per-rendered-frame upload coalescing in tire_marks.gd: coalescing
## only wins where physics outruns rendering (a capped or slow build), whereas a bigger
## step cuts the work at any frame rate.
@export var tire_mark_segment_step_m_web_touch := 1.0
## Max segments retained per wheel (ring buffer); older marks recycle. ~100 m at
## the default step — bounds memory, and the chase cam looks forward anyway.
@export var tire_mark_max_segments := 200
## Height the ribbon sits above the wheel's contact patch, in metres (lifts it
## clear of the road surface so it never z-fights or clips under the terrain).
@export var tire_mark_ground_offset_m := 0.05
## Extra lateral allowance beyond the road half-width within which marks still lay
## (so the verge of the gravel still marks), in metres.
@export var tire_mark_gravel_margin_m := 0.3
## Fade each mark's opacity with how hard its tire is working, instead of laying every
## segment at its surface's ceiling. WHERE marks appear is identical either way, only how
## solid they are changes. See features/tire-marks.md.
##
## OFF IS A DEBUG / PERF FALLBACK, NOT A LOOK. It puts the ribbons back in the opaque
## pass, which discards alpha entirely — and since both mark colours are now pure BLACK
## (intensity lives in the opacity), that renders solid black trails rather than the flat
## grey it used to. Reach for it to measure what the transparent pass costs, not to ship.
@export var tire_mark_alpha_enabled := true
## GRAVEL ruts: the tire force (newtons, combined longitudinal + lateral) at which a rut
## reaches full opacity. Opacity ramps linearly from nothing at 0 N to solid here, so a
## cruising tire leaves a faint scuff and a loaded one digs a dark rut. Roughly the peak
## a hard-working tire pulls, so most of the range is actually used.
@export var tire_mark_gravel_full_force_n := 4000.0
## TARMAC skids: grip usage (1.0 = on the limit — see Drivetrain.grip_fraction) at which
## a skid first shows. Below this a tire is rolling within its limits and paved road takes
## no mark at all, which is why tarmac starts high instead of at zero like gravel.
@export_range(0.0, 2.0) var tire_mark_tarmac_grip_min := 0.8
## Grip usage at which a tarmac skid reaches full opacity. Between this and
## tire_mark_tarmac_grip_min the skid fades in.
@export_range(0.0, 3.0) var tire_mark_tarmac_grip_max := 1.0
## Opacity below which a segment is not laid at all (the ribbon breaks instead). A quad
## this faint is invisible but still rasterises and still sorts in the transparent pass,
## so skipping it is free frame time. Keep small — this is a cull threshold, not a look.
@export_range(0.0, 0.5) var tire_mark_min_alpha := 0.03


@export_group("Wheel Particles")
## Cheap debris flung from the driven wheels when they spin faster than the ground
## (features/wheel-dust.md). ONE MultiMesh of billboarded quads serves every
## surface — each particle carries its own colour, size and roll, picked at emit
## time: grey clods on gravel, slim green blades on grass, nothing on tarmac.
@export var wheel_particles_enabled := true
## Clod colour — matched to the gravel road (gravel.jpg averages ~0.42 grey).
## Unshaded, so tune it against the lit road in-game.
@export var wheel_particle_color := Color(0.42, 0.40, 0.36)
## Hard cap on live particles (the ring-buffer size + MultiMesh instance count).
## Shared across ALL surfaces, so total draw cost is bounded wherever the car is;
## oldest particles recycle first.
@export_range(16, 2000) var wheel_particle_max := 50
## Edge length of each square gravel clod billboard, in metres.
@export var wheel_particle_size_m := 0.12
## Blade colour for grass thrown up off the road footprint on the home world —
## matched to textures/grass.jpg (samples average ~(0.35, 0.44, 0.19); the most
## common quantised pixel clusters land right on that). Region overrides (e.g.
## Greece's dry olive ground) supply their own colour via
## RegionLibrary look_of()["grass_particle_color"] — see wheel_particles.gd.
@export var wheel_particle_grass_color := Color(0.35, 0.44, 0.19)
## Width of a grass blade billboard, in metres (the slim axis).
@export var wheel_particle_grass_width_m := 0.03
## Length of a grass blade billboard, in metres (the long axis).
@export var wheel_particle_grass_length_m := 0.22
## Per-particle random brightness variation, as a +/- fraction of the base colour
## (0 = every particle identical). Breaks a burst up so it reads as many separate
## bits of debris rather than one flat smear. Free — each instance already carries
## its own colour.
@export_range(0.0, 1.0) var wheel_particle_color_jitter := 0.18
## Longitudinal grip usage a driven wheel must exceed before it throws any debris.
## 1.0 means "past the fore/aft limit": the tire has actually broken traction and is
## tearing material loose, rather than merely slipping a little while still gripping.
## Below 1.0 a rolling wheel would spray dirt it isn't shifting. See
## Drivetrain.wheel_long_grip_usage and features/wheel-dust.md.
@export_range(0.0, 3.0) var wheel_particle_min_long_grip := 1.0
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


@export_group("Engine Smoke")
## Grey smoke that puffs from the bonnet each time a damaged engine misfires
## (EngineSmoke, features/engine-smoke.md). Its own small MultiMesh pool, separate
## from the wheel dust. Off above the misfire health threshold (no cuts = no smoke).
@export var engine_smoke_enabled := true
## Hard cap on live smoke particles (ring-buffer size + MultiMesh instance count) —
## a small pool, since smoke is a light haze, not a spray.
@export_range(4, 500) var engine_smoke_max := 48
## Smoke particles emitted per misfire cutout (one puff).
@export_range(1, 20) var engine_smoke_per_cut := 5
## Cap on misfire cuts turned into puffs per physics tick, so a rapid burst of cuts
## can't flood the pool in one frame.
@export_range(1, 10) var engine_smoke_max_puffs_per_tick := 2
## Smoke colour (unshaded billboard). Alpha is the starting opacity; each particle
## fades to nothing over its life.
@export var engine_smoke_color := Color(0.30, 0.30, 0.32, 0.55)
## Edge length of a smoke billboard at birth, in metres (it grows over its life).
@export var engine_smoke_size_m := 0.35
## How much a smoke puff grows over its lifetime (final size = birth size x this).
@export_range(1.0, 8.0) var engine_smoke_growth := 3.0
## How long each smoke particle lives before recycling, in seconds.
@export var engine_smoke_lifetime_s := 1.5
## Upward rise speed of the smoke, in m/s (buoyant lift).
@export var engine_smoke_rise_mps := 1.4
## Random sideways/scatter speed added to each puff particle, in m/s.
@export var engine_smoke_scatter_mps := 0.5
## Bonnet emit point in the car's LOCAL space (metres): front (−Z) and top (+Y) of
## the chassis, so smoke rises from the engine bay. Added to the car origin each puff.
@export var engine_smoke_offset := Vector3(0.0, 0.4, -1.2)
## Synthetic (out-of-event) puffing for display cars whose engine isn't running (HQ
## car park / lift): seconds between puffs at the WORST damage (severity 1, at 0 HP)
## and at the LIGHTEST damage (severity → 0, just past the health threshold). The
## interval lerps between them with severity, so a wreck smokes far more than a
## lightly-damaged car. A fully-healthy car never puffs.
@export_range(0.05, 3.0) var engine_smoke_synthetic_interval_min := 0.35
@export_range(0.1, 6.0) var engine_smoke_synthetic_interval_max := 1.4


@export_group("Exhaust Flames")
## Master switch for the exhaust backfire flames (features/exhaust-flames.md). Off
## means the pool does no per-frame work at all.
@export var exhaust_flames_enabled := true
## Per-car exhaust pipe placements, as { car_id: [pipe, ...] } — one entry per pipe, so a
## single-exit car has one and a quad-exit car four.
##
## A pipe is either a Vector3 (position only, flame pointing straight back) or a Vector4
## whose xyz is that same position and whose w is the pipe's YAW in DEGREES. Both forms
## may be mixed freely in one list, so giving one car an angle never forces the rest to be
## rewritten.
##
## Position is car-LOCAL metres: +Z REARWARD (forward is −Z), +Y up, +X right.
## Yaw rotates the flame in the HORIZONTAL plane: 0 points straight back, POSITIVE turns
## it toward the car's RIGHT (+X), negative toward its left. Side exits want a few degrees
## outward — e.g. Vector4(0.94, -0.22, -0.1, 20.0) for a right-hand sill pipe.
##
## This lives here rather than in CarLibrary (next to bonnet_cam_offset, where per-car
## body data otherwise belongs) for ONE reason: this resource is what the F8 hot-reload
## re-reads, and a .gd script is not. Dialling a pipe in by eye needs the tweak-reload-
## look loop that only a resource gives — see the exhaust lab in features/debug-tools.md.
## Once a car's pipes are dialled in, its entry is settled data and could reasonably
## move to CarLibrary.
##
## A car with no entry here falls back to exhaust_offset_fallback, mirrored across the
## centreline into two pipes.
@export var exhaust_offsets: Dictionary = {}
## Fallback single-pipe position for a car with no exhaust_offsets entry, in car-local
## metres. Its Z is IGNORED — the fallback pins itself to the rear of the car's actual
## wheelbase instead, so it lands near the tail on a long car and a short one alike.
## Mirrored to +X and −X, giving an unlisted car a plausible twin exit.
@export var exhaust_offset_fallback := Vector3(0.35, 0.28, 0.0)
## How many generated flame frames to cycle between. More than one is what keeps a
## sustained flame (nitrous) from sitting static; a handful is plenty, since the swap
## picks a DIFFERENT frame each time rather than looping in order.
@export_range(1, 12) var exhaust_flame_frames := 4
## Seconds each frame shows before swapping to another. Short — this is a flicker.
@export_range(0.01, 1.0) var exhaust_flame_frame_seconds := 0.05
## Resolution of each generated frame, in pixels (square). Small suits the look: these
## are nearest-filtered PS1-era textures, not smooth gradients.
@export_range(8, 256) var exhaust_flame_texture_px := 64
## How long one rev-limiter bang stays lit, in seconds. RETRIGGERABLE — each further bang
## re-arms it, so bouncing off the limiter reads as rapid flicker rather than one long
## flame. Nitrous ignores this and stays lit for as long as it delivers.
@export_range(0.01, 1.0) var exhaust_flame_pop_seconds := 0.09
## Flame size in metres: how far it reaches out of the pipe (length, along the car's
## rearward +Z) and how wide it is at its widest.
@export var exhaust_flame_length_m := 0.45
@export var exhaust_flame_width_m := 0.16
## How far the flame wanders sideways toward its tip, as a fraction of the texture width.
## 0 is a perfectly straight flame; the wander is what differs most between frames, so
## this is the main dial for how lively the flicker reads.
@export_range(0.0, 0.5) var exhaust_flame_wobble := 0.12
## Width of the white-hot core near the pipe mouth, as a fraction of the flame's local
## half-width. 0 removes the core and leaves only the hot->cool gradient.
@export_range(0.0, 1.0) var exhaust_flame_core_fraction := 0.45
## Overall tint/brightness multiplier applied to the generated frames. Additive blending
## means this reads as intensity — lower it if the flames blow out at night.
@export var exhaust_flame_tint := Color(1.0, 1.0, 1.0, 1.0)
## Flame colour at the pipe MOUTH (hot) and at the TIP (cooling as it dissipates). Each
## frame lerps between them along its length. Additive-blended, so these read as light.
@export var exhaust_flame_color_hot := Color(1.0, 0.86, 0.45, 1.0)
@export var exhaust_flame_color_cool := Color(1.0, 0.30, 0.06, 1.0)


@export_group("Trees")
## Billboard tree sprites scattered around each track turn.
## Master switch for stage foliage — trees, bushes and the bush hit volume. The
## benchmark's vegetation toggle drives this (features/benchmark.md); normal play
## leaves it on. Unlike trees_per_turn = 0 it skips the scatter work entirely.
@export var vegetation_enabled := true
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
## Tree size in metres: width (x) by height (y). Trees are opaque billboard
## cutouts, scaled so the card's height matches y and its width matches x.
@export var tree_size_m := Vector2(7.5, 7.5)
## Minimum per-instance size multiplier for HOME billboard trees
## (`textures/tree.png`): each one is scaled by a random
## factor in [this, 1.0] (hashed off its position), so a home stand varies in height
## instead of every tree being identical. 1.0 disables the jitter. The region-forced
## billboard path has its own floor (`region_tree_billboard_min_scale`).
@export_range(0.1, 1.0) var tree_billboard_min_scale := 0.3
## Vertical offset (m) applied to HOME billboard trees to sink them into the
## ground: negative pushes the card's bottom edge below the terrain (hiding the
## seam where the trunk meets the slope), positive lifts it. Region billboards have
## their own offset (`region_tree_billboard_ground_offset_m`).
@export_range(-3.0, 3.0) var tree_billboard_ground_offset_m := -0.5
## Aspect-jitter amplitude for HOME billboard trees: on top of the uniform size
## jitter, width and height each get an independent random multiplier in
## [1 - this, 1 + this], so some trees read taller-and-narrower and others
## shorter-and-wider. This dial sets how DRASTIC the shape variation is; 0 disables
## it. Region billboards have their own (`region_tree_billboard_aspect_jitter`).
@export_range(0.0, 0.9) var tree_billboard_aspect_jitter := 0.15
## Half-extent (m) in X/Z of each tree's box hitbox — a square trunk footprint.
@export_range(0.05, 5.0) var tree_collision_radius_m := 0.5
## Height (m) of each tree's box hitbox.
@export_range(0.5, 20.0) var tree_collision_height_m := 4.0
## Approach speed (km/h) at or above which crashing into a tree topples it and
## removes its hitbox. The car still comes to a stop against the tree as it does
## today; the tree then falls over and stops colliding, so you can drive on
## through where it stood. Below this speed a tree stays a solid obstacle. Felling is
## now decoupled from damage (damage is keyed to deceleration, not the contact), so this
## only governs when a tree tips over, independent of HP. 0 disables felling.
## This is now the FULL-SIZE threshold: a tree of visual size `s` fells at
## `tree_fell_speed_kmh * s`, so smaller trees topple sooner (see TreeFall).
@export_range(0.0, 200.0) var tree_fell_speed_kmh := 45.0
## Seconds a felled tree takes to tilt from upright to flat on the ground. Purely
## a look value (the hitbox is gone the instant it's felled).
@export_range(0.1, 5.0) var tree_fell_duration_s := 2.0
## Maximum fraction of shed forward momentum a felled tree returns to the car,
## approached as tree size -> the smallest tree. A felled full-size tree returns
## 0 (hard stop, as before); a small tree returns up to this fraction so the car
## ploughs on through. 0 disables plough-through entirely (every felled tree
## hard-stops). See TreeFall.plough_keep and features/trees.md.
@export_range(0.0, 1.0) var tree_plough_keep_max := 0.8
## Distance (m) past which trees are fully culled — the value used on every target
## EXCEPT a web TOUCH device (see tree_render_distance_web_touch_m). Defaults near
## the loaded terrain extent (TerrainManager.RADIUS=3, CHUNK_M=50 -> ~175 m to the
## ring edge; this default sits inside that). world.gd resolves the
## effective value once at boot via tree_render_distance_for() and writes it back
## here, so all downstream readers (foliage, signs, spectators, arches) see it.
@export_range(10.0, 500.0) var tree_render_distance_m := 120.0
## Foliage/world-prop cull distance (m) on a web TOUCH device (phone/tablet browser
## — the same low-end target as the 30fps default target_fps_web). Kept shorter than
## the desktop/native distance to hold the frame budget; picked by
## tree_render_distance_for(web, touch).
@export_range(10.0, 500.0) var tree_render_distance_web_touch_m := 60.0
## Width (m) of the dithered dissolve band just before the render cutoff.
@export_range(0.0, 100.0) var tree_render_fade_m := 15.0
## Near-camera dissolve: canopy fragments closer than this (m) to the camera are
## fully dithered away, so a tree the camera pushes inside stops blocking the view
## (the canopy is double-sided for render robustness, so culling can't do this).
@export_range(0.0, 10.0) var tree_near_fade_start_m := 0.5
## Distance (m) by which the near-camera canopy dissolve is fully solid again.
## Must be >= tree_near_fade_start_m; the gap is the dither band.
@export_range(0.1, 20.0) var tree_near_fade_end_m := 3.0
## Grid cell size (m) trees are binned into for rendering. Each bin is its own
## MultiMesh, so the engine can drop far bins to the mesh's importer LODs and
## cull them past tree_render_distance_m. Smaller = finer LOD/cull granularity
## but more draw calls; ~25 m balances both against the ~75 m loaded terrain.
@export_range(5.0, 100.0) var tree_bin_size_m := 25.0
## Height (m) the ground-cover bush mesh (models/vegetation/groundcover_opaque.glb)
## is scaled to. Bushes are 3D low-poly meshes rendered through TreeMeshField
## (binned, LOD/visibility-culled) but without collision; everything else about
## their scatter/render reuses the tree_* params.
@export_range(0.1, 5.0) var bush_height_m := 0.6
## Albedo tint multiplied into the bush mesh (on top of the tone-matched foliage
## texture and the per-instance baked terrain light). Lifted a touch above the
## model's authored green so the ground cover reads a bit more against the grass.
@export var bush_tint := Color(1.25, 1.25, 1.25)
## Size (width x height, m) of a region billboard tree — the star-shaped cutout a
## `tree_mix` species selects with the `region` profile (e.g. Greece's
## tree-greece.webp). Larger than the home tree_size_m: a big, low Mediterranean
## canopy that stands in for the home region's trees on that map.
@export var region_tree_billboard_size_m := Vector2(4.0, 4.0)
## Minimum per-instance size multiplier for region billboard trees: each one is
## scaled by a random factor in [this, 1.0] (hashed off its position), so a Greece
## stand varies in height instead of every tree being identical. 1.0 disables the
## jitter. Only affects the region-forced billboard path (e.g. tree-greece.webp).
@export_range(0.1, 1.0) var region_tree_billboard_min_scale := 0.5
## Vertical offset (m) applied to REGION billboard trees (e.g. Greece) to sink them
## into the ground: negative pushes the card's bottom edge below the terrain (hiding
## the seam where the trunk meets the slope), positive lifts it. The home billboard
## path has its own offset (`tree_billboard_ground_offset_m`).
@export_range(-3.0, 3.0) var region_tree_billboard_ground_offset_m := -0.5
## Aspect-jitter amplitude for REGION billboard trees (e.g. Greece): on top of the
## uniform size jitter, width and height each get an independent random multiplier in
## [1 - this, 1 + this], so silhouettes vary in shape (taller-and-narrower vs
## shorter-and-wider). Sets how DRASTIC that variation is; 0 disables it. The home
## billboard path has its own (`tree_billboard_aspect_jitter`).
@export_range(0.0, 0.9) var region_tree_billboard_aspect_jitter := 0.15


@export_group("Rocks")
# Roadside boulders — low-poly Kenney meshes scattered like the bushes but WITH
# collision. Density is per-region (RegionLibrary's `rock_density`), so only the
# shared shape/size/hitbox knobs live here. See features/rocks.md.
## Master switch for the rock scatter, mirroring vegetation_enabled for trees and
## bushes. Off removes the meshes AND their hitboxes.
@export var rocks_enabled := true
## Base rock GROUP count per track turn, before the region's `rock_density` multiplier.
## Counts clusters, not rocks — each one fans out into rock_group_min..max boulders
## (see TreeScatter.cluster), so the rock count is roughly this times the mean group
## size. Deliberately far below trees_per_turn: rocks carry collision, so a dense field
## turns the verge into a wall, and they are meant to read as occasional hazards.
@export_range(0.0, 100.0) var rock_groups_per_turn := 1.0
## Smallest number of rocks in a group.
@export_range(1, 12) var rock_group_min := 4
## Largest number of rocks in a group. Clamped up to rock_group_min if authored below
## it, so an inverted pair degrades to a fixed group size rather than to no rocks.
@export_range(1, 12) var rock_group_max := 7
## Radius (m) a group's rocks fan out to around their anchor. Companions land in the
## OUTER HALF of this, so it sets how tight a cluster reads — too small and metre-wide
## boulders interpenetrate, too large and the group stops reading as one outcrop.
##
## It has to move WITH the group size. Companions share a ring, so the spacing between
## them is roughly the ring's circumference over the count: raising rock_group_max
## without raising this packs more boulders onto the same ring until they intersect.
@export_range(0.0, 40.0) var rock_group_radius_m := 9.0
## Radius (m) around each turn anchor that rocks scatter into. Mirrors
## tree_spawn_radius_m; together with rock_groups_per_turn it sets the scatter grid pitch.
@export_range(1.0, 100.0) var rock_spawn_radius_m := 25.0
## Positional jitter of a rock within its scatter cell (0 = a hard lattice, 1 = the
## full cell). Mirrors tree_jitter.
@export_range(0.0, 1.0) var rock_jitter := 0.7
## Height (m) of a rock at species scale 1.0 — THE size knob for the whole scatter.
## Each species multiplies this by its own entry in Foliage.ROCK_HEIGHT_SCALES,
## because the three models have very different aspect ratios (see that constant).
@export_range(0.1, 12.0) var rock_height_m := 2.25
## How far a rock is sunk INTO the ground, as a fraction of its own height. Rocks are
## whole boulders resting on the surface as authored, which reads as if they were
## dropped on the terrain rather than sitting in it; sinking the field buries the base
## so the silhouette meets the ground instead of balancing on it.
##
## A fraction rather than a metre value so it survives resizing — the same reasoning as
## rock_collision_radius_frac. Applied per species (each field is offset by its own
## height x this), and the collision body sinks with the mesh, since it is a child of
## the same field node. 0 sits them flat on the surface.
@export_range(0.0, 0.8) var rock_sink_frac := 0.32
## Collision-box half-width as a fraction of the rock's actual scaled horizontal
## half-extent. Below 1.0 so the box is inscribed in the silhouette rather than
## boxing its corners — clipping a rock's edge is far less jarring than hitting a
## wall of air beside it. The box is derived from the mesh, so resizing rocks
## resizes their hitbox automatically.
@export_range(0.1, 1.5) var rock_collision_radius_frac := 0.8
## Body colour of a rock, written into its vertex colours at mesh-merge time.
## Replaces Kenney's authored orange; a neutral, desaturated stone grey that sits in
## the same tonal band as the tree billboards rather than competing with them.
@export var rock_body_color := Color(0.42, 0.41, 0.39)
## Colour of the rock's TOP cap (Kenney authors it as a separate "grass" material).
## Replaces their turquoise with a muted lichen green, so the cap reads as weathering
## rather than as a second object sitting on the stone.
@export var rock_cap_color := Color(0.36, 0.40, 0.31)


@export_group("Roadside Signs")
# A-frame (wet-floor) roadside turn-arrow signs along the stage (todo/roadside-signs.md).
# Few per stage (tens), so they are individual nodes, not a MultiMesh. Authored face
# textures (the pacenote arrow boards) go in sign_textures. Start/finish are the
# inflatable arches, not signs, and the stage is no longer split into signed sectors.
## Master switch for the roadside signs. The benchmark's signs toggle drives this
## (features/benchmark.md); normal play leaves it on.
@export var signs_enabled := true
## Number of equal arc-length sectors the stage is split into. No longer drives any
## signs (sector boards were dropped); kept only as the stage timer's per-sector
## split hook (SignLayout.sector_offsets, todo/stage-start-and-end.md §5).
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
# Knock-over launch, mirroring the spectator ragdoll (todo/roadside-signs.md). On
# contact the sign is masked off the car and flung along the car's travel direction
# instead of colliding with it — a fake collision that lets it tumble on the terrain
# without ever bogging the vehicle down.
## Fraction of the car's speed imparted to a struck sign. The whole impulse scales
## with car speed, so slowly nudging a sign barely moves it.
@export_range(0.0, 3.0) var sign_knock_speed_factor := 1.0
## Small lower clamp (m/s) on the launch speed, so a crawl still tips the sign rather
## than nothing at all — kept low so slow contact stays gentle.
@export_range(0.0, 20.0) var sign_knock_speed_min := 1.0
## Upper clamp (m/s) on the launch speed, so a fast hit doesn't fling it absurdly far.
@export_range(0.0, 60.0) var sign_knock_speed_max := 26.0
## Upward lift as a FRACTION of the launch speed (not a fixed m/s), so the lift scales
## with the car's speed: a slow hit stays low, a fast hit lofts the sign. ~0.35 ≈ 19° up.
@export_range(0.0, 2.0) var sign_knock_lift_ratio := 0.35
## Peak tumble spin (rad/s) at full launch speed; scaled down toward zero as the car
## slows, so a gentle bump produces a gentle tumble.
@export_range(0.0, 30.0) var sign_knock_spin := 11.0

@export_group("Corner Barriers")
# Solid crash barriers along the OUTSIDE of the stage's sharp corners
# (features/barriers.md). Planned by BarrierLayout, built by BarrierField from 2 m
# BarrierSection modules stitched end to end. The look follows the road surface: the
# steel armco guardrail on gravel, the precast concrete jersey rail on tarmac.
# Unlike the roadside signs these are SOLID and in the damage obstacle group — hitting
# one costs HP.
## Master switch for the corner barriers. The benchmark's barriers toggle drives this
## (features/benchmark.md); normal play leaves it on.
@export var barriers_enabled := true
## Length of one barrier module, in metres — the pitch a run is stitched at.
@export_range(0.5, 8.0) var barrier_section_length_m := 2.0
## Clear gap, in metres, between the visible road edge and the barrier's nearest face.
## Measured to the face, so the armco and the wider-footed jersey rail leave the same gap.
## KEEP `this + the barrier's own depth` (0.6 m at the jersey's foot) UNDER
## `2 x tree_road_margin_m`, or trees start spawning inside the barrier's footprint —
## the tree scatter rejects on the road inflated by that margin and knows nothing about
## the barrier. See features/barriers.md.
@export_range(0.0, 4.0) var barrier_road_gap_m := 0.4
## How far, in metres, a run extends before the corner entry and past its exit, so the
## barrier starts before the car needs it rather than exactly on the apex.
@export_range(0.0, 20.0) var barrier_lead_m := 5.0
## Tarmac-ness (0..1, as TerrainManager.surface_at reports) at or above which a module
## uses the concrete jersey rail instead of the steel armco.
@export_range(0.0, 1.0) var barrier_tarmac_threshold := 0.5
## How far, in metres, each module is sunk into the ground. Small: enough that a rigid
## module on slightly uneven verge buries its foot rather than floating above it.
@export_range(0.0, 0.5) var barrier_sink_m := 0.06
## How far OUT FROM THE ROAD EDGE, in metres, the hill-or-drop probe reads the ground.
## A barrier only goes up where the land falls away; where the corner is cut into a bank
## the hillside already stops the car. This MUST clear the road's flatten band
## (`track_transition_cells`, 3 m by default) — inside it the carve pass has blended the
## ground to road height, so every corner would read as flat.
@export_range(1.0, 30.0) var barrier_slope_probe_m := 5.0
## How far, in metres, the ground outboard of the barrier must sit BELOW the road before
## the stretch counts as a drop worth guarding. Also the flat-ground cutoff: level verge
## gets no barrier.
@export_range(0.0, 20.0) var barrier_drop_min_m := 1.0
## How far, in metres, the ground outboard of the barrier may rise ABOVE the road before
## the stretch counts as banked (and so gets no barrier). Small but non-zero: terrain
## noise puts a verge a few cm above road level even where the land genuinely falls away
## further out, and a zero tolerance would veto those on a coin flip.
@export_range(0.0, 5.0) var barrier_hill_tolerance_m := 0.15
## Shortest barrier worth building, in modules. A one- or two-module stub reads as debris
## on the verge rather than as a barrier, so stretches shorter than this are dropped.
@export_range(1, 20) var barrier_min_run_modules := 3

@export_group("Finish Arch")
# The inflatable rally gates straddling the road (features/finish-arch.md): a
# FINISH arch at the centerline end (100% progress, so crossing it ends the
# stage) and a matching START arch at the car's start line. Placed by world.gd.
## Whether to build the finish arch at the end of the stage.
@export var finish_arch_enabled := true
## Whether to build the start arch at the start line.
@export var start_arch_enabled := true
## Clear gap, in metres, between each road edge and the inside face of a leg.
## An arch's opening = track_width + 2 x this, so the legs stand clear of the
## road and the car drives through cleanly. Shared by both gates.
@export_range(0.0, 6.0) var finish_arch_road_margin_m := 1.5


@export_group("Spectators")
# Crowds of low-poly people trackside that react to the car (todo/roadside-spectators.md):
# one group at the start, one at the end, and one at a random mid-stage point. While
# upright they are pure agent data + a MultiMesh (no physics bodies, not obstacles);
# a strike flips one to a single-capsule ragdoll launched along the car's velocity.
## Build the spectator crowds. 0-size groups also disable them.
@export var spectators_enabled := true
## People per group.
@export_range(0, 200) var spectator_group_size := 50
## The mid-stage group spawns at a seeded progress fraction in this range.
@export_range(0.0, 1.0) var spectator_mid_progress_min := 0.30
@export_range(0.0, 1.0) var spectator_mid_progress_max := 0.70
## Length (m) of the crowd band along the track — the group spreads this far up and
## down the road (split half ahead, half behind the anchor point).
@export_range(2.0, 120.0) var spectator_area_length_m := 36.0
## Total width (m) of the crowd band across the track. It straddles the road centre,
## so the carriageway stays clear and spectators line BOTH verges.
@export_range(2.0, 60.0) var spectator_area_width_m := 24.0
## Extra gap (m) kept off the carriageway when placing — road footprint is inflated
## by this before rejecting standing positions on it.
@export_range(0.0, 10.0) var spectator_road_margin_m := 1.0
## Minimum comfortable spacing (m) between neighbours — initial placement and the
## separation steering both use it. ("Don't like being too close.")
@export_range(0.1, 5.0) var spectator_separation_m := 0.5
## How close (m) a tree must be for a spectator to avoid spawning by / steer from it.
@export_range(0.1, 10.0) var spectator_tree_avoid_m := 1.5
## Detection radius (m) within which spectators flee the car.
@export_range(0.5, 30.0) var spectator_flee_radius_m := 10.0
## Distance (m) car→spectator at which the spectator is knocked over (ragdoll).
@export_range(0.2, 5.0) var spectator_knock_radius_m := 1.2
## Top speed (m/s) a spectator can move while fleeing/shuffling.
@export_range(0.5, 12.0) var spectator_max_speed_mps := 6.5
## Acceleration (m/s^2) toward the steering target.
@export_range(1.0, 60.0) var spectator_accel_mps2 := 18.0
## Only the group within this distance (m) of the car runs steering (LOD); the
## others stand still until the car approaches.
@export_range(10.0, 400.0) var spectator_active_radius_m := 90.0
## Crowd-sim decimation: run the per-member steering only every Nth physics tick
## (delta accumulates so motion is unchanged over time), staggered across groups.
## Ambient crowd doesn't need a 60 Hz update; 2 halves the sim cost. Pure perf knob.
@export_range(1, 6) var spectator_sim_interval := 2
## Steering weights (relative pull of each preference).
@export_range(0.0, 10.0) var spectator_w_separation := 1.5
@export_range(0.0, 10.0) var spectator_w_flee := 4.0
@export_range(0.0, 10.0) var spectator_w_road := 3.0
@export_range(0.0, 10.0) var spectator_w_obstacle := 2.0
@export_range(0.0, 10.0) var spectator_w_anchor := 0.6
## Ragdoll launch: target speed = car speed x factor, clamped to [min, max] (m/s).
## The whole impulse scales with car speed, so a slow nudge barely moves them — the
## min is just a small floor so a crawl still topples them rather than nothing at all.
@export_range(0.0, 3.0) var spectator_knock_speed_factor := 0.8
@export_range(0.0, 20.0) var spectator_knock_speed_min := 1.0
@export_range(0.0, 60.0) var spectator_knock_speed_max := 22.0
## Upward lift as a FRACTION of the launch speed (not a fixed m/s), so the lift scales
## with the car's speed: a slow hit stays low, a fast hit lofts them. ~0.3 ≈ 17° up.
@export_range(0.0, 2.0) var spectator_knock_lift_ratio := 0.3
## Peak tumble spin (rad/s) at full launch speed; scaled down toward zero as the car
## slows, so a gentle bump produces a gentle tumble.
@export_range(0.0, 30.0) var spectator_knock_spin := 9.0
@export_range(1.0, 200.0) var spectator_ragdoll_mass_kg := 65.0
## How many ragdoll bodies each crowd pre-builds at load time and then recycles, so a
## car-into-crowd hit reuses an existing RigidBody3D (+ capsule + mesh instance) instead
## of constructing one mid-drive. A hit that outruns the pool still falls back to building
## a fresh body, so this bounds the PREBUILT set, never the number of ragdolls.
@export_range(0, 32) var spectator_ragdoll_pool_size := 8
## Distance (m) behind the car at which a settled ragdoll is freed.
@export_range(10.0, 300.0) var spectator_despawn_behind_m := 70.0


@export_group("Opponent Wrecks")
# A crashed-out rival is shown as a wrecked car by the roadside for the event they
# wrecked in (features/opponent-wrecks.md): the ACTUAL car they drove, frozen (hitbox
# kept) with a small standing crowd around it and lazy engine smoke. The wreck ITSELF
# (how often / how many) is decided in RallyLibrary (OPPONENT_WRECK_CHANCE); these knobs
# only shape the roadside presentation.
## Stage roadside wrecks at all. Off = a crashed rival still DNFs, just isn't shown.
@export var opponent_wrecks_enabled := true
## Gap (m) between the road edge (half track width) and the NEAR side of the wreck —
## the minimum; the placement then searches OUTWARD from here for the flattest patch
## so the wreck rests on level ground beside the road instead of buried in a slope.
@export_range(0.0, 20.0) var opponent_wreck_road_offset_m := 1.3
## Extra yaw (rad) the wreck is skewed by, off the road direction, so it reads as
## crashed rather than parked. Randomised per wreck within ±this.
@export_range(0.0, 3.14159) var opponent_wreck_yaw_skew := 1.2
## People in the small gathering around the wreck (a static standing cluster, no AI).
@export_range(0, 40) var opponent_wreck_crowd_size := 7
## Radius (m) of the ring the onlookers stand in around the wreck.
@export_range(0.5, 12.0) var opponent_wreck_crowd_radius_m := 3.2
## Conservative wreck-car footprint (m) used to sample verge flatness and keep the
## car clear of the carriageway: half-width and half-length of the sampled box.
@export_range(0.1, 5.0) var opponent_wreck_footprint_half_w := 1.1
@export_range(0.1, 10.0) var opponent_wreck_footprint_half_len := 2.0
## Half-angle (rad) of the crescent the onlookers are spread across, about the outward
## (verge) direction — ±this. ~2.0 rad ≈ ±115°, covering the verge side + flanks but
## never the road-ward hemisphere between the wreck and the carriageway.
@export_range(0.0, 3.14159) var opponent_wreck_crowd_arc_half := 2.0


@export_group("Star Economy")
## Stars: what a REPAIR costs (features/star-economy.md). Flat, whatever the damage —
## one star returns a car to full health and straightens its wheels.
##
## Deliberately CHEAP. Repair is a ritual and a small tax, not an economic wall: the real
## cost of wrecking is the lost rally result (a DNF, no podium, no progress), and pricing
## the repair steeply would punish the same mistake twice. Flat rather than per-HP so the
## player never has to arithmetic their way to "is it worth fixing".
@export_range(0, 30) var star_cost_per_repair := 1
## Stars: what a COPY of an already-discovered upgrade part costs, fitted to another car.
##
## Upgrades are car-bound, so this is the sink that spreads a part you won once across the
## garage — and being per-car-per-part it is effectively bottomless, which is what stops a
## late-game star balance becoming dead weight. The first copy is free: it is fitted to the
## car that won the part-unlock rally (features/prize-rallies.md).
@export_range(0, 30) var star_cost_per_part := 2
## Stars: what converting ONE car to ONE non-stock drive layout costs (RWD/AWD/FWD).
##
## The conversion CAPABILITY is global — won once, on the rally gating `drivetrain_swap`,
## and available to every car from then on. This is the per-car, per-layout bill, and it is
## paid once: a layout a car has bought is free to switch back to thereafter, exactly as a
## bought part is free to toggle. Returning to the car's own stock layout is always free and
## never charged. See features/upgrade-catalogue.md.
@export_range(0, 30) var star_cost_per_drive_mode := 2


@export_group("Performance")
## Render frame cap (FPS) on desktop targets. 0 = uncapped. Physics runs
## independently at the project physics tick. Mobile uses target_fps_mobile and
## web uses target_fps_web instead (see target_fps_for()).
@export_range(0, 240) var target_fps := 60
## Render frame cap (FPS) on NATIVE mobile targets (not web — see target_fps_web).
## The native APK has a real audio thread and performs fine at 60. 0 = uncapped.
@export_range(0, 240) var target_fps_mobile := 60
## Render frame cap (FPS) on the WEB target specifically. Lower than desktop/native
## for thermal/battery headroom, but bounded by audio: the web export is
## SINGLE-THREADED, so audio is serviced by the main loop (no audio thread) and a
## lower frame rate drains the generator + WebAudio buffers between frames, causing
## gaps/crackle. 30 is viable only because the audio buffers (engine_audio.gd's
## per-device buffer_seconds() and audio/driver/output_latency.web in project.godot) are sized to
## bridge a ~33 ms inter-frame gap plus jitter — raise those before lowering this
## further. 0 = uncapped. See features/rendering.md and features/engine-audio.md.
@export_range(0, 240) var target_fps_web := 30
## Texture LOD bias for the foliage/ground shaders: positive values pull distant
## sampling toward cheaper (lower) mip levels, saving texture bandwidth on
## tile-based mobile GPUs. Keep modest so the alpha-cutout silhouettes don't blur.
@export_range(0.0, 4.0) var texture_lod_bias := 0.75

# --- Web-touch quality tier (todo/mobile-web-performance.md) -----------------
# Every field below follows the SAME split as tree_render_distance_m /
# terrain_lod_bands_m: a web TOUCH device (phone/tablet browser — the low-end
# target) gets the *_web_touch value, and EVERY other target (native mobile,
# desktop, and desktop BROWSER) gets the base value. Resolve them through the
# matching *_for(web, touch) function below, never by branching on Platform at
# the call site — one notion of "mobile", not several.
#
# Defaults are deliberately equal to the base value where the change is not yet
# wired, so adding the field is a no-op until the owning item lands.

## Engine-synth mix rate (Hz) on a web TOUCH device. The synth is a per-sample
## GDScript DSP loop, so its CPU cost scales with THIS number, not with frame
## rate — on wasm it is the largest single script cost in the game. Halving it
## halves that cost; the audible price is dulled crackle/turbo-whistle layers
## (Nyquist drops to ~5.5 kHz) rather than a lost engine fundamental.
## Changing this changes the generator buffer frame counts — re-check the
## benchmark's skip_count() after. See engine_audio.gd's MIX_RATE.
@export_range(8000.0, 48000.0) var engine_mix_rate_web_touch := 22050.0

## Ground-plane subdivision for the HQ apron and the podium floor. These are flat
## planes whose only per-vertex variation is the tarmac feather weight, so the
## subdivision buys nothing except feather-band resolution. The mesh is now a
## non-uniform grid (coarse lattice + a fine ring around each pad edge), so this is
## the COARSE lattice density only — the feather band is sampled finely regardless.
## At the old uniform 240 the HQ ground alone was ~115k triangles, drawn continuously
## on the game's first screen; at 24 it is ~3.2k with a finer feather band.
@export_range(8, 512) var ground_subdiv := 24
## Ground-plane subdivision on a web TOUCH device. Widen the tarmac feather
## slightly if the band reads too hard at the lower resolution.
@export_range(8, 512) var ground_subdiv_web_touch := 16

## Terrain LOD far-cutoff distances (metres), one per level boundary — the
## coarsest level draws to the ring edge with no cutoff, so this has (levels - 1)
## entries (TerrainLod.LOD_STRIDES has `levels`). The display mesh decimates by
## distance so far ground costs a fraction of the near-flat 1 m tessellation; the
## engine crossfades between levels via visibility_range. See features/terrain.md.
## This set is the higher-quality one used on every target EXCEPT a web TOUCH device
## (bands pushed farther out so finer terrain persists to match the longer desktop
## render distance). world.gd resolves the effective set once at boot via
## terrain_lod_bands_for() and writes it back here before apply_terrain_lod().
@export var terrain_lod_bands_m: PackedFloat32Array = PackedFloat32Array([60.0, 100.0, 115.0, 120.0])
## Terrain LOD bands used on a web TOUCH device (the low-end / 30fps target) — the
## finer levels are dropped sooner to hold the frame budget. Picked by
## terrain_lod_bands_for(web, touch).
@export var terrain_lod_bands_web_touch_m: PackedFloat32Array = PackedFloat32Array([40.0, 70.0, 80.0, 90.0])
## Downward skirt depth (metres) on each terrain chunk's LOD meshes, hiding the
## crack where neighbouring chunks show different levels. Invisible under fog.
@export_range(0.0, 20.0) var terrain_lod_skirt_m := 3.0
## Chunk ring (Chebyshev distance, in chunks) around the car that carries live
## collision. Farther loaded chunks are render-only, so their heightfield is not a
## broadphase entry. 1 = the inner 3×3.
@export_range(0, 4) var terrain_collision_ring := 1
## When true, far corridor chunks skip generating the full-res grid at precompute and
## prebake only the LOD levels their distance from the racing line can ever display.
## Off = full precompute (every chunk full-res) — useful to A/B the loading cost.
@export var terrain_precompute_prune_enabled := true
## Extra reach (metres) added to a chunk's closest-possible camera distance when
## deciding which LOD levels it can show. Must exceed the largest replay-camera offset
## from the car (finish-replay roadside/flyby shots ~40 m) so a replay never exposes a
## pruned level. Larger = more conservative (keeps finer levels farther out).
## Was 40.0. Lowered to 25.0 (2026-07-29) after actually reading replay_camera.gd:
## the 40 was assumed to protect the FLYBY shot, but FLYBY is c + (6, 2, 6) ~= 8.7 m.
## The real maxima are HIGH_WIDE (0, 14, 16) ~= 21.3 m and ORBIT ~= 9.6 m. ROADSIDE's
## 35/40 m constants are ALONG THE ROAD — the plant sits on the car's own travel line,
## so it barely changes distance-to-centerline, which is what the chunk classification
## measures. 25 keeps ~4 m over the true worst case, classifies fewer chunks full-res,
## and drops detail_ring() from 3 to 2 on desktop.
## If a replay shot ever shows unbuilt terrain, RAISE THIS FIRST.
@export_range(0.0, 200.0) var terrain_precompute_safety_slack_m := 25.0
## Defer each full-res chunk's FINEST LOD level instead of prebaking it for the whole
## corridor, rebuilding it on demand as chunks enter the detail ring.
##
## DEFAULT OFF (prebake every level at load) since 2026-07-30, on EVERY target
## including web — deliberately NOT gated per-platform. Deferring saves VRAM but pays
## for it with a mid-drive hitch: each on-demand rebuild is a measured ~6.2 ms, of
## which ~67% is the 8 dictionary lookups per vertex in TerrainManager's
## _vertex_color_row / _surface_uv2_row over 51x51 vertices, and a chunk crossing
## queues a whole row of them (drained at terrain_detail_builds_per_frame).
##
## Windowed A/B on the benchmark stage, same seed (see features/terrain.md ->
## "Lazy finest LOD level"):
##   lazy (on)  -> frame p99 11.03 ms, 1% low  90.6 fps, VRAM +9.5 MB, cache 12.3 MB
##   prebake    -> frame p99  4.52 ms, 1% low 221.3 fps, VRAM +35.1 MB, cache 10.7 MB
## So prebaking costs ~+25.6 MB VRAM and SAVES ~1.6 MB RAM (the retained `l0_light`,
## kept only to feed the lazy rebuild, becomes unnecessary) for a 59% better p99 and a
## 2.4x better 1% low. Turn back ON only if a real device runs out of VRAM — that is
## the trade this flag exists to express, in that direction.
@export var terrain_lazy_finest_lod := false
## Finest-level rebuilds allowed per rendered frame. A rebuild is a measured ~6.2 ms,
## and a chunk boundary crossing brings a whole row in at once, so building them all in
## one frame hitches; 1 clears a crossing in a handful of frames, well before the car
## reaches them. Only reached when terrain_lazy_finest_lod is ON — with the default
## (prebake) the detail queue stays empty, so this is the escape-hatch path's knob.
@export_range(1, 16) var terrain_detail_builds_per_frame := 1


# --- Value snapshots (the live config's IDENTITY is load-bearing) -------------
#
# The active car — plus its Drivetrain and EngineSim — holds the live GameConfig BY
# REFERENCE (car.gd `config`, which for the player car IS `Config.data`), while the HUD,
# engine audio and save layer read `Config.data`. So code that needs to save and restore
# the config around a mutation must copy VALUES back into the same object; assigning
# `Config.data = <a duplicate>` silently splits the two, and the car then writes an object
# nothing else reads any more (the bug that left a turbo fitted in the pre-race Upgrades
# menu working but gauge-less — see start_line.gd `_spawn_grid`).
#
# `duplicate(true)` is not a value-complete snapshot either: the LIVE engine fields
# (peak_torque, redline_rpm, engine_cylinders, …) are plain non-@export vars, so
# Resource.duplicate() resets them to their declared defaults instead of preserving the
# fielded values. Both functions below walk the SCRIPT property list, so every field is
# captured and restored regardless of whether it is exported.

## Every script variable on this config as a { property_name: value } map. Arrays and
## dictionaries are deep-copied, so the snapshot never shares mutable state with the live
## object. Pair with restore_values().
func snapshot_values() -> Dictionary:
	var snap := {}
	for prop in get_property_list():
		if not (int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var value: Variant = get(prop["name"])
		if value is Array or value is Dictionary:
			value = value.duplicate(true)
		snap[prop["name"]] = value
	return snap


## Copy a snapshot_values() map back onto THIS config, in place — never reassign the
## object the rest of the game is holding (see the note above). Arrays/dicts are
## duplicated again so the live config doesn't start sharing state with the snapshot.
func restore_values(snapshot: Dictionary) -> void:
	for prop_name in snapshot:
		var value: Variant = snapshot[prop_name]
		if value is Array or value is Dictionary:
			value = value.duplicate(true)
		set(prop_name, value)


# Per-axle spring rate: the overall suspension_stiffness split front/rear by the
# static weight fraction, so each axle's rate is proportional to the load it carries
# and the car sits LEVEL at rest (compression = load / rate is then equal front and
# Frame cap to apply for the current target: a web TOUCH device (phone/tablet
# browser) gets its own ceiling (target_fps_web, kept lower but audio-bounded —
# see the field); native mobile the thermal ceiling (target_fps_mobile); desktop
# — including a DESKTOP browser (web but not a touch device) — the higher one
# (target_fps). Web-touch takes precedence since is_mobile_or_web() is also true
# on web. Pure so world.gd can pass Platform queries and tests can pin any branch.
# 0 = uncapped.
func target_fps_for(mobile_or_web: bool, web: bool = false, touch: bool = true) -> int:
	if web:
		return target_fps_web if touch else target_fps
	return target_fps_mobile if mobile_or_web else target_fps


# Foliage/world-prop cull distance for the current target: a web TOUCH device
# (phone/tablet browser — the same low-end target as target_fps_web) gets the
# shorter tree_render_distance_web_touch_m; every other target (native mobile,
# desktop, desktop browser) gets the longer tree_render_distance_m. Pure so
# world.gd resolves it once at boot and tests can pin either branch.
func tree_render_distance_for(web: bool, touch: bool) -> float:
	return tree_render_distance_web_touch_m if (web and touch) else tree_render_distance_m


# Terrain LOD bands for the current target, split the same way as the render
# distance above: web-touch gets the tighter terrain_lod_bands_web_touch_m, all
# other targets the higher-quality terrain_lod_bands_m.
func terrain_lod_bands_for(web: bool, touch: bool) -> PackedFloat32Array:
	return terrain_lod_bands_web_touch_m if (web and touch) else terrain_lod_bands_m


# Engine-synth mix rate for the current target, split the same way: a web TOUCH
# device gets engine_mix_rate_web_touch, every other target the full rate. Pure
# so engine_audio.gd resolves it once and tests can pin either branch.
func engine_mix_rate_for(web: bool, touch: bool, full_rate: float) -> float:
	return engine_mix_rate_web_touch if (web and touch) else full_rate


# Tire-mark segment spacing for the current target, split the same way.
func tire_mark_segment_step_for(web: bool, touch: bool) -> float:
	return tire_mark_segment_step_m_web_touch if (web and touch) else tire_mark_segment_step_m


# Flat-ground subdivision (HQ apron / podium floor) for the current target.
func ground_subdiv_for(web: bool, touch: bool) -> int:
	return ground_subdiv_web_touch if (web and touch) else ground_subdiv


# Whether the on-disk overworld terrain cache may be used for the current target:
# the authored overworld_cache_enabled AND not web. On web, user:// is IndexedDB
# backed, shares its quota with profile.json, and there is no quota detection — a
# ~83 MB terrain cache there risks taking the player's save down with it, so the
# cache is off on EVERY browser (desktop included), hence `touch` is accepted for
# signature parity with the other per-target accessors but never consulted.
# Pure so the overworld resolves it once at entry and tests can pin either branch.
func overworld_cache_active_for(web: bool, _touch: bool) -> bool:
	return overworld_cache_enabled and not web


# rear). The 2x keeps the fleet-average rate at suspension_stiffness — a 50/50 car
# gets the base rate on both axles (unchanged), a nose-heavy car a stiffer front.
func axle_stiffness(front: bool) -> float:
	return suspension_stiffness * 2.0 * (weight_front if front else 1.0 - weight_front)


# Per-axle spring travel / rest length; a 0 override inherits suspension_travel.
func axle_travel(front: bool) -> float:
	var t: float = suspension_travel_front if front else suspension_travel_rear
	return t if t > 0.0 else suspension_travel


# Tyre load-sensitivity multiplier on a tyre's compound μ. Real tyre grip is NOT the
# textbook load-independent μN: the effective μ falls as the load pressed through the
# contact patch rises, and a wider tyre spreads that load over more rubber. So grip
# tracks load-per-width, not load alone. We model the multiplier as (ref / P)^k where
# P = normal_force / width and k = tire_load_sensitivity: >1 when a tyre is lightly
# loaded or wide, <1 when heavily loaded or narrow, exactly 1 at tire_ref_pressure.
# The SAME function feeds both the physics (drivetrain per-wheel μ, with the live
# suspension normal force — so weight transfer shifts grip for free) and the car-select
# lateral-G stat (with static axle loads), so the panel can't disagree with the car.
func tire_load_factor(normal_force: float, width: float) -> float:
	if normal_force <= 0.0 or width <= 0.0:
		return 1.0
	var pressure := normal_force / width
	return pow(tire_ref_pressure / pressure, tire_load_sensitivity)


# Critically damped for the spring rate. Godot scales each wheel's
# mass-normalized spring/damper by the full chassis mass, so with 4 wheels the
# bounce mode is x'' + 4c x' + 4k x = 0 and per-wheel critical damping is
# sqrt(stiffness), not the textbook 2 * sqrt(stiffness). Pass a per-axle rate
# (axle_stiffness) so each axle is critically damped for ITS own spring; the
# argument defaults to the overall rate.
func suspension_damping_compression(stiffness := -1.0) -> float:
	return sqrt(stiffness if stiffness >= 0.0 else suspension_stiffness)


# Rebound damper runs 1.5x the compression value for stability.
func suspension_damping_relaxation(stiffness := -1.0) -> float:
	return 1.5 * suspension_damping_compression(stiffness)


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


# The OVERWORLD's height layers, same (wavelength, amplitude) shape as terrain_layers() so a
# consumer can swap one for the other. Every hub height path must use this one; see the
# "Overworld terrain NOISE" block for why the hub does not share the stage values.
func overworld_terrain_layers() -> Array[Vector2]:
	return [
		Vector2(overworld_terrain_layer1_wavelength, overworld_terrain_layer1_amplitude),
		Vector2(overworld_terrain_layer2_wavelength, overworld_terrain_layer2_amplitude),
		Vector2(overworld_terrain_layer3_wavelength, overworld_terrain_layer3_amplitude),
	]


# Push every ps1_post_process.gdshader uniform onto a post-process material —
# the dither grid plus the whole colour grade. Shared by BOTH hosts of that pass
# (world.gd for the stage, hq.gd for the HQ hub) so the two can never drift into
# grading the game differently depending on which screen you're on. Every target
# renders at the same authored resolution, so both the dither grid and the grade
# are resolution-independent and pushed raw.
func apply_post_process(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("virtual_resolution", virtual_resolution)
	mat.set_shader_parameter("grade_amount", grade_amount)
	mat.set_shader_parameter("grade_saturation", grade_saturation)
	mat.set_shader_parameter("grade_contrast", grade_contrast)
	mat.set_shader_parameter("grade_shadow_tint", grade_shadow_tint)
	mat.set_shader_parameter("grade_highlight_tint", grade_highlight_tint)
	mat.set_shader_parameter("grade_vignette_strength", grade_vignette_strength)
	mat.set_shader_parameter("grade_vignette_radius", grade_vignette_radius)


# Push the fake car-lighting uniforms onto a ps1_models.gdshader material. Used
# for every lit car mesh (chassis/cabin/wheels in world.gd, the MX-5 body in
# car.gd) so the light parameters live in one place. Terrain materials are never
# passed here, so they keep the shader's default light_amount of 0 (flat).
# Dim an authored colour by the ACTIVE weather's sun multiplier, preserving alpha.
#
# THE ONE PLACE THAT KNOWS THE RULE. Every material in the game is `unshaded`, so
# nothing dims automatically — each one has to be told, and each one that ISN'T told
# keeps rendering full daylight while the world around it goes dark. That was a real
# bug three times over: the car (full sun on rain and storm stages), the trees (lit
# on their sunward side at night, with no sun), and the lakes (bright daylight blue
# at night). Route any new fake-lit material through here rather than pushing an
# authored colour straight at a shader.
func weather_lit(col: Color) -> Color:
	return Color(col.r * weather_sun_mult, col.g * weather_sun_mult,
		col.b * weather_sun_mult, col.a)


# Whether the ground under this stage is SNOW rather than dirt with snow painted on.
# Derived from the deep-snow block RallySession.apply_event_config seats off the
# region, which is 0.0 for every region that authors none — so this is exactly "the
# stage is in a snowy region" with no second flag to keep in sync. Same shape as the
# `frozen_water_grip > 0.0` gate the drivetrain already uses for ice.
func ground_is_snow() -> bool:
	return deep_snow_depth_m > 0.0


# Car-local exhaust pipe placements for a car spec (features/exhaust-flames.md) — one
# entry per exit, so a single-exit car gets one and a quad-exit car four.
#
# Each entry is a Vector4: xyz is the pipe POSITION in car-local metres, and w is the
# pipe's YAW in DEGREES about the vertical axis — which way the flame points in the
# horizontal plane. 0 is straight back along +Z; POSITIVE turns the flame toward the car's
# RIGHT (+X), negative toward its left. Side exits (the Viper) need a few degrees outward
# so the flame leaves the sill rather than running along it.
#
# Authored per car in exhaust_offsets, keyed on the car id. THE ONE PLACE THAT RESOLVES
# A CAR TO ITS PIPES, shared by car.gd (which caches the result into exhaust_locals on
# every spec apply) and ExhaustFlames (which falls back to it for a bare stub car).
#
# A car with no entry — or an entry that is empty, or not an array of Vector3 — falls
# back to a MIRRORED PAIR derived from exhaust_offset_fallback: its X mirrored to both
# sides, its Y used as-is, and its Z DISCARDED in favour of the rear of this car's own
# wheelbase. That last part is the point of the fallback: a fixed Z would sit inside a
# long car and short of a small one, whereas a wheelbase-derived one lands near the tail
# of any car, which is all an un-dialled-in car needs.
func exhaust_locals_for(spec: Dictionary) -> PackedVector4Array:
	var authored: Variant = exhaust_offsets.get(String(spec.get("id", "")))
	if authored is Array or authored is PackedVector3Array or authored is PackedVector4Array:
		var out := PackedVector4Array()
		for v in authored:
			# A pipe may be authored either way: a Vector3 is a position pointing straight
			# back, a Vector4 adds a yaw. Accepting both means adding an angle to one car
			# never forces every other car's entry to be rewritten.
			if v is Vector4:
				out.append(v)
			elif v is Vector3:
				out.append(Vector4(v.x, v.y, v.z, 0.0))
		if not out.is_empty():
			return out
	# +Z is rearward and the wheelbase spans ±wheelbase/2 about the car origin, so the
	# rear axle sits at +wheelbase/2 — close enough to the tail to eyeball from. Straight
	# back (yaw 0): an un-dialled-in car has no reason to prefer any other angle.
	var z: float = float(spec.get("wheelbase", 2.5)) * 0.5
	return PackedVector4Array([
		Vector4(absf(exhaust_offset_fallback.x), exhaust_offset_fallback.y, z, 0.0),
		Vector4(-absf(exhaust_offset_fallback.x), exhaust_offset_fallback.y, z, 0.0),
	])


# THE ONE PLACE THAT KNOWS THE SURFACE-TYRE RULE, shared by the live physics
# (Drivetrain.surface_tire_params) and the lap-time model (LapTimeModel._surface_grip)
# so the AI field can never diverge from the car the player is actually driving.
#
# Static, and takes its `source` as an ARGUMENT rather than reading its own fields,
# because the two callers source them differently: physics passes the live config the
# upgrade pipeline wrote, while the lap model passes a car_meta for a rival that may not
# be the player's car at all. Both work — see _tire_axis_value.
#
# Which axes exist, and how each blends, is TIRE_SURFACE_AXES plus _channel_weight —
# not this function. Widening the set of axes must never need an edit here.
#
# `ctx` is the STAGE CONTEXT, built by fill_tire_context below. It is a Dictionary rather
# than a parameter list on purpose: a new axis keyed on any condition the context already
# carries needs no signature change and therefore no caller edit. See the note on
# fill_tire_context for the one case that is NOT free.
static func tire_surface_mult_for(source, ctx: Dictionary) -> float:
	var out := 1.0
	for axis in TIRE_SURFACE_AXES:
		var w := _channel_weight(String(axis["channel"]), ctx)
		if is_nan(w) or w <= 0.0:
			continue
		out *= lerpf(1.0, _tire_axis_value(source, String(axis["field"])), w)
	return out


# THE STAGE CONTEXT every channel rule reads from. Fills `ctx` IN PLACE and returns it, so
# the per-wheel physics path can own one scratch Dictionary and allocate nothing per tick.
#
# It deliberately carries everything BOTH callers already have in hand at the call site —
# the contact's tarmac weight, whether the region is snowy, and the stage weather — even
# though no axis reads weather today. That is the point: adding a wet-weather axis is then
# three edits in THIS FILE and nothing else — and it should key on `ctx["is_wet"]` (seeded
# below from WeatherLibrary.is_wet), not on the raw weather id.
#
# HONEST LIMIT, because the previous version of this comment over-promised and cost a
# round: an axis keyed on something NOT in this dictionary (altitude, time of day, tyre
# temperature) needs that value added here and at both fill sites too. Still no change to
# the resolver or to any consumer's logic — but it is five edits across three files, not
# three edits in one. Do not read "adding an axis is one file" as unconditional.
static func fill_tire_context(ctx: Dictionary, tarmac_weight: float, snowy: bool,
		weather: String) -> Dictionary:
	ctx["tarmac"] = tarmac_weight
	ctx["snowy"] = snowy
	ctx["weather"] = weather
	# The CLASSIFICATION, not just the id. A wet-weather axis must read this bool and never
	# compare `ctx["weather"] == "rain"`: `storm` is wet too, and three separate attempts to
	# add a wet axis have shipped a rain-only comparison that was silently dead in a storm.
	# WeatherLibrary.WETNESS is the single table that decides, and a new condition cannot
	# ship unclassified (test_every_condition_is_classified_wet_or_dry).
	ctx["is_wet"] = WeatherLibrary.is_wet(weather)
	return ctx


# How much of each channel this contact is on, read off the stage context. One arm per
# registered channel; the exclusivity between them lives here, in one place.
#
# The snow bonus is all-or-nothing on the region (snow ground is snow ground, and the
# packed-snow road is the same white stuff as the verge), while the tarmac penalty is
# FEATHERED by the contact's tarmac weight — a gravel stage costs the compound nothing,
# and a mixed stage costs it in proportion to the asphalt it actually crosses. They are
# EXCLUSIVE: on a snow stage the "tarmac" channel is a dusting over asphalt, so charging
# the tarmac penalty there would cancel the whole point of a winter compound.
#
# Returns NAN — not 0.0 — for a channel with no arm. A zero is indistinguishable from
# "this contact simply isn't on that channel right now", which is why the guard test could
# not tell an unregistered channel from an inactive one. NAN says "no rule exists", and
# tests/headless/test_tire_surface_axes.gd asserts on exactly that.
static func _channel_weight(channel: String, ctx: Dictionary) -> float:
	match channel:
		"snow":
			return 1.0 if bool(ctx.get("snowy", false)) else 0.0
		"tarmac":
			return 0.0 if bool(ctx.get("snowy", false)) else clampf(float(ctx.get("tarmac", 0.0)), 0.0, 1.0)
	# A channel with no blend rule contributes nothing on every stage, which is the silent
	# no-op this registry exists to make impossible. Say so where it happens, not only in
	# the guard test.
	push_error("GameConfig.TIRE_SURFACE_AXES uses channel '%s', which _channel_weight has no rule for." % channel)
	return NAN


# One axis's live multiplier. `source` is either a GameConfig (the player's car, after
# the upgrade pipeline has written it) or a car_meta Dictionary (a rival's, which may not
# be the player's car at all); absent reads as the 1.0 identity, which is what makes the
# whole mechanism an exact no-op for a car with no such compound fitted.
static func _tire_axis_value(source, field: String) -> float:
	if source is Dictionary:
		return float(source.get(field, 1.0))
	if source == null:
		return 1.0
	var v: Variant = source.get(field)
	if v == null:
		push_error("GameConfig.TIRE_SURFACE_AXES names '%s', which is not a GameConfig property." % field)
		return 1.0
	return float(v)


# Two-axis compatibility shim over tire_surface_mult_for, kept because tests call this
# arity directly. Production code goes through tire_surface_mult_for so that widening
# TIRE_SURFACE_AXES needs no signature change anywhere — this shim deliberately sees
# only the snow/tarmac pair it names.
static func tire_surface_mult(snow_mult: float, tarmac_mult: float,
		tarmac_weight: float, snowy: bool) -> float:
	return tire_surface_mult_for({
		"tire_snow_grip_mult": snow_mult,
		"tire_tarmac_grip_mult": tarmac_mult,
	}, fill_tire_context({}, tarmac_weight, snowy, RallyLibrary.WEATHER_DRY))


func apply_car_light(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("light_amount", car_light_amount)
	mat.set_shader_parameter("light_dir", sun_direction)
	# Sun and sky ambient dim with the weather; ground_color (the bounce off the
	# surface below) does not, since it is dominated by the ground's own albedo.
	mat.set_shader_parameter("sun_color", weather_lit(sun_color))
	mat.set_shader_parameter("sky_color", weather_lit(sky_color))
	mat.set_shader_parameter("ground_color", ground_color)


# The same fake sun/ambient block for FOLIAGE billboards (billboard_opaque.gdshader).
# Mirrors apply_car_light so trees sit in the same light as the ground and the car —
# in particular so a tree's sunward side stops being lit on a night stage, where
# there is no sun to light it.
func apply_foliage_light(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("sun_dir", sun_direction.normalized())
	mat.set_shader_parameter("sun_color", weather_lit(sun_color))
	mat.set_shader_parameter("sky_color", weather_lit(sky_color))
	mat.set_shader_parameter("ground_color", ground_color)
	mat.set_shader_parameter("light_amount", foliage_light_amount)


# Push the shared sun/ambient values + the terrain amount onto a TerrainManager,
# which bakes them into vertex colours when chunks generate. Call BEFORE the
# initial terrain build so the shading is baked into the first chunks.
func apply_terrain_light(tm: TerrainManager) -> void:
	tm.light_amount = terrain_light_amount
	tm.sun_dir = sun_direction.normalized()
	tm.sun_color = sun_color
	tm.sky_color = sky_color
	tm.ground_color = ground_color


# Push the terrain LOD tunables onto the manager BEFORE the corridor precompute
# (the LOD meshes + skirt are prebaked in cache_chunk from lod_skirt_m) and the
# initial build. Mirrors apply_terrain_light.
func apply_terrain_lod(tm: TerrainManager) -> void:
	tm.lod_band_ends_m = terrain_lod_bands_m
	tm.lod_skirt_m = terrain_lod_skirt_m
	tm.collision_ring = terrain_collision_ring
	tm.precompute_prune_enabled = terrain_precompute_prune_enabled
	tm.precompute_safety_slack_m = terrain_precompute_safety_slack_m
	tm.lazy_finest_lod = terrain_lazy_finest_lod
	tm.detail_builds_per_frame = terrain_detail_builds_per_frame


# Push the Cliffs group onto the terrain manager before bake_track (mirrors
# apply_terrain_light). cliff_seed derives the camber noise from the stage's
# track_seed so the whole stage is one deterministic function of the seed.
func apply_cliffs(tm: TerrainManager) -> void:
	tm.cliff_enabled = cliff_enabled
	tm.cliff_wavelength_m = cliff_wavelength_m
	tm.cliff_gain = cliff_gain
	tm.cliff_max_height_m = cliff_max_height_m
	tm.cliff_run_m = cliff_run_m
	tm.cliff_fade_m = cliff_fade_m
	tm.cliff_open_radius_m = cliff_open_radius_m
	tm.cliff_amount = cliff_amount
	tm.cliff_seed = track_seed


# The scalar tree-scatter knobs packed into the Dictionary TreeScatter.scatter
# expects. tree_size_m is rendering-only and passed separately to BillboardField.
func tree_params() -> Dictionary:
	return {
		"points_per_turn": trees_per_turn,
		"spawn_radius_m": tree_spawn_radius_m,
		"jitter": tree_jitter,
	}


# The same packing for the ROCK scatter. `density` is the region's rock_density
# multiplier (RegionLibrary), applied to the base count here rather than in world.gd
# so every caller gets the regional weighting without having to remember it.
#
# Rocks get their own params rather than reusing tree_params() because the two have
# opposite pressures: trees are dense scenery you drive past, rocks are sparse
# obstacles you drive INTO, so their counts have to move independently — turning the
# forest up must not turn the hazard field up with it.
#
# NOTE the count fed to TreeScatter is a count of GROUP ANCHORS, not of rocks — each
# one is fanned out by TreeScatter.cluster afterwards.
func rock_params(density := 1.0) -> Dictionary:
	return {
		"points_per_turn": rock_groups_per_turn * maxf(density, 0.0),
		"spawn_radius_m": rock_spawn_radius_m,
		"jitter": rock_jitter,
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
		"knock_speed_factor": sign_knock_speed_factor,
		"knock_speed_min": sign_knock_speed_min,
		"knock_speed_max": sign_knock_speed_max,
		"knock_lift_ratio": sign_knock_lift_ratio,
		"knock_spin": sign_knock_spin,
		# Structural (mirrors the spectator ragdoll): the sign lives on its own layer,
		# off the car's mask, and only masks the world layer (terrain + trees). The car
		# shares the world layer, so SignField also adds an explicit exception on contact.
		"knock_layer": 1 << 4,
		"knock_mask": 1,
		# Shared world-prop render distance (same field foliage uses) so resting signs
		# cull at the same range as the trees/spectators. See MeshUtil.apply_visibility_range.
		"render_distance_m": tree_render_distance_m,
		"render_fade_m": tree_render_fade_m,
	}


# Everything BarrierLayout.plan + BarrierField.build need (features/barriers.md).
# `track_width` and the shared world-prop render distance come along so the barrier
# lines up with the road and culls with the rest of the roadside dressing.
func barrier_render_params() -> Dictionary:
	return {
		"section_length_m": barrier_section_length_m,
		"road_gap_m": barrier_road_gap_m,
		"lead_m": barrier_lead_m,
		"tarmac_threshold": barrier_tarmac_threshold,
		"sink_m": barrier_sink_m,
		"slope_probe_m": barrier_slope_probe_m,
		"drop_min_m": barrier_drop_min_m,
		"hill_tolerance_m": barrier_hill_tolerance_m,
		"min_run_modules": barrier_min_run_modules,
		"track_width": track_width,
		"render_distance_m": tree_render_distance_m,
		"render_fade_m": tree_render_fade_m,
	}


# Everything SpectatorGroup.setup needs (todo/roadside-spectators.md). The collision
# bits are structural, not tuned: ragdolls live on their own layer (5) and only mask
# the world layer (1, terrain+trees) — never the car, which SpectatorGroup also adds
# an explicit exception for since the car shares layer 1.
func road_marking_params() -> Dictionary:
	return {
		"enabled": road_markings_enabled,
		"half_width": track_width * 0.5,
		"color": road_marking_color,
		"width_m": road_marking_width_m,
		"edge_inset_m": road_marking_edge_inset_m,
		"center_dash_m": road_marking_center_dash_m,
		"center_gap_m": road_marking_center_gap_m,
		"height_m": road_marking_height_m,
		"tarmac_threshold": road_marking_tarmac_threshold,
		"sample_step_m": road_marking_sample_step_m,
	}


func spectator_params() -> Dictionary:
	return {
		"group_size": spectator_group_size,
		"separation_m": spectator_separation_m,
		"tree_avoid_m": spectator_tree_avoid_m,
		"tree_cell_m": maxf(spectator_tree_avoid_m, 0.5),
		"flee_radius_m": spectator_flee_radius_m,
		"knock_radius_m": spectator_knock_radius_m,
		"max_speed_mps": spectator_max_speed_mps,
		"accel_mps2": spectator_accel_mps2,
		"active_radius_m": spectator_active_radius_m,
		"sim_interval": spectator_sim_interval,
		"road_probe_m": track_width * 0.5,
		"anchor_dead_zone_m": spectator_separation_m,
		"w_separation": spectator_w_separation,
		"w_flee": spectator_w_flee,
		"w_road": spectator_w_road,
		"w_obstacle": spectator_w_obstacle,
		"w_anchor": spectator_w_anchor,
		"knock_speed_factor": spectator_knock_speed_factor,
		"knock_speed_min": spectator_knock_speed_min,
		"knock_speed_max": spectator_knock_speed_max,
		"knock_lift_ratio": spectator_knock_lift_ratio,
		"knock_spin": spectator_knock_spin,
		"ragdoll_mass_kg": spectator_ragdoll_mass_kg,
		"ragdoll_pool_size": spectator_ragdoll_pool_size,
		"despawn_behind_m": spectator_despawn_behind_m,
		"drag_strength": spectator_drag_strength,
		"ragdoll_layer": 1 << 4,
		"ragdoll_mask": 1,
		"seed": 0,
		# Shared world-prop render distance (same field foliage uses) so the crowd
		# and the trees it stands among cull at one range. See MeshUtil.apply_visibility_range.
		"render_distance_m": tree_render_distance_m,
		"render_fade_m": tree_render_fade_m,
	}


# --- Crosswind (storm) -------------------------------------------------------
# Shape of the seeded gust profile applied as a lateral body force on a stage whose
# weather entry carries a "wind" block (scripts/crosswind.gd). The wind STRENGTH,
# GUST and DIRECTION are named by that block and live with the condition; these two
# are profile shape, shared by any windy condition.

## Wavelength (m of stage distance) of the slowest gust octave — how far apart the
## big gusts sit. Smaller = busier, more frequent wind changes.
@export var crosswind_gust_wavelength_m := 400.0

## Fraction of the wind force that still acts when the car is exactly nose-on to it.
## 1.0 = direction-independent; lower values make a broadside car catch more wind.
## A cheap stand-in for real exposure — there is deliberately no shelter/occlusion
## model (open ground vs. tree cover); see features/car-physics.md.
@export_range(0.0, 1.0) var crosswind_nose_on_fraction := 0.35


@export_group("Rival Ghost")
# While the player drives, the rally leader (P1) is shown on track as a translucent
# ghost car, crossing the finish exactly when the standings say they did
# (features/rival-ghost.md). It is NOT an AI driver: it is posed kinematically from
# LapTimeModel.optimum_profile, re-solved with a degraded "driver skill" envelope until
# the profile's total lands on P1's drawn time. These knobs shape the look and the
# solve; WHO gets ghosted (the fastest classified rival) is not tunable.
## Show the ghost at all. Off = no ghost, but the in-stage "vs P1" delta popup still
## works — the shared pace object is built for every session run regardless.
@export var rival_ghost_enabled := true
## Cull distance (m). Beyond this the ghost is hidden — a ghost minutes up the road is
## not worth drawing. Its pose stays valid at any distance (it needs no terrain
## collider), so this is purely a rendering budget.
@export_range(50.0, 2000.0) var rival_ghost_visible_m := 400.0
## Ghost body opacity at a normal chasing distance. Low enough to read as "not really
## there", high enough to chase.
@export_range(0.05, 1.0) var rival_ghost_opacity := 0.4
## Float P1's name above the ghost, so it reads as a rival you are racing rather than an
## anonymous car. Billboarded, and it fades with the ghost's proximity fade.
@export var rival_ghost_nametag_enabled := true
## Height (m) of the nametag above the ghost's origin.
@export_range(0.5, 8.0) var rival_ghost_nametag_height_m := 2.2
## On-screen size (m of world height) of the nametag text.
@export_range(0.1, 3.0) var rival_ghost_nametag_size_m := 0.55
## Give the ghost its own gravel spray. It needs a SECOND WheelParticles system (that
## node tracks one car), so it is a real cost rather than a free ride on the player's —
## off is a legitimate choice on a tight frame budget.
@export var rival_ghost_dust_enabled := true
## Distance (m) over which the ghost fades OUT as it gets close to the player: full
## opacity at this range, fully transparent at zero. Stops a ghost you are overlapping
## from filling the screen and hiding the road you are trying to drive.
@export_range(0.0, 60.0) var rival_ghost_fade_near_m := 14.0
## Peak lateral shift (m) off the centerline as the ghost threads a line — wide on
## entry, tucked at the apex, drifting out on exit. Shares one road-width budget with
## the slip angle below, so nose and tail stay on the carriageway.
@export_range(0.0, 6.0) var rival_ghost_line_offset_m := 1.2
## Artistic multiplier on the ghost's slip angle. The angle ITSELF is derived from the
## tyre model, not authored here: a tyre at peak lateral force sits at its peak-slip angle,
## which is asin(*_slip_peak) for the surface (~11.5 deg on tarmac, ~20.5 deg on gravel),
## scaled by how much of the friction circle cornering is actually using. So the
## gravel-vs-tarmac difference comes out of the physics for free — retune
## gravel_slip_peak / tarmac_slip_peak to change it. 1.0 = physical; raise it to
## exaggerate the drift for looks.
@export_range(0.0, 3.0) var rival_ghost_slip_scale := 1.0
## Hard ceiling (deg) on slip. Past this the ghost reads as a spin, not a slide.
@export_range(0.0, 90.0) var rival_ghost_max_slip_deg := 45.0
## Smoothing time constant (s) for the ghost's LATERAL position (how far off the
## centerline it sits). The road curve is only baked every ~5 m and lerped, so the geometry
## the ghost reads steps at each chord vertex; this filters the residual sideways motion.
## Applied to the lateral offset ONLY — never to along-track position, which is the ghost's
## clock and must stay exact. 0 disables it.
@export_range(0.0, 2.0) var rival_ghost_position_smoothing_s := 1.0
## The same, for the ghost's ROTATION. Kept SHORTER than the positional constant on
## purpose: heavy rotational filtering makes the car turn lazily and lag its own direction
## of travel, which reads as sliding rather than driving, while sideways position wants the
## heavier hand. 0 disables it.
## CAREFUL: this is NOT the only thing that smooths rotation. rival_ghost_slip_lag_s below
## lags the slip angle, which is a yaw folded into the same basis — so setting THIS to 0
## alone still leaves the ghost's rotation filtered in corners. Zero both for genuinely
## unfiltered rotation.
@export_range(0.0, 2.0) var rival_ghost_rotation_smoothing_s := 0.0
## Smoothing time (s) for the slip angle, so yaw builds through entry and unwinds on
## exit instead of snapping at the apex. This is the SECOND rotational filter — slip is a
## yaw applied to the body, so it lags rotation exactly as rival_ghost_rotation_smoothing_s
## does. See the note there.
@export_range(0.0, 2.0) var rival_ghost_slip_lag_s := 0.25
## How much of the driver-skill deficit comes out of CORNERING: grip scales by
## pow(k, this). 0 = grip is never reduced, so the ghost corners at the car's true limit
## and every bit of its deficit comes from power (the default -- it makes the ghost a
## usable reference line: it brakes where you should brake and carries the right apex
## speed, and only loses to you down the straights). 1 = the old coupled behaviour, where
## a slower rival is slower everywhere.
## Caution: with this at 0 the only lever left is straight-line pace, so a very twisty
## stage may not have enough straight to give away and the solve will clamp (it warns).
## That ceiling is structural -- lowering rival_ghost_skill_min will not fix it.
@export_range(0.0, 2.0) var rival_ghost_grip_exponent := 0.0
## How much comes out of STRAIGHT-LINE pace: power scales by pow(k, this). Grip is the dominant loss, power the weaker secondary one —
## at k=0.8 and 0.30 that is a 20% grip cut against a ~6.5% power cut, i.e. a crew
## that loses it in the corners and is only slightly down on straights.
## Toward 1.0 = slower rivals feel gutless on straights. Toward 0 = corner-limited
## only, and straightness-dominated stages stop converging (they trip the residual cap
## below, which is exactly what that cap is for).
@export_range(0.05, 1.0) var rival_ghost_power_exponent := 1.0
## Lower end of the skill bracket the solve bisects over. Must be low enough to reach
## the slowest authored pace; if clamp warnings prove common, lower THIS before touching
## the exponents (an exponent changes how every ghost looks).
## Measured, not guessed: with the grip exponent at 0 the worst career stage needs 0.151
## (tools/audit_ghost_pace.tscn sweeps all 96 of them), so this sits well under that.
## A wide bracket costs nothing — the bisection still lands on whichever k matches the
## target, so a low floor only extends what is REACHABLE; it never makes a normal ghost
## slower. Raise the grip exponent and this can come back up.
@export_range(0.01, 1.0) var rival_ghost_skill_min := 0.05
## Upper end of the bracket. Deliberately ABOVE 1.0: it is a safety valve for
## cached-vs-live track divergence, where the target can land beyond the car's
## ungraded optimum. Without the headroom those solves fall onto the uniform-scale
## fallback this design exists to avoid.
@export_range(1.0, 2.0) var rival_ghost_skill_max := 1.15
## Bisection steps. Plus 2 bracket evaluations = the sweep budget per solve.
@export_range(1, 40) var rival_ghost_skill_iterations := 12
## Largest time error (ms) the final uniform micro-scale may absorb. Beyond this the
## solve has failed to find a real SHAPE and is falling back to disguised uniform
## scaling, so it warns instead of shipping silently.
@export_range(1, 5000) var rival_ghost_max_time_residual_ms := 250


@export_group("Overworld")
# The drivable overworld map — a single open landmass the player drives across to reach
# rallies, dealerships and the workshop, standing in for the HQ's menu tables. See
# docs/superpowers/specs/2026-08-17-overworld-hq-design.md and features/overworld.md.
# The terrain is generated once per invalidation key and cached under user://overworld/,
# then streamed in chunks around the car; zones are dwell-activated hotspots on it.
## Master gate. Off (the default) = the shipped hq.tscn hub is the only hub and none of
## the overworld's generation, cache or streaming cost is ever paid. Read at BOOT, before
## any settings UI exists, which is why it lives here and not only on the dev page.
@export var overworld_enabled := false
## Width AND depth (metres) of the square map. Map positions are normalised 0..1, so this
## is the only thing that converts them to world metres — changing it rescales every zone
## placement, and it is part of the terrain cache's invalidation key, so a change forces a
## full regeneration. It is also the main cost lever: generation time and cache size scale
## with the SQUARE of it (~83 MB at 4 km, ~47 MB at 3 km).
@export_range(500.0, 16000.0) var overworld_size_m := 4000.0
## Persist generated overworld chunks to user://overworld/ so the (slow) first-entry
## generation is paid once instead of every entry. Off = regenerate every session, which
## is the dev escape hatch while the invalidation key is churning — correctness is
## unaffected, only load time. See overworld_cache_active_for() for the platform side.
@export var overworld_cache_enabled := true
## Radius, in chunks (Chebyshev), of the ring of loaded chunks kept around the car — a
## radius of 10 is a 21x21 window. Larger = more of the map visible with fewer stream-in
## pops, but more memory and more build work per boundary crossing.
## PROVISIONAL: the design calls for this to be measured on a real device (the overworld's
## streaming budget is genuinely new and has no precedent in the corridor-shaped rally
## terrain), and the number retuned from that measurement. Treat it as a starting point.
@export_range(1, 32) var overworld_load_radius := 10
## Chunk builds allowed per rendered frame while the load ring catches up. A crossing
## queues a whole row of chunks at once, so building them all in one frame hitches;
## draining a couple per frame keeps them ahead of the car without a visible stall.
## Same provisional caveat as the load radius — size it from a measured build cost.
@export_range(1, 16) var overworld_chunk_build_budget := 2
## Radius (metres) of a zone's trigger area — how close the car must be parked to a
## rally / dealership / workshop hotspot for it to be a candidate for activation.
@export_range(2.0, 200.0) var overworld_zone_radius_m := 25.0
## How long (seconds) the car must sit stopped inside a zone before it activates. ANY
## movement resets the accumulator to zero, so this is a deliberate "park here" gesture
## rather than something a fast drive-through can trip.
@export_range(0.0, 15.0) var overworld_zone_dwell_s := 3.0
## Speed (km/h) below which the car counts as stopped for the dwell timer above. Not
## zero: idle creep and suspension settle never quite reach a true standstill.
@export_range(0.0, 30.0) var overworld_zone_stop_kmh := 2.0
## Height (metres) of the transparent light tube that stands on a zone — the landmark that
## replaced the old ground ring. Tall enough to be spotted well before the marker itself
## comes in at `overworld_marker_draw_distance_m`; it fades out towards the top, so this is
## the height at which it has fully vanished, not a hard edge.
@export_range(0.0, 400.0) var overworld_zone_tube_height_m := 60.0
## Alpha of the tube AT ITS BASE while idle. The vertical fade to nothing is baked into the
## mesh; this is the overall strength dial. Low enough to see the terrain and the car through
## it, high enough to read against a bright sky.
@export_range(0.0, 1.0, 0.01) var overworld_zone_tube_alpha := 0.28
## Alpha the tube's lit portion (and its sweeping fill line) reaches at a completed dwell.
## The jump from `overworld_zone_tube_alpha` to this IS the "it fired" punctuation, so keep
## the gap wide.
@export_range(0.0, 1.0, 0.01) var overworld_zone_tube_ready_alpha := 0.85
## How far in (metres) from the map bounds the coastline taper begins. Inside this band
## the ground falls away to the perimeter depth, so the map ends in water rather than at a
## visible wall. Part of the cache invalidation key — changing it regenerates the terrain.
@export_range(0.0, 2000.0) var overworld_edge_taper_m := 300.0
## How far BELOW the waterline the very perimeter of the map sits (metres). Deep enough
## that the taper reads as sea floor and no undrowned ground survives at the bounds.
## Also part of the cache invalidation key.
@export_range(0.0, 500.0) var overworld_edge_depth_m := 40.0
# --- Overworld terrain NOISE ------------------------------------------------------------
#
# The hub gets its OWN height noise, separate from the stages' terrain_layer* fields, because
# the two worlds want opposite things from the same generator. A stage is a narrow corridor
# a few hundred metres wide where big relief reads as drama; the hub is a 1 km square the
# player crosses constantly, where the same relief becomes a wall between two rally zones.
# The stage values (300 m / 30 m on layer 1) put only three or four features across the whole
# hub and fought the flat pads hard enough to leave undrivable lips off them — see
# tools/analyse_road_grades.gd.
#
# Same generator, same meaning as the stage fields: PERLIN, FRACTAL_NONE, one noise per layer
# at `frequency = 1 / wavelength`, summed as `noise(x, z) * amplitude`. Amplitude is the peak
# CONTRIBUTION in metres, so the layer sum bounds the total relief.
#
# ALL of these are in the chunk cache's invalidation key (OverworldCache.invalidation_key), so
# retuning any one of them discards the precomputed map and rebuilds it on the next launch.
# Anything that sets up hub terrain must read these — overworld.gd, the cache key, AND
# tools/analyse_road_grades.gd — or it measures a world the player never drives.

## Broad relief: the hills the roads wind between. Keep the wavelength a decent fraction of
## overworld_size_m or the map reads as one slope; keep the amplitude modest or the pads
## cannot feather back into it at a drivable grade.
@export_range(1.0, 1000.0) var overworld_terrain_layer1_wavelength := 220.0
@export_range(0.0, 100.0) var overworld_terrain_layer1_amplitude := 12.0
## Mid detail: undulation along a road rather than hills to cross.
@export_range(1.0, 200.0) var overworld_terrain_layer2_wavelength := 60.0
@export_range(0.0, 10.0) var overworld_terrain_layer2_amplitude := 3.0
## Fine texture: stops the ground reading as smooth shading at close range. Small enough not
## to shake the car — the wheels average anything under a metre or so.
@export_range(1.0, 200.0) var overworld_terrain_layer3_wavelength := 18.0
@export_range(0.0, 10.0) var overworld_terrain_layer3_amplitude := 0.8
## Seed for the hub's height noise only. Deliberately SEPARATE from track_seed, which still
## places the hub's roads and scatter: reshaping the ground should not relocate every road and
## tree, and re-rolling the road layout should not force a full terrain rebake.
@export var overworld_terrain_seed := 2

## THE FRONTIER WALL — the translucent curtain standing on the edge of the revealed region, so the
## boundary is visible before the veil and the push-back explain it (features/overworld.md ->
## "The frontier wall"). A WARNING, never a collider: the soft push is still the only thing that
## moves the car.
@export var overworld_fog_wall_enabled := true
## How tall the curtain stands, metres. Tall enough to read across a valley, short enough not to
## wall the sky off. Baked into the mesh, so a retune shows on the next rebuild (a rally completing,
## or re-entering the hub) rather than instantly.
## Seconds the showroom camera takes to fly back to the driving view when the car picker closes.
## 0 disables the transition and cuts, which is also what a visuals-off picker does — so the
## hand-back contract is identical either way and only the visible case gained a move.
##
## Kept SHORT: it plays after the player has committed (confirm) or backed out (cancel), so it is
## time between an input and control returning. The car is parked, so there is nothing to miss.
@export_range(0.0, 3.0, 0.05) var overworld_picker_fly_seconds := 0.45
@export_range(0.0, 200.0) var overworld_fog_wall_height_m := 22.0
## Its overall opacity at the base (the fade to nothing with height is the light tube's own curve).
@export_range(0.0, 1.0, 0.01) var overworld_fog_wall_alpha := 0.40
## Its tint. BLACK, so the edge of the world reads as the world running out rather than as a hazard
## stripe: it darkens what is behind it, which is the same thing crossing it does to the whole screen
## (`Overworld.FOG_VEIL_ALPHA`). It was red, which said "danger" about ground that is merely unknown.
@export var overworld_fog_wall_color := Color(0.0, 0.0, 0.0)

## THE DIEGETIC CAR PICKER's camera (features/overworld.md -> "Picking a car in place"), in the
## CAR's own space: x = to its right, y = up from the ground it stands on, z = ahead of its nose.
## A three-quarter view in front of the car the player parked — the car never moves to suit it.
@export var overworld_picker_camera_offset := Vector3(2.6, 1.5, 5.2)
## How far BELOW the car's middle that camera aims, metres. Pitches the shot DOWN, which pushes the
## car UP the frame and clear of the bottom-anchored menu bar. Moving the aim rather than raising the
## camera keeps the car the same distance and the same size on screen.
@export_range(0.0, 6.0, 0.05) var overworld_picker_camera_aim_drop_m := 0.9
## Field of view for that camera. Tighter than the chase camera's on purpose: this is a portrait
## of one car, not a driving view.
@export_range(20.0, 110.0) var overworld_picker_camera_fov := 45.0

## Turntable rate (degrees/second) of the GHOST CARS parked at dealership zones. It no longer
## turns the floating ICONS: those (and the star layer above them) FACE THE PLAYER, because a
## rally's kind and your star count are information and should not have to be waited for
## (features/overworld.md -> "Markers"). A parked prize car carries no such information, so it
## keeps turning like a showroom turntable.
@export_range(0.0, 360.0) var overworld_marker_spin_deg_s := 30.0
## How high (metres) a zone's icon floats above the zone's ground position — high enough
## to clear foliage and be spotted over a rise.
@export_range(0.0, 40.0) var overworld_marker_height_m := 6.0
## Beyond this distance (metres) from the car, a zone's marker is not built at all. With
## 38 rallies plus the service zones on one map, drawing every marker everywhere is the
## whole budget; this keeps only the ones the player can plausibly be heading for.
@export_range(50.0, 4000.0) var overworld_marker_draw_distance_m := 600.0
## Cap on how many ghost cars (the showroom cars posed at dealership zones) may be alive
## at once. Each is a real car mesh, so this is a hard rendering budget, not a hint.
@export_range(0, 12) var overworld_ghost_car_max := 3

# --- The drive-in garage (scripts/overworld_garage.gd) --------------------------------------
# The garage is a BUILDING on the overworld that the player drives into; the car is then seated
# on a lift and the tune / upgrade pages open in place. See features/overworld.md → "The garage".
## Clear width of one service bay, in metres. Two bays wide; wide enough to drive into without
## clipping a pillar.
@export_range(3.0, 14.0, 0.1) var overworld_garage_bay_width_m := 7.5
## Front-to-back depth of the garage. Deep enough that a car is fully under the roof.
@export_range(6.0, 24.0, 0.1) var overworld_garage_bay_depth_m := 12.0
## Fastest the car may be moving, in km/h, for driving into the bay to seat it on the lift.
## Arrive faster and nothing happens until you have stopped — the back wall is solid, so this
## can only delay the entry, never block it.
@export_range(0.0, 40.0, 0.5) var overworld_garage_enter_max_kmh := 12.0
## How high the lift raises the car above the bay floor, in metres.
@export_range(0.0, 3.0, 0.05) var overworld_garage_lift_height_m := 1.2
## How long the lift takes to travel, in seconds (each way).
@export_range(0.05, 6.0, 0.05) var overworld_garage_lift_time_s := 1.2
## How far (metres) the garage stands OFF TO THE SIDE of the road, measured from the HQ pin to
## the door plane. The building is offset perpendicular to the roads that meet the HQ node and
## yawed to face back at them, so every approach road runs past its opening instead of into its
## back wall (see features/overworld.md → "Standing off the road"). The value is a WISH: the
## placement clamps it so the whole footprint stays inside `overworld_pad_garage_radius_m`, the
## level circle the building has to stand on, so raising this past what the pad can hold does
## nothing until the pad grows too.
@export_range(0.0, 40.0, 0.5) var overworld_garage_road_offset_m := 8.0

## The STOP TUBE inside the garage — the translucent light column standing on the lift bay that
## says "park here". Radius in metres; the column reads as the spot you have to be in, the same
## way a rally zone's tube reads as its trigger radius (features/overworld.md → "The stop tube").
## Zero hides it entirely.
@export_range(0.0, 6.0, 0.1) var overworld_garage_tube_radius_m := 1.7
## How tall the stop tube stands, in metres. It lives INSIDE a building, so unlike a zone tube
## this wants to stay under the roof rather than reach for the sky.
@export_range(0.0, 12.0, 0.1) var overworld_garage_tube_height_m := 4.2
## Base opacity of the stop tube, and the opacity it jumps to once the car is in the bay and
## slow enough to be taken. The jump IS the "you are in the right place" punctuation.
@export_range(0.0, 1.0, 0.01) var overworld_garage_tube_alpha := 0.3
@export_range(0.0, 1.0, 0.01) var overworld_garage_tube_ready_alpha := 0.85

# --- Flat pads under the zones and the garage (scripts/overworld_pads.gd) -------------------
# A level circle of ground is baked into the terrain under every rally zone and under the
# garage, so a zone's light tube / marker / ghost car and the garage BUILDING sit on flat
# ground rather than straddling a slope. Baked at generation time and part of the chunk
# cache's invalidation key, so retuning any of these forces a one-time terrain re-warm.
# See features/terrain.md → "Flat pads".

## Radius (metres) of the level circle under a RALLY ZONE. Wants to cover the trigger radius
## (`overworld_zone_radius_m`) plus the tube base, the marker's shadow and a parked ghost car.
@export_range(0.0, 80.0, 0.5) var overworld_pad_zone_radius_m := 12.0
## Radius (metres) of the level circle under the GARAGE — larger, because the building has a
## real footprint (`overworld_garage_bay_width_m` × `overworld_garage_bay_depth_m`) that must
## be level across ALL of it plus the approach the player drives in across. A circle
## circumscribing that rectangle is only ~7.1 m; this is deliberately well beyond it. It must
## also leave room for `overworld_garage_road_offset_m` — the building stands OFF the road, and
## its placement clamps that wish so the back corners stay on the pad, so too small a radius here
## silently cancels the offset and parks the garage back on the junction.
@export_range(0.0, 120.0, 0.5) var overworld_pad_garage_radius_m := 21.0
## Width (metres) of the feather band outside a pad, over which the flatten ramps away to the
## surrounding terrain. This is a DRIVABILITY dial as much as a look one: the steepest grade
## the feather can produce is about 1.5 × (height difference across the pad) ÷ this width, so
## narrowing it on a steep site can build a lip the car cannot climb — at the very place the
## player was driving to.
@export_range(0.5, 120.0, 0.5) var overworld_pad_feather_m := 14.0
## The steepest grade (rise ÷ run) a feather ramp may reach. A pad whose surroundings are rough
## enough that `overworld_pad_feather_m` would exceed this WIDENS its own band until the ramp is
## back under the cap, so the road leaving a pad is always drivable. Keep it under the grade a
## FWD car can climb on the loosest surface (~0.22 on snow).
@export_range(0.02, 1.0, 0.01) var overworld_pad_max_grade := 0.15
## Hard ceiling (metres) on a band widened by `overworld_pad_max_grade`. A pad on a cliff edge
## accepts a steeper lip rather than flattening half the neighbourhood.
@export_range(1.0, 200.0, 1.0) var overworld_pad_max_feather_m := 60.0

# --- The overworld map and minimap (scripts/overworld_map.gd) -------------------------------
# The minimap is an always-on corner panel; the full map is the M / gamepad-Back overlay. Both
# are drawn SCHEMATICALLY from the road network, the revealed pins and the fog mask — see the
# header of overworld_map.gd for why the photographic `textures/map_world.jpg` must not be used.

## Edge length (screen pixels) of the always-on minimap panel in the top-left corner. Square,
## so this is both its width and its height.
@export_range(80.0, 480.0) var overworld_minimap_size_px := 176.0
## How much world the minimap shows, in METRES across the panel. Small enough that the road
## you are on is legible; large enough to show the next junction.
@export_range(50.0, 4000.0) var overworld_minimap_zoom_m := 400.0
## Whether the minimap ROTATES so the car's facing is up (true), or stays north-up (false).
## Heading-up is directly actionable — "the road bends left" reads as left — which is why it
## ships on; a north indicator is drawn either way, so the panel can still be correlated with
## the (always north-up) full map.
@export var overworld_minimap_rotate_with_heading := true
## Overall opacity of the minimap panel. Below 1 so the driving view is never fully occluded.
@export_range(0.1, 1.0, 0.01) var overworld_minimap_alpha := 0.82
## Line width (screen pixels) for roads, the coastline and the selection ring on both maps.
@export_range(0.5, 8.0, 0.5) var overworld_map_line_width_px := 2.0
## Width (screen pixels) of the SAT-NAV route line — the road path to the destination the player
## picked on the full map, drawn on the minimap they follow while driving. Wider than a road, or
## it reads as just another road; a dark casing is drawn under it at ~2x this.
@export_range(1.0, 16.0, 0.5) var overworld_map_route_width_px := 4.0
## Speed (screen pixels per second) of the full map's synthetic CURSOR — the pointer the analog
## stick and the arrow keys glide, since a controller has none. Fast enough to cross the map without
## boredom; slow enough that magnetism can catch a pin on the way past.
@export_range(80.0, 3000.0, 10.0) var overworld_map_cursor_px_s := 520.0
## Pick radius (screen pixels) around a full-map pin for mouse hover and click / touch tap.
## Generous on purpose — it is also the finger target on a phone.
@export_range(6.0, 96.0, 1.0) var overworld_map_pick_px := 28.0
## Radius (screen pixels) of the player arrow — the unit it is scaled in.
@export_range(1.0, 20.0, 0.5) var overworld_map_pin_px := 5.0
## Half-extent (SCREEN pixels) of a destination pin's ICON on the MINIMAP. Pins are icons, not
## dots — a pennant for a rally, a car, a trophy, a house for the garage, and the part's own
## `UpgradeIcons` texture for a part unlock — so this is the half-width of that glyph's box.
##
## It is deliberately in screen pixels and does NOT scale with the map's zoom: one painter serves
## both presentations, so a world-space size would make minimap pins vanish.
@export_range(3.0, 24.0, 0.5) var overworld_map_icon_px := 7.0
## The same, on the FULL-SCREEN map, where there is room and pin NAMES are drawn beside the icons.
## Larger than the minimap's on purpose.
@export_range(4.0, 40.0, 0.5) var overworld_map_icon_full_px := 11.0
## How dark unexplored map goes, 0..1. The mask itself is the SHARED `MapFog` one, so the map
## and the ground agree about where the frontier is; this is only how strongly it is painted.
@export_range(0.0, 1.0, 0.01) var overworld_map_fog_alpha := 0.86
## Screen margin (pixels) around the minimap panel and inside the full-screen map.
@export_range(0.0, 120.0) var overworld_map_margin_px := 24.0

## Foliage density in the overworld, as a MULTIPLIER on the stage scatter counts
## (`trees_per_turn` / the rock groups). Well below 1 on purpose.
##
## The stage counts are authored to decorate a ROAD CORRIDOR you drive past at speed: at the
## shipped values the scatter lattice is ~6.3 m, i.e. one tree per ~39 m², which is genuine
## forest. Applied to open country the player has to NAVIGATE, that is wall-to-wall woodland
## with no clearings and no sight lines — the first play report was "spawned me in the middle
## of the forest and I have no idea where the roads are".
##
## It is also the cheapest lever on the overworld's frame cost: every streamed chunk builds a
## billboard field and a mesh field with colliders, so halving the instance count halves the
## per-chunk spawn spike. Raise it for denser woods, lower it if chunks hitch.
@export_range(0.0, 1.0, 0.05) var overworld_foliage_density := 0.35

## How long a REGION CROSSING takes to cross-fade its colours, in seconds. 0 snaps.
##
## The ground tint, the tarmac colour and the fog/background colour are lerped over this; the
## ground TEXTURES and the sky panorama still swap instantly, because blending those needs a
## second sampler plus a per-vertex region weight. The tint carries most of a region's character,
## so fading it carries most of the transition.
@export_range(0.0, 8.0, 0.1) var overworld_region_fade_s := 1.5

## Whether the overworld GROUND blends between regions SPATIALLY, at the fixed boundary between
## two regions, instead of the whole world restyling the moment the car crosses the line. Only
## the sky cross-fades over time (`overworld_region_fade_s` above); the ground is meant to arrive
## ahead of you and leave the ground behind you alone.
##
## Part of the terrain cache's invalidation key: turning it on or off changes the per-vertex data
## baked into every stored chunk (the region rank in UV2.y), so flipping it forces a ONE-TIME
## re-warm of the overworld chunk cache the next time the map is entered.
@export var overworld_region_blend_enabled := true

## How wide the visible region cross-fade is, as a FRACTION of the span between the two blended
## regions. Small = a crisp line on the ground; 1.0 = a gradient smeared across the whole span.
##
## Purely a shader remap of the baked rank, so changing it is free — it does NOT invalidate the
## chunk cache and needs no re-bake.
@export_range(0.02, 1.0, 0.01) var overworld_region_blend_width := 0.35
