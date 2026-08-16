extends GutTest
# Nitrous: the per-STAGE torque boost (features/nitrous.md). Bare EngineSim + a synthetic
# GameConfig — no scene, no catalogue entry — so nothing here depends on the authored
# nitrous tune. Every test asserts a RELATIONSHIP that must hold for any reasonable
# values, never a chosen number.

const SUB := 1.0 / 480.0  # one spin substep at 60 Hz x 8 (drivetrain.SPIN_SUBSTEPS)


# A config with nitrous fitted. Values are arbitrary test inputs, deliberately unlike the
# shipped tune, so a designer retuning the catalogue can't break these tests.
func _cfg(gain := 0.5, tank := 2.0) -> GameConfig:
	var cfg := GameConfig.new()
	cfg.peak_torque = 300.0
	cfg.global_torque_scale = 1.0
	cfg.idle_rpm = 900.0
	cfg.redline_rpm = 7000.0
	cfg.nitrous_boost_gain = gain
	cfg.nitrous_tank_seconds = tank
	return cfg


func _engine(cfg: GameConfig) -> EngineSim:
	var e := EngineSim.new(cfg)
	e.reset()
	return e


# Free-rev the engine for `steps` substeps at full throttle, nitrous held or not, and
# return the omega reached. Neutral (gear 0) keeps the driveline out of it.
func _climb(e: EngineSim, steps: int, nitrous: bool) -> float:
	e.gear = 0
	for _i in steps:
		e.nitrous_active = nitrous
		e.step(SUB, 1.0, 0.0)
	return e.omega


# Spray for `steps` substeps while holding the engine at a mid rpm. Pinning omega matters:
# a free-revving engine reaches the LIMITER within a few hundred substeps, and a rev-limiter
# fuel cut correctly suspends delivery — so a free-rev loop drains only intermittently and
# can never empty the tank. Anything measuring DURATION has to keep combustion alive.
func _spray(e: EngineSim, steps: int, nitrous := true) -> void:
	var mid := (e.config.idle_rpm + e.config.redline_rpm) * 0.5 * TAU / 60.0
	for _i in steps:
		e.gear = 0
		e.omega = mid
		e.nitrous_active = nitrous
		e.step(SUB, 1.0, 0.0)


# --- Fitted / not fitted -----------------------------------------------------

func test_has_nitrous_needs_both_a_gain_and_a_tank() -> void:
	# has_nitrous reads the VALUES, not a separate flag, so either one at zero means
	# "nothing to deliver" — mirroring has_supercharger_physics.
	assert_true(_cfg().has_nitrous(), "a gain and a tank means fitted")
	assert_false(_cfg(0.0, 2.0).has_nitrous(), "no gain means not fitted")
	assert_false(_cfg(0.5, 0.0).has_nitrous(), "no tank means not fitted")


func test_an_unfitted_engine_carries_no_charge_and_reports_nothing() -> void:
	var e := _engine(_cfg(0.0, 0.0))
	assert_eq(e.nitrous_charge, 0.0, "no tank to fill")
	assert_eq(e.nitrous_fraction(), 0.0, "and nothing to show on the gauge")


# --- The refill rule ---------------------------------------------------------

func test_reset_refills_the_tank() -> void:
	# THE anti-exploit property: car.reset_to() calls engine.reset(), so every stage start
	# AND every in-stage reset-to-start begins full. There is deliberately no spent state
	# to carry between events, so there is nothing to savescum and no partial tank to
	# reason about.
	var cfg := _cfg()
	var e := _engine(cfg)
	assert_eq(e.nitrous_fraction(), 1.0, "a fresh engine starts full")
	_spray(e, 200)
	assert_lt(e.nitrous_fraction(), 1.0, "holding it drains the tank")
	e.reset()
	assert_eq(e.nitrous_fraction(), 1.0, "reset refills to full")


func test_the_gauge_fraction_tracks_the_tank_and_stays_bounded() -> void:
	var cfg := _cfg()
	var e := _engine(cfg)
	for _i in 2000:  # comfortably longer than the tank, at a held mid rpm
		_spray(e, 1)
		assert_between(e.nitrous_fraction(), 0.0, 1.0, "the gauge reading stays in 0..1")
	assert_eq(e.nitrous_fraction(), 0.0, "and reaches empty")


# --- Delivery ----------------------------------------------------------------

func test_holding_nitrous_makes_more_torque() -> void:
	var cfg := _cfg()
	var plain := _climb(_engine(cfg), 150, false)
	var boosted := _climb(_engine(cfg), 150, true)
	assert_gt(boosted, plain, "nitrous held accelerates the engine harder")


func test_a_bigger_gain_makes_more_torque() -> void:
	# The gain is the "harder" lever of the upgrade ladder.
	var small := _climb(_engine(_cfg(0.2)), 150, true)
	var big := _climb(_engine(_cfg(0.9)), 150, true)
	assert_gt(big, small, "a larger boost gain delivers more")


func test_an_empty_tank_delivers_nothing() -> void:
	# Once dry, a held button must be inert — otherwise the tank size would mean nothing.
	var cfg := _cfg(0.5, 0.05)  # a deliberately tiny tank
	# Two engines drained by the SAME history, so they start the comparison in an identical
	# state and the only difference is whether the (dead) button is held.
	var held := _engine(cfg)
	var released := _engine(cfg)
	_spray(held, 200)
	_spray(released, 200)
	assert_eq(held.nitrous_fraction(), 0.0, "setup: the tank is dry")
	assert_eq(held.omega, released.omega, "setup: both engines are in the same state")
	assert_almost_eq(_climb(held, 150, true), _climb(released, 150, false), 0.001,
		"holding an empty tank behaves exactly like not holding it")


func test_a_bigger_tank_lasts_longer() -> void:
	# The tank is the "longer" lever. Same gain, so the only difference is duration.
	var short := _engine(_cfg(0.5, 0.5))
	var long := _engine(_cfg(0.5, 3.0))
	_spray(short, 400)
	_spray(long, 400)
	assert_eq(short.nitrous_fraction(), 0.0, "the small tank empties")
	assert_gt(long.nitrous_fraction(), 0.0, "the big one still has charge")


# --- The drain gate ----------------------------------------------------------

func test_off_throttle_does_not_drain_the_tank() -> void:
	# Nitrous only flows when it would actually do something, so the button can't be used
	# to dump the tank while coasting.
	var e := _engine(_cfg())
	e.gear = 0
	for _i in 200:
		e.nitrous_active = true
		e.step(SUB, 0.0, 0.0)  # closed throttle
	assert_eq(e.nitrous_fraction(), 1.0, "a closed throttle burns nothing")


func test_releasing_the_button_stops_the_drain() -> void:
	var e := _engine(_cfg())
	_spray(e, 100)
	var held := e.nitrous_fraction()
	assert_lt(held, 1.0, "setup: some charge was used")
	_spray(e, 200, false)
	assert_eq(e.nitrous_fraction(), held, "released, the tank stops draining")


# --- The audio cue edges -----------------------------------------------------

func test_the_trigger_flag_fires_only_on_the_delivery_edge() -> void:
	var e := _engine(_cfg())
	e.gear = 0
	e.nitrous_active = true
	e.step(SUB, 1.0, 0.0)
	assert_true(e.nitrous_event, "the first delivering substep is an edge")
	e.step(SUB, 1.0, 0.0)
	assert_false(e.nitrous_event, "a continuing spray is not a new edge")


func test_the_empty_flag_fires_when_the_tank_runs_dry() -> void:
	var e := _engine(_cfg(0.5, 0.05))
	var saw_empty := false
	for _i in 400:
		_spray(e, 1)
		if e.nitrous_emptied:
			saw_empty = true
	assert_true(saw_empty, "running dry raises the cutoff cue")


# --- It must not leak between cars -------------------------------------------

func test_fielding_an_engine_clears_a_previous_cars_nitrous() -> void:
	# THE leak guard. The player car runs on the shared Config.data resource, and
	# install_nitrous only ever WRITES its fields — so without a hard reset per fielding,
	# fielding a nitrous car and then a car without one would hand the second car a free
	# tank (plus a HUD gauge and a mobile NOS button it never earned). EngineLibrary.apply
	# runs BEFORE UpgradeLibrary.apply in car.gd's pipeline, so a car that really has
	# nitrous still gets it written back afterwards.
	var cfg := _cfg()  # nitrous fitted
	assert_true(cfg.has_nitrous(), "setup: the config carries a previous car's nitrous")
	# Iterate the catalogue as opaque input — no engine authors nitrous, which is the point.
	for engine in EngineLibrary.all():
		EngineLibrary.apply(engine, cfg)
		assert_false(cfg.has_nitrous(),
			"fielding engine '%s' clears leftover nitrous" % engine.get("id", "?"))
		return


func test_a_fitted_nitrous_survives_the_engine_reset() -> void:
	# The other half: the reset must not defeat a car that legitimately has nitrous, since
	# upgrades are applied after the engine. Mirrors car.gd's ordering.
	var cfg := GameConfig.new()
	var car := {"model_id": "x", "installed_upgrades": ["nitrous"], "disabled_upgrades": [],
		"tuning": {}}
	for engine in EngineLibrary.all():
		EngineLibrary.apply(engine, cfg)
		break
	UpgradeLibrary.apply(car, cfg)
	assert_true(cfg.has_nitrous(), "a fitted nitrous is written back after the engine reset")


func test_refresh_fitment_revives_nitrous_installed_after_the_engine_was_built() -> void:
	# THE staleness guard for the per-substep `_has_nitrous` cache. car.gd builds the
	# drivetrain (and so the EngineSim) BEFORE applying upgrades, so an engine is always
	# constructed believing nitrous is unfitted; the upgrade layer then writes the fields.
	# A rally is bailed out by staging calling reset(), but free roam never resets — so
	# without refresh_fitment the gate stays false and a fitted nitrous is silently dead.
	var cfg := GameConfig.new()          # no nitrous yet, as after EngineLibrary.apply
	var e := _engine(cfg)
	assert_eq(e.nitrous_fraction(), 0.0, "setup: built while unfitted")
	# The upgrade layer lands, mutating the SAME config the engine holds.
	cfg.nitrous_boost_gain = 0.5
	cfg.nitrous_tank_seconds = 2.0
	e.refresh_fitment()
	assert_eq(e.nitrous_fraction(), 1.0, "a newly fitted tank shows up, and starts full")
	var plain := _climb(_engine(_cfg(0.0, 0.0)), 150, true)
	assert_gt(_climb(e, 150, true), plain, "and it actually delivers torque")


func test_refresh_fitment_clears_nitrous_that_has_been_removed() -> void:
	var cfg := _cfg()
	var e := _engine(cfg)
	assert_eq(e.nitrous_fraction(), 1.0, "setup: fitted and full")
	cfg.nitrous_boost_gain = 0.0
	cfg.nitrous_tank_seconds = 0.0
	e.refresh_fitment()
	assert_eq(e.nitrous_fraction(), 0.0, "removing it empties the tank")
	assert_false(e.nitrous_delivering, "and stops any delivery")


# --- Awarding it ---------------------------------------------------------------

func test_nitrous_has_a_garage_row_and_installs_like_any_other_part() -> void:
	# CHANGED DELIBERATELY: nitrous used to be a HIDDEN slot, auto-fitted ENABLED on award,
	# because a four-rung ladder that always installed its highest rung left the player
	# nothing to decide. It is one part now, so it gets an ordinary garage row — and
	# without one, a won NOS could only ever be fitted by the award path, never by the
	# player.
	assert_false(UpgradeLibrary.is_hidden_slot("nitrous"),
		"the nitrous slot is shown in the garage")
	assert_false(UpgradeLibrary.installs_enabled("nitrous"),
		"so it installs DISABLED like every other part, for the player to switch on")
	assert_false(UpgradeLibrary.installs_enabled("turbo_small"),
		"same as a part that always had a row")


# --- Eligibility isolation ---------------------------------------------------

func test_nitrous_never_reaches_power_to_weight() -> void:
	# The load-bearing rule: nitrous is a per-stage resource, not a stat. If it fed
	# effective_meta, a bottle the player empties in one stage would read as a permanent
	# power level everywhere a build is compared or displayed.
	var meta := {"mass": 1200.0, "peak_torque": 400.0, "redline": 6000.0,
		"drive_mode": CarLibrary.RWD}
	var bare := {"model_id": "x", "installed_upgrades": [], "disabled_upgrades": [], "tuning": {}}
	var nos := {"model_id": "x", "installed_upgrades": ["nitrous"], "disabled_upgrades": [],
		"tuning": {}}
	assert_eq(
		CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(nos, meta.duplicate())),
		CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(bare, meta.duplicate())),
		"a fitted nitrous leaves power-to-weight untouched")
