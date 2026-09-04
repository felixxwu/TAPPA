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
			HubShell.View.SUMMARY]:
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
