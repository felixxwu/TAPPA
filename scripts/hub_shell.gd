class_name HubShell
extends Control
# Docs: features/hub-shell.md — update in the same change as this file.
# Tests: tests/headless/test_hub_shell.gd — extend in the same change. Before you change
# behaviour here, `grep -rn 'HubShell' tests/headless/` and read what is pinned.
#
# THE FLAT SHELL: the game's main scene, and the only way into a run.
#
# It replaces the diegetic 3D hub (`hq.tscn`, 3527 lines) and the overworld, both deleted
# in stage 2b of todo/roguelike-pivot-plan.md. Decision 9 chose a flat 2D UI outright, so
# there is no 3D station, no camera pose, no spatial navigation — every screen here is a
# flat MenuPage and every one of them is keyboard + gamepad navigable through
# MenuNav.attach, which CLAUDE.md requires of every menu in the game.
#
# DELIBERATELY PLAIN. Stage 3's bar is "the loop runs start to finish", not "the loop looks
# good": this is four stacked pages of buttons. Stages 4-8 replace the region and car pages
# with real screens (a shop, boost levels, perks, lifetime stats) and this file is expected
# to be rewritten around them. Do not invest in its looks now, and do not grow it into the
# place those features live — give each its own script when it lands.
#
# WHY ONE SCRIPT AND ONE SCENE: the pages share nothing but a host and a back stack, and
# the whole shell is smaller than any one of the nine hub collaborators it replaces.
# Splitting it now would be four files that each do one `for` loop.

# The pages, as a plain stack. `_page` is the live MenuPage; `_view` says which screen it
# is showing, so `_back()` knows where to go and the tests can assert a screen without
# reading button text.
#
# SHOP / BOOST_SHOP are stage 6's meta shop (todo/roguelike-pivot.md "Upgrades — RR's
# two-tier model" + "Car acquisition — RR's shop"): boost levels and the Engine Swap
# unlock, both reached from MAIN rather than from the run's own car-select flow, since
# they are permanent purchases available any time, not something tied to picking a car
# for THIS run. Car BUYING, per decision 28's wording ("the car select screen offers a
# Buy action for unowned cars"), is folded into the existing CAR page instead of a fifth
# view — see _build_car().
enum View { MAIN, REGION, CAR, SUMMARY, SHOP, BOOST_SHOP }

# RunSession is an autoload with no class_name, so its STATIC members must be reached
# through the script resource — calling a static via the autoload instance is a
# STATIC_CALLED_ON_INSTANCE warning, which test_smoke.gd treats as a failure.
const RunSessionScript = preload("res://scripts/run_session.gd")

var _view: int = View.MAIN
var _page: MenuPage = null
# The region the player picked on the REGION page, held while they pick a car on the next.
var _pending_region := ""


func _ready() -> void:
	# A run that ended hands control back here (world.gd -> Scenes.hub_path()). Show its
	# summary rather than the main menu, or the player is dropped at a title screen with no
	# idea whether they cleared the region — the run's outcome is the whole point of it.
	if not RunSession.last_result().is_empty():
		_show(View.SUMMARY)
	else:
		_show(View.MAIN)


# The heading each view carries. The SUMMARY heading is the one that says something the
# player cannot get anywhere else on that page: whether the run ended by clearing the
# region or by missing a target.
func _title_for(view: int) -> String:
	match view:
		View.REGION: return "Pick a region"
		View.CAR: return "Pick a car"
		View.SUMMARY:
			var completed := bool(RunSession.last_result().get("completed", false))
			return "Region cleared" if completed else "Run over"
		View.SHOP: return "Shop"
		View.BOOST_SHOP: return "Boost levels"
		_: return "TAPPA"


# --- Page plumbing -----------------------------------------------------------

# Tear the current page down and build the next. Every screen goes through here, so there
# is exactly one place that can leave a stale page parked under the tree.
func _show(view: int) -> void:
	_view = view
	if is_instance_valid(_page):
		var layer := _page.get_parent()
		if is_instance_valid(layer):
			layer.queue_free()
		_page = null
	# The heading is a CONSTRUCTION option, not a settable property: MenuPage builds no
	# label at all when "title" is absent, and title_label() is then null.
	_page = MenuPage.open_modal(self, {"margin": 24.0, "title": _title_for(view)})
	match view:
		View.MAIN: _build_main()
		View.REGION: _build_region()
		View.CAR: _build_car()
		View.SUMMARY: _build_summary()
		View.SHOP: _build_shop()
		View.BOOST_SHOP: _build_boost_shop()
	# `remember: false` — each page is rebuilt from scratch, so there is no earlier focus
	# on it worth restoring; the first action is always the right landing spot.
	MenuNav.attach(_page, {"on_back": _back})


# Esc / gamepad B. MAIN and SUMMARY are roots — backing out of them does nothing rather
# than dropping the player into a page they never opened.
func _back() -> void:
	match _view:
		View.REGION: _show(View.MAIN)
		View.CAR: _show(View.REGION)
		View.SHOP: _show(View.MAIN)
		View.BOOST_SHOP: _show(View.SHOP)
		_: pass


func _action(text: String, on_press: Callable) -> Button:
	var b := UITheme.button(text)
	b.pressed.connect(on_press)
	return _page.add_action(b)


# A body row that reads as a list entry. Buttons rather than labels because every row here
# is chooseable, and MenuNav only walks focusable controls — a label row would be invisible
# to the keyboard and break the navigation contract.
func _row(text: String, on_press: Callable) -> Button:
	var b := UITheme.button(text)
	b.pressed.connect(on_press)
	_page.body().add_child(b)
	return b


# --- MAIN --------------------------------------------------------------------

func _build_main() -> void:
	var money := UITheme.label("Money: %d" % Save.money())
	_page.body().add_child(money)

	# A paused run is offered FIRST, because the alternative — starting anything else —
	# discards it and burns its attempt (decision 48). Putting Resume anywhere but the top
	# is how a player loses a run they meant to finish.
	var resumable: Dictionary = RunSessionScript.resumable_run(
		Save.profile, int(Time.get_unix_time_from_system()))
	if not resumable.is_empty():
		_row("Resume run", _resume_run)

	_row("New run", func() -> void: _show(View.REGION))
	_row("Shop", func() -> void: _show(View.SHOP))
	_action("Quit", func() -> void: get_tree().quit())


func _resume_run() -> void:
	if RunSession.resume(int(Time.get_unix_time_from_system())):
		Scenes.change_to(get_tree(), Scenes.MAIN)


# --- REGION ------------------------------------------------------------------

# Regions in AUTHORED order (RegionLibrary.ordered), not table order — the table's own
# header says array position is meaningless, and the player meets these in progression
# order or the list is nonsense.
#
# A locked region is SHOWN, named, and says what opens it. Hiding it would leave a new
# player with one row and no idea the game continues; showing it unpressable with no
# explanation is worse. Its button is disabled, so MenuNav skips it and the keyboard
# cannot land on a dead row.
func _build_region() -> void:
	var cleared: Array = Save.profile.get(Save.KEY_REGIONS_CLEARED, [])
	for region in RegionLibrary.ordered():
		var id := String(region.get("id", ""))
		if id == "":
			continue
		var region_name := String(region.get("name", id))
		if not RegionLibrary.is_unlocked(id, Save.profile):
			var gate := RegionLibrary.gate_for(id)
			var locked := _row("%s — locked (clear %s)" % [region_name, gate],
				func() -> void: pass)
			locked.disabled = true
			# The framework's own opt-out. Setting focus_mode here would be undone:
			# MenuNav.attach runs AFTER this build and re-enables focus on every
			# BaseButton it finds, skipping only those carrying this meta.
			locked.set_meta("menu_nav_skip", true)
			locked.focus_mode = Control.FOCUS_NONE
			continue
		var mark := " — cleared" if cleared.has(id) else ""
		_row(region_name + mark, func() -> void:
			_pending_region = id
			_show(View.CAR))
	_action("Back", func() -> void: _show(View.MAIN))


# --- CAR ---------------------------------------------------------------------

# Owned cars are selectable to start the run; unowned cars offer a Buy action, per
# decision 28's own wording ("the car select screen offers a Buy action for unowned
# cars") — one combined screen rather than a separate shop page for cars, so buying and
# picking share the exact same list a player is already looking at. This is also what
# retires the old dead end: a fresh profile owns nothing, but decision 28 seeds it with
# money (GameConfig.run_starting_money), so the same page that used to say "no cars yet"
# now lists something it can actually afford.
func _build_car() -> void:
	_page.body().add_child(UITheme.label("Money: %d" % Save.money()))
	var owned: Array = Save.profile.get(Save.KEY_CARS, [])
	for car in owned:
		var entry: Dictionary = car
		var iid := int(entry.get("instance_id", -1))
		if iid < 0:
			continue
		var spec: Dictionary = CarLibrary.for_owned(entry)
		var label := String(spec.get("name", entry.get("model_id", "car")))
		_row(label, func() -> void: _start_run(entry))

	for spec in CarLibrary.all():
		var model_id := String(spec.get("id", ""))
		if model_id.is_empty() or Save.owns_model(model_id):
			continue
		var cost := int(spec.get("cost", 0))
		var car_name := String(spec.get("name", model_id))
		var buy_row := _row("Buy %s — %d" % [car_name, cost],
			func() -> void: _buy_car(model_id))
		if Save.money() < cost:
			# The framework's own opt-out (see the REGION page's locked rows): setting
			# focus_mode alone would be undone, since MenuNav.attach runs AFTER this build
			# and re-enables focus on every BaseButton it finds.
			buy_row.disabled = true
			buy_row.set_meta("menu_nav_skip", true)
			buy_row.focus_mode = Control.FOCUS_NONE

	_action("Back", func() -> void: _show(View.REGION))


func _buy_car(model_id: String) -> void:
	if Save.buy_car(model_id):
		# Rebuild in place: the bought car now belongs in the owned list above and must
		# drop out of the buy list below it.
		_show(View.CAR)


# Start the region run — but a PAUSED run of either kind is a single slot (decision 27),
# so starting this one throws that one away and burns its attempt (decision 48). The
# confirm has to say so in those words: the rule is defensible, discovering it after the
# fact is not.
func _start_run(owned_car: Dictionary) -> void:
	var now := int(Time.get_unix_time_from_system())
	if RunSessionScript.resumable_run(Save.profile, now).is_empty():
		_begin_run(owned_car)
		return
	ConfirmPopup.open(self, "Abandon your paused run?",
		"You have a run paused. Starting a new one throws it away, and the attempt is "
		+ "used — you cannot go back to it.",
		[{"label": "Keep it", "callback": func() -> void: pass},
		 {"label": "Abandon it", "callback": func() -> void:
			RunSession.discard_run(now)
			_begin_run(owned_car)}])


func _begin_run(owned_car: Dictionary) -> void:
	if RunSession.start_region(_pending_region, owned_car):
		Scenes.change_to(get_tree(), Scenes.MAIN)


# --- SUMMARY -----------------------------------------------------------------

# One screen for BOTH outcomes — cleared the region, or stopped by the clock. A run that
# ends on a missed target has no placement to celebrate, and the same information is worth
# reading either way (gameplay.md -> "The run, end to end").
func _build_summary() -> void:
	var result: Dictionary = RunSession.last_result()
	var done := int(result.get("stages_completed", 0))
	var total := int(result.get("stage_count", 0))
	_page.body().add_child(UITheme.label("Stages cleared: %d / %d" % [done, total]))
	_page.body().add_child(UITheme.label("Money earned: %d" % int(result.get("money_earned", 0))))

	var times: Array = result.get("stage_times_ms", [])
	for i in times.size():
		var ms := int(times[i])
		_page.body().add_child(UITheme.label(
			"Stage %d: %.2fs" % [i + 1, float(ms) / 1000.0]))

	# Clearing the stored result is what makes this screen one-shot: _ready() shows the
	# summary whenever one is parked, so leaving it set would trap the player here.
	_action("Continue", func() -> void:
		RunSession.clear_last_result()
		_show(View.MAIN))


# --- SHOP ----------------------------------------------------------------------
# Stage 6's meta shop (todo/roguelike-pivot.md "Upgrades — RR's two-tier model" + "Car
# acquisition — RR's shop"). Reached from MAIN, not from the run-starting flow: boost
# levels and the Engine Swap unlock are permanent purchases available any time, unlike car
# buying, which decision 28 keeps on the CAR page above (see that function's own comment).

func _build_shop() -> void:
	_page.body().add_child(UITheme.label("Money: %d" % Save.money()))
	_row("Boost levels", func() -> void: _show(View.BOOST_SHOP))

	var unlocked := Save.engine_swap_unlocked()
	var price := Save.engine_swap_unlock_price()
	var swap_row := _row(
		"Engine Swap — unlocked" if unlocked else "Unlock Engine Swap — %d" % price,
		func() -> void: _buy_engine_swap_unlock())
	if unlocked or Save.money() < price:
		# Same opt-out as every other unpressable row on this shell: menu_nav_skip, not
		# just focus_mode, because MenuNav.attach re-enables focus on every BaseButton
		# after the page is built.
		swap_row.disabled = true
		swap_row.set_meta("menu_nav_skip", true)
		swap_row.focus_mode = Control.FOCUS_NONE

	_action("Back", func() -> void: _show(View.MAIN))


func _buy_engine_swap_unlock() -> void:
	if Save.buy_engine_swap_unlock():
		_show(View.SHOP)


# --- BOOST_SHOP ------------------------------------------------------------------
# One row per BoostLibrary.CATALOGUE id: its level (out of GameConfig.boost_level_max), the
# price of the NEXT level, and the effect range the whole ladder covers (decision 42 — "the
# shop shows the effect range per level ... so the purchase is legible without a live car to
# compute against"; BoostLibrary.effect_range_text is that formatting). Pressing a row buys
# the next level; a row at the cap or the player cannot afford is disabled + menu_nav_skip,
# same pattern as every other unpressable row on this shell.
func _build_boost_shop() -> void:
	_page.body().add_child(UITheme.label("Money: %d" % Save.money()))
	var max_level := int(Config.data.boost_level_max)
	for id in BoostLibrary.CATALOGUE:
		var boost_id := String(id)
		var level := Save.boost_level(boost_id)
		var label := BoostLibrary.label_for(boost_id)
		var range_text := BoostLibrary.effect_range_text(boost_id)
		var at_cap := level >= max_level
		var row_text: String
		if at_cap:
			row_text = "%s — MAX (Lv %d/%d, rolls %s)" % [label, level, max_level, range_text]
		else:
			var price := Save.boost_level_price(boost_id)
			row_text = "%s — Lv %d/%d, rolls %s — %d" % [label, level, max_level, range_text, price]
		var row := _row(row_text, func() -> void: _buy_boost_level(boost_id))
		if at_cap or Save.money() < Save.boost_level_price(boost_id):
			row.disabled = true
			row.set_meta("menu_nav_skip", true)
			row.focus_mode = Control.FOCUS_NONE
	_action("Back", func() -> void: _show(View.SHOP))


func _buy_boost_level(id: String) -> void:
	if Save.buy_boost_level(id):
		_show(View.BOOST_SHOP)
