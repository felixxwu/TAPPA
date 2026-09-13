extends GutTest
# SkillProgressPanel (scripts/skill_progress_panel.gd) — the between-stage "how much
# closer did that stage get me" CARD CAROUSEL, one card per skill whose gate stat actually
# moved this stage. Driven entirely off a SYNTHETIC skill roster
# (SkillLibrary.override_for_test) and synthetic profile/before-lifetime dicts, per
# CLAUDE.md — nothing here pins a shipped skill's id, price or threshold.
#
# Also carries THE NAV TEST CLAUDE.md requires of every menu: the carousel is the page's
# focusable body and MenuNav attaches to it, on a bare Control host with no world needed.

const FX_SKILLS: Array[Dictionary] = [
	{"id": "fx_locked", "label": "Locked Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 800}},
	{"id": "fx_unlocked", "label": "Unlocked Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 10}},
	{"id": "fx_owned", "label": "Owned Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 10}},
	{"id": "fx_untouched", "label": "Untouched Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_other_stat", "threshold": 800}},
]

var _host: Control


func before_each() -> void:
	Config.reset()
	SkillLibrary.override_for_test(FX_SKILLS)
	_host = Control.new()
	add_child_autofree(_host)


func after_each() -> void:
	SkillLibrary.reset()
	Config.reset()


# fx_locked and fx_unlocked both progressed this stage (fx_stat 100 -> 150); fx_owned's
# stat also moved but it's bought already; fx_other_stat (fx_untouched's gate) sat still.
func _profile() -> Dictionary:
	return {
		Save.KEY_LIFETIME: {"fx_stat": 150, "fx_other_stat": 400},
		Save.KEY_BOUGHT_SKILLS: ["fx_owned"],
		Save.KEY_EQUIPPED_SKILLS: [],
	}


func _before_lifetime() -> Dictionary:
	return {"fx_stat": 100, "fx_other_stat": 400}


func _page() -> MenuPage:
	return MenuPage.open_modal(_host, {"margin": SkillProgressPanel.PAGE_MARGIN,
		"title": "Skill progress"})


# Build the panel the way world.gd's _show_skill_progress does and hand back the carousel.
func _build(profile: Dictionary) -> CardCarousel:
	return SkillProgressPanel.build(_page(), profile, _before_lifetime())


func _all_text(carousel: CardCarousel) -> String:
	var texts := ""
	for node in carousel.find_children("*", "Label", true, false):
		texts += String((node as Label).text) + " "
	return texts


func test_the_panel_is_a_real_card_carousel_mounted_in_the_page() -> void:
	var page := _page()
	var carousel := SkillProgressPanel.build(page, _profile(), _before_lifetime())
	assert_not_null(carousel, "build returns the carousel it mounted")
	assert_false(page.find_children("*", "CardCarousel", true, false).is_empty(),
		"the carousel is mounted inside the page, not left detached")


func test_the_carousel_is_focusable_so_the_cards_can_be_navigated() -> void:
	var carousel := _build(_profile())
	assert_eq(carousel.focus_mode, Control.FOCUS_ALL,
		"the card list is one focusable unit (left/right move the selection)")
	assert_true(carousel.has_method("menu_nav_handles_side"),
		"and it owns left/right through MenuNav's seam")


func test_a_locked_skill_below_its_gate_shows_the_gates_fraction() -> void:
	var carousel := _build(_profile())
	var unlock := SkillLibrary.unlock_of("fx_locked")
	var expected := LifetimeStats.progress_text(150, int(unlock.get("threshold", 0)))
	assert_true(_all_text(carousel).to_upper().contains(expected.to_upper()),
		"a locked skill below its gate shows current/threshold")


func test_a_skill_at_or_over_its_gate_shows_the_unlocked_text() -> void:
	var carousel := _build(_profile())
	assert_true(_all_text(carousel).to_upper().contains("UNLOCKED"),
		"fx_unlocked's gate (10) is met by the 150 in the fixture profile")


func test_a_card_shows_how_much_this_stage_added() -> void:
	var carousel := _build(_profile())
	assert_true(_all_text(carousel).contains("+50"),
		"fx_stat moved 100 -> 150 this stage, so its cards should say +50")


func test_an_owned_skill_gets_no_card_even_though_its_stat_moved() -> void:
	var carousel := _build(_profile())
	assert_false(_all_text(carousel).to_upper().contains("OWNED FIXTURE SKILL"),
		"fx_owned is already bought — nothing left to progress, no card for it")


func test_a_skill_whose_gate_stat_did_not_move_this_stage_gets_no_card() -> void:
	var carousel := _build(_profile())
	assert_false(_all_text(carousel).to_upper().contains("UNTOUCHED FIXTURE SKILL"),
		"fx_untouched's gate stat (fx_other_stat) is unchanged this stage")


func test_only_progressed_skills_get_cards() -> void:
	var carousel := _build(_profile())
	# fx_locked and fx_unlocked progressed; fx_owned and fx_untouched did not.
	assert_eq(carousel.card_count(), 2,
		"one card per skill that actually moved this stage")


func test_no_progress_this_stage_shows_a_placeholder_card_not_an_empty_strip() -> void:
	var carousel := _build({
		Save.KEY_LIFETIME: {"fx_stat": 100, "fx_other_stat": 400},
		Save.KEY_BOUGHT_SKILLS: ["fx_owned"],
		Save.KEY_EQUIPPED_SKILLS: [],
	})
	assert_eq(carousel.card_count(), 1, "a single placeholder card, no skill cards")
	assert_false(carousel.get_card(0).disabled,
		"the placeholder is selectable — nothing is being refused, it's a read-out")


func test_the_page_can_be_navigated_by_keyboard_with_the_carousel_first() -> void:
	var page := _page()
	var carousel := SkillProgressPanel.build(page, _profile(), _before_lifetime())
	var carry_on := UITheme.button("Continue")
	page.add_action(carry_on)
	MenuNav.attach(page, {"first": carousel})
	assert_not_null(MenuNav.of(page), "the skill-progress page has a MenuNav attached")
	assert_eq(carry_on.focus_mode, Control.FOCUS_ALL,
		"and Continue is still reachable off the carousel")
