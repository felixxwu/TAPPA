extends GutTest
# The flat shell (scripts/hub_shell.gd) — the game's main scene and the only way into a
# run, replacing the deleted diegetic 3D hub.
#
# Two things are pinned here and nothing else:
#   1. NAVIGATION. CLAUDE.md requires every menu in the game to be keyboard + gamepad
#      navigable, and says a new menu ships with a nav test in the same piece of work.
#      That is the rule this file exists for.
#   2. The SCREEN GRAPH — which page leads where, and what each one does with the run
#      state. Deliberately NOT the page's looks, wording or button order: stage 3's shell
#      is explicitly a placeholder that stages 4-8 rewrite, and a test that pinned its
#      layout would break on every one of those stages while proving nothing.

var _save: Node
var _shell: HubShell


func before_each() -> void:
	CarFixtures.install()
	_save = Save
	_save.profile = _save._default_profile()
	_shell = HubShell.new()
	add_child_autofree(_shell)


func after_each() -> void:
	if RunSession.is_active():
		RunSession.pause_run()
	_save.clear_run()
	RunSession.clear_last_result()
	CarFixtures.restore()


func _page() -> MenuPage:
	return _shell._page


# Every focusable Button on the live page, in tree order.
func _buttons() -> Array:
	var out: Array = []
	for node in _page().find_children("*", "Button", true, false):
		if (node as Button).focus_mode != Control.FOCUS_NONE:
			out.append(node)
	return out


func _press(text: String) -> bool:
	for b in _buttons():
		if String((b as Button).text).to_upper().contains(text.to_upper()):
			(b as Button).pressed.emit()
			return true
	return false


# --- Navigation (the CLAUDE.md contract) --------------------------------------

# The rule, on every page the shell can show: a menu reachable only by pointer is not
# shippable. Walks the graph rather than testing one page, because the shell rebuilds its
# page on every transition and a nav wiring that is only correct on the first build is the
# failure this guards.
func test_every_page_is_keyboard_navigable() -> void:
	for view in [HubShell.View.MAIN, HubShell.View.REGION, HubShell.View.CAR,
			HubShell.View.SUMMARY, HubShell.View.SHOP, HubShell.View.BOOST_SHOP,
			HubShell.View.PERKS, HubShell.View.STATS, HubShell.View.CHALLENGE]:
		_shell._show(view)
		await get_tree().process_frame
		assert_not_null(MenuNav.of(_page()),
			"view %d has a MenuNav attached" % view)
		assert_gt(_buttons().size(), 0,
			"view %d offers at least one focusable control" % view)


func test_back_walks_the_page_stack_and_stops_at_the_root() -> void:
	_shell._show(HubShell.View.CAR)
	_shell._back()
	assert_eq(_shell._view, HubShell.View.REGION, "car backs out to region select")
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN, "region backs out to the main page")
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN,
		"and the root absorbs Back rather than dropping the player somewhere they never went")


func test_boost_shop_backs_out_to_the_shop_not_the_main_page() -> void:
	_shell._show(HubShell.View.BOOST_SHOP)
	_shell._back()
	assert_eq(_shell._view, HubShell.View.SHOP, "boost shop backs out to the shop page")
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN, "and the shop backs out to the main page")


# One page at a time. The shell frees the old page's CanvasLayer on every transition; a
# leaked one keeps claiming input and swallows the new page's navigation.
func test_showing_a_page_frees_the_previous_one() -> void:
	_shell._show(HubShell.View.REGION)
	var first := _page()
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(is_instance_valid(first) and first.is_inside_tree(),
		"the previous page is gone, not parked under the tree still claiming input")


# --- The screen graph ---------------------------------------------------------

func test_the_shell_opens_on_the_main_page_with_no_result_parked() -> void:
	assert_eq(_shell._view, HubShell.View.MAIN,
		"a fresh boot lands on the main page")


# The run's outcome has to survive the scene change back here, or the player is dropped at
# a title screen with no idea whether they cleared the region.
func test_a_finished_run_opens_the_summary_instead_of_the_main_page() -> void:
	RunSession._last_result = {"completed": false, "stages_completed": 3,
		"stage_count": 8, "money_earned": 400, "stage_times_ms": [1000, 2000, 3000]}
	var shell := HubShell.new()
	add_child_autofree(shell)
	await get_tree().process_frame
	assert_eq(shell._view, HubShell.View.SUMMARY,
		"the summary is shown for a run that just ended")


# The summary is one-shot: _ready() shows it whenever a result is parked, so a summary
# that did not clear the result would trap the player on it forever.
func test_continuing_from_the_summary_clears_the_result() -> void:
	RunSession._last_result = {"completed": true, "stages_completed": 8,
		"stage_count": 8, "money_earned": 900, "stage_times_ms": []}
	_shell._show(HubShell.View.SUMMARY)
	assert_true(_press("Continue"), "setup: the summary offers a way out")
	assert_true(RunSession.last_result().is_empty(),
		"the result is cleared, so returning to the hub does not re-open the summary")
	assert_eq(_shell._view, HubShell.View.MAIN, "and the player lands back on the main page")


# --- Decision 48: the paused-run confirm --------------------------------------

# The shell owes the other half of decision 48. Discarding a paused run BURNS its attempt,
# so starting a new run over the top of one must ask first — the rule is defensible, but
# discovering it after the fact is not.
func test_starting_a_run_over_a_paused_one_asks_first() -> void:
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	assert_true(RunSession.start_region("home", car), "setup: a run is going")
	RunSession.pause_run()

	_shell._pending_region = "home"
	_shell._start_run(car)
	await get_tree().process_frame

	assert_not_null(ConfirmPopup.any_open(get_tree()),
		"a confirm is raised rather than silently throwing the paused run away")
	# Leave nothing parked for the next test.
	var modal := ConfirmPopup.any_open(get_tree())
	if modal != null:
		(modal as ConfirmPopup).trigger_back()
		await get_tree().process_frame


func test_starting_a_run_with_nothing_paused_does_not_ask() -> void:
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	_shell._pending_region = "home"
	_shell._start_run(car)
	await get_tree().process_frame
	assert_null(ConfirmPopup.any_open(get_tree()),
		"nothing to lose, so nothing to confirm")
	assert_true(RunSession.is_active(), "and the run starts")


# --- Linear region unlock (stage 4) -------------------------------------------

# A locked region is on the page, named, and says what opens it — but is not focusable, so
# the keyboard cannot land on a row it can never press. Asserts the RULE against a
# synthetic order rather than the shipped table: which region is second is authored data a
# designer may reorder freely.
func test_a_locked_region_is_shown_but_not_focusable() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_first", "order": 0, "name": "First"},
		{"id": "fx_second", "order": 1, "name": "Second"},
	] as Array[Dictionary])
	_shell._show(HubShell.View.REGION)
	await get_tree().process_frame

	# UITheme.enforce uppercases button text, so compare case-insensitively rather than
	# pinning the presentation.
	var texts: Array[String] = []
	for b in _page().find_children("*", "Button", true, false):
		texts.append(String((b as Button).text).to_upper())
	var joined := " | ".join(texts)
	assert_true(joined.contains("SECOND"), "the locked region is still listed")
	assert_true(joined.contains("FIRST"), "and it names what opens it")

	for b in _buttons():
		assert_false(String((b as Button).text).to_upper().contains("LOCKED"),
			"a locked row is not focusable — the keyboard cannot land on it")
	RegionLibrary.reset()


func test_clearing_a_region_unlocks_the_next() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_first", "order": 0, "name": "First"},
		{"id": "fx_second", "order": 1, "name": "Second"},
	] as Array[Dictionary])
	assert_false(RegionLibrary.is_unlocked("fx_second", _save.profile),
		"setup: the second region starts locked")
	assert_true(RegionLibrary.is_unlocked("fx_first", _save.profile),
		"the first region is always open — a new profile must be able to start somewhere")

	_save.profile[_save.KEY_REGIONS_CLEARED] = ["fx_first"]
	assert_true(RegionLibrary.is_unlocked("fx_second", _save.profile),
		"clearing the first opens the second")
	RegionLibrary.reset()


# The ledger is what unlock reads, so only a run that cleared EVERY stage may write it.
func test_only_a_completed_run_records_the_region_as_cleared() -> void:
	var mode := RegionRunMode.for_region("home")
	mode.record_outcome({"completed": false, "stages_completed": 5}, 0)
	assert_false((_save.profile[_save.KEY_REGIONS_CLEARED] as Array).has("home"),
		"a run stopped by the clock has not cleared the region, however far it got")

	mode.record_outcome({"completed": true}, 0)
	assert_true((_save.profile[_save.KEY_REGIONS_CLEARED] as Array).has("home"),
		"clearing every stage records it")

	mode.record_outcome({"completed": true}, 0)
	assert_eq((_save.profile[_save.KEY_REGIONS_CLEARED] as Array).count("home"), 1,
		"a region stays replayable, so a second clear must not duplicate the entry")


# The invariant RegionLibrary's own header states: array position carries no meaning, so
# progression must read the authored `order` field. Reversing the table must not re-rank
# the game.
func test_progression_reads_the_authored_order_not_array_position() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_late", "order": 1, "name": "Late"},
		{"id": "fx_early", "order": 0, "name": "Early"},
	] as Array[Dictionary])
	assert_eq(RegionLibrary.order_of("fx_early"), 0,
		"the first region is the one authored order 0, not the one listed first")
	assert_true(RegionLibrary.is_unlocked("fx_early", _save.profile))
	assert_false(RegionLibrary.is_unlocked("fx_late", _save.profile))
	assert_eq(String(RegionLibrary.ordered()[0].get("id", "")), "fx_early",
		"ordered() sorts by the field, not by table position")
	assert_eq(RegionRunMode.for_region("fx_late").region_index(), 1,
		"and the run's difficulty/payout rank comes from the same field")
	RegionLibrary.reset()


# --- The meta shop (stage 6) ---------------------------------------------------

# Decision 28: the CAR page is no longer a dead end for a car-less profile — a fresh
# profile is seeded with money (GameConfig.run_starting_money) and the page lists
# unowned cars with a Buy action.
func test_a_car_less_profile_can_buy_from_the_car_page() -> void:
	assert_true((_save.profile.get(_save.KEY_CARS, []) as Array).is_empty(),
		"setup: nothing owned yet")
	assert_gt(_save.money(), 0, "setup: decision 28 seeds a starting purse")
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	var texts: Array[String] = []
	for b in _page().find_children("*", "Button", true, false):
		texts.append(String((b as Button).text).to_upper())
	var joined := " | ".join(texts)
	assert_true(joined.contains("BUY"), "the car page offers a Buy action, not a dead end")


func test_buying_a_car_from_the_shop_moves_it_into_the_owned_list() -> void:
	var cheapest := ""
	var cheapest_cost := -1
	for spec in CarLibrary.all():
		var cost := int(spec.get("cost", 0))
		if cheapest_cost < 0 or cost < cheapest_cost:
			cheapest = String(spec.get("id", ""))
			cheapest_cost = cost
	_save.profile[_save.KEY_MONEY] = cheapest_cost
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	assert_true(_press("Buy"), "setup: a buy row is on the page")
	assert_true(_save.owns_model(cheapest), "the cheapest car is now owned")


# An unaffordable row is disabled AND carries menu_nav_skip — the same rule the REGION
# page's locked rows follow (see test_a_locked_region_is_shown_but_not_focusable).
func test_an_unaffordable_car_row_is_shown_but_not_focusable() -> void:
	_save.profile[_save.KEY_MONEY] = 0
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	for b in _buttons():
		assert_false(String((b as Button).text).to_upper().begins_with("BUY"),
			"with no money, no Buy row is focusable")


func test_shop_reaches_boost_levels_and_engine_swap() -> void:
	_shell._show(HubShell.View.SHOP)
	await get_tree().process_frame
	assert_true(_press("Boost levels"), "the shop opens the boost-level page")
	assert_eq(_shell._view, HubShell.View.BOOST_SHOP)


func test_buying_a_boost_level_raises_it_and_spends_money() -> void:
	var id: String = BoostLibrary.CATALOGUE.keys()[0]
	_save.profile[_save.KEY_MONEY] = _save.boost_level_price(id)
	assert_eq(_save.boost_level(id), 0, "setup: level 0")
	_shell._show(HubShell.View.BOOST_SHOP)
	await get_tree().process_frame
	assert_true(_press(BoostLibrary.label_for(id)), "setup: the boost's row is on the page")
	assert_eq(_save.boost_level(id), 1, "the level went up by one")
	assert_eq(_save.money(), 0, "and the price was spent")


func test_buying_the_engine_swap_unlock_flips_the_flag() -> void:
	_save.profile[_save.KEY_MONEY] = _save.engine_swap_unlock_price()
	assert_false(_save.engine_swap_unlocked(), "setup: locked")
	_shell._show(HubShell.View.SHOP)
	await get_tree().process_frame
	assert_true(_press("Unlock Engine Swap"), "setup: the unlock row is on the page")
	assert_true(_save.engine_swap_unlocked(), "the flag is now set")


func test_the_engine_swap_row_is_shown_but_not_focusable_once_bought() -> void:
	_save.profile[_save.KEY_ENGINE_SWAP_UNLOCKED] = true
	_shell._show(HubShell.View.SHOP)
	await get_tree().process_frame
	var all_texts: Array[String] = []
	for b in _page().find_children("*", "Button", true, false):
		all_texts.append(String((b as Button).text).to_upper())
	assert_true(" | ".join(all_texts).contains("ENGINE SWAP"),
		"the row is still shown, saying the capability is owned")
	for b in _buttons():
		assert_false(String((b as Button).text).to_upper().contains("ENGINE SWAP"),
			"but it is not focusable — nothing left to buy")


# --- Perks + lifetime stats (stage 7) -------------------------------------------
# Synthetic perks throughout (PerkLibrary.override_for_test), never the shipped
# PERKS table — per CLAUDE.md, a perk's price/threshold/existence is authored data
# and must not be pinned by a test.

const FX_PERKS: Array[Dictionary] = [
	{
		"id": "fx_locked", "label": "Fixture Locked Perk", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 999},
	},
	{
		"id": "fx_buyable", "label": "Fixture Buyable Perk", "price": 50,
		"unlock": {"stat": "fx_stat", "threshold": 0},
	},
]


func test_perks_page_shows_a_locked_perk_but_not_focusable() -> void:
	PerkLibrary.override_for_test(FX_PERKS)
	_shell._show(HubShell.View.PERKS)
	await get_tree().process_frame
	var texts: Array[String] = []
	for b in _page().find_children("*", "Button", true, false):
		texts.append(String((b as Button).text).to_upper())
	assert_true(" | ".join(texts).contains("FIXTURE LOCKED PERK"), "the locked perk is still shown")
	for b in _buttons():
		assert_false(String((b as Button).text).to_upper().contains("FIXTURE LOCKED PERK"),
			"but it is not focusable — its threshold has not been crossed")
	PerkLibrary.reset()


func test_buying_an_unlocked_perk_from_the_page_moves_it_to_owned() -> void:
	PerkLibrary.override_for_test(FX_PERKS)
	_save.profile[_save.KEY_MONEY] = 50
	_shell._show(HubShell.View.PERKS)
	await get_tree().process_frame
	assert_true(_press("Buy Fixture Buyable Perk"), "setup: a buy row is on the page")
	assert_true(_save.owns_perk("fx_buyable"), "the perk is now owned")
	PerkLibrary.reset()


func test_equipping_an_owned_perk_from_the_page_marks_it_equipped() -> void:
	PerkLibrary.override_for_test(FX_PERKS)
	_save.profile[_save.KEY_MONEY] = 50
	_save.buy_perk("fx_buyable")
	_shell._show(HubShell.View.PERKS)
	await get_tree().process_frame
	assert_true(_press("Equip"), "setup: an equip row is on the page")
	assert_true(_save.perk_equipped("fx_buyable"))
	PerkLibrary.reset()


func test_stats_page_lists_every_lifetime_stat_and_still_backs_out() -> void:
	_save.profile[_save.KEY_LIFETIME] = {}
	_shell._show(HubShell.View.STATS)
	await get_tree().process_frame
	var texts: Array[String] = []
	# Walk the whole subtree, not just direct children: MenuPage nests its body inside a
	# scroll container. And compare UPPERCASED — UITheme.enforce uppercases every label, so
	# a case-sensitive match tests the theme's casing rather than the page's content.
	for label in _page().find_children("*", "Label", true, false):
		texts.append(String((label as Label).text).to_upper())
	var joined := " | ".join(texts)
	for id in LifetimeStats.IDS:
		assert_true(joined.contains(LifetimeStats.label_for(String(id)).to_upper()),
			"the stats page shows a row for '%s'" % id)
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN, "stats backs out to the main page")


# --- The challenge entry point (stage 9, decision 15) ---------------------------------
#
# The MINIMUM that makes the retained challenge mode reachable. These pin the SCREEN GRAPH
# and the eligibility gate, not the wording or the period rules (ChallengeLibrary's own
# tests own those).

func test_the_main_page_reaches_the_challenge() -> void:
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	assert_true(_press("Rally challenge"), "the main page offers the challenge")
	assert_eq(_shell._view, HubShell.View.CHALLENGE)


func test_the_challenge_page_backs_out_to_main() -> void:
	_shell._show(HubShell.View.CHALLENGE)
	await get_tree().process_frame
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN)


# Picking a period hands off to the SHARED car page — and the car page must then back out
# to the challenge, not to region select, or the player is dropped into a flow they never
# opened.
func test_picking_a_period_opens_the_car_page_and_backs_out_to_the_challenge() -> void:
	_shell._show(HubShell.View.CHALLENGE)
	await get_tree().process_frame
	assert_true(_press("Daily"), "a live period is offered")
	assert_eq(_shell._view, HubShell.View.CAR)
	await get_tree().process_frame
	_shell._back()
	assert_eq(_shell._view, HubShell.View.CHALLENGE)


# Region select CLEARS the pending challenge, so a player who backs out of a challenge and
# starts a region run does not silently start a challenge instead.
func test_opening_region_select_clears_a_pending_challenge() -> void:
	_shell._show(HubShell.View.CHALLENGE)
	await get_tree().process_frame
	assert_true(_press("Daily"))
	assert_ne(_shell._pending_challenge, "", "setup: a challenge is pending")
	_shell._show(HubShell.View.REGION)
	await get_tree().process_frame
	assert_eq(_shell._pending_challenge, "", "region select drops the challenge intent")


# --- Drivetrain conversions: MOVED to the between-stage pick -----------------------
#
# Decision 52 (a per-car purchase sold from the SHOP page, DRIVETRAIN / DRIVETRAIN_CAR) is
# superseded: a conversion is now a run-scoped mid-run upgrade picked between stages
# (RunSession.choose_drivetrain, RunPickPanel), so the SHOP no longer hosts it — see
# tests/headless/test_run_pick_panel.gd and test_run_session.gd for the coverage that
# replaces this block.
