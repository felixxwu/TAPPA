extends GutTest
# LoadingTips: the flavor-text pool shown on the loading screen in place of the
# generation-stage name (see loading_screen.gd, world.gd::_stage).

func test_random_is_always_drawn_from_the_pool() -> void:
	for _i in 30:
		assert_true(LoadingTips.TIPS.has(LoadingTips.random()),
			"random() only ever returns a listed tip")


func test_the_pool_is_not_trivially_empty() -> void:
	# A sanity guard, not a content check (CLAUDE.md — don't pin authored values): an
	# empty or single-entry pool would make "random" a lie, whatever the wording says.
	assert_gt(LoadingTips.TIPS.size(), 1, "there is more than one tip to draw from")


func test_every_tip_is_non_empty_text() -> void:
	for tip in LoadingTips.TIPS:
		assert_gt(tip.length(), 0, "no blank entries in the pool")


# Consecutive draws never repeat — the same tip twice in a row across two separate loads
# reads as broken ("didn't it just say that?"), not as chance.
func test_consecutive_draws_never_repeat() -> void:
	var previous := LoadingTips.random()
	for _i in 40:
		var next := LoadingTips.random()
		assert_ne(next, previous, "back-to-back draws must differ")
		previous = next


# A one-entry pool can't honor "never repeats" (there is nothing else to pick), so it
# must degrade to returning that entry rather than looping forever. Exercised against a
# synthetic pool via the pure helper — TIPS is a const and can't be swapped out.
func test_a_single_entry_pool_returns_it_without_hanging() -> void:
	var pool: Array[String] = ["Only tip in town."]
	assert_eq(LoadingTips._pick_avoiding(pool, ""), "Only tip in town.",
		"the lone tip is returned with no prior draw")
	assert_eq(LoadingTips._pick_avoiding(pool, "Only tip in town."), "Only tip in town.",
		"and even when it IS the one to avoid, since there's nothing else")
