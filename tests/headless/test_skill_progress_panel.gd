extends GutTest
# SkillProgressPanel (scripts/skill_progress_panel.gd) — the between-stage "how much
# closer did that stage get me" read-out of every skill's unlock gate. Driven entirely
# off a SYNTHETIC skill roster (SkillLibrary.override_for_test) and a synthetic profile
# dict, per CLAUDE.md — nothing here pins a shipped skill's id, price or threshold.

const FX_SKILLS: Array[Dictionary] = [
	{"id": "fx_locked", "label": "Locked Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 800}},
	{"id": "fx_unlocked", "label": "Unlocked Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 10}},
	{"id": "fx_owned", "label": "Owned Fixture Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 10}},
]


func before_each() -> void:
	SkillLibrary.override_for_test(FX_SKILLS)


func after_each() -> void:
	SkillLibrary.reset()


func _profile() -> Dictionary:
	return {
		Save.KEY_LIFETIME: {"fx_stat": 150},
		Save.KEY_BOUGHT_SKILLS: ["fx_owned"],
		Save.KEY_EQUIPPED_SKILLS: [],
	}


func _labels(control: Control) -> Array[Label]:
	var out: Array[Label] = []
	for node in control.find_children("*", "Label", true, false):
		out.append(node as Label)
	return out


func test_a_locked_skill_below_its_gate_shows_the_gates_fraction() -> void:
	var grid := SkillProgressPanel.build(_profile())
	var unlock := SkillLibrary.unlock_of("fx_locked")
	var expected := LifetimeStats.progress_text(150, int(unlock.get("threshold", 0)))
	var texts := ""
	for l in _labels(grid):
		texts += String(l.text) + " "
	assert_true(texts.to_upper().contains(expected.to_upper()),
		"a locked skill below its gate shows current/threshold")


func test_a_skill_at_or_over_its_gate_shows_the_unlocked_text() -> void:
	var grid := SkillProgressPanel.build(_profile())
	var texts := ""
	for l in _labels(grid):
		texts += String(l.text) + " "
	assert_true(texts.to_upper().contains("UNLOCKED"),
		"fx_unlocked's gate (10) is met by the 150 in the fixture profile")


func test_an_owned_skill_shows_the_owned_text() -> void:
	var grid := SkillProgressPanel.build(_profile())
	var texts := ""
	for l in _labels(grid):
		texts += String(l.text) + " "
	assert_true(texts.to_upper().contains("OWNED"),
		"fx_owned is in KEY_BOUGHT_SKILLS, so its row reads Owned")


func test_the_row_count_matches_skill_library_all() -> void:
	var grid := SkillProgressPanel.build(_profile())
	assert_eq(grid.get_child_count(), SkillLibrary.all().size() * 2,
		"one key label plus one state label per skill")
