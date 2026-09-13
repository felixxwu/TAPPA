class_name SkillProgressPanel
extends RefCounted
# Docs: features/skills.md — update in the same change as this file.
# Tests: tests/headless/test_skill_progress_panel.gd — extend in the same change.
#
# "HOW MUCH CLOSER DID THAT STAGE GET ME?" — the between-stage read-out of every skill's
# unlock gate, shown right after the upgrade confirmation (world.gd's interstitial
# sequence: pick -> what it does to the car -> this). Every skill is gated on a lifetime
# counter crossing a threshold (SkillLibrary's `unlock` block, e.g. DAMAGE_TAKEN >= 300),
# and those counters only ever grow, so a stage that went badly still moved something.
# Without this screen that progress is invisible until the player happens to open the hub's
# skills page and finds a gate has silently opened.
#
# ONE ROW PER SKILL, in `SkillLibrary.all()` order, showing the state that skill is
# actually in:
#   * LOCKED   — the counter's fraction, "150/800", against the stat's own name. This is
#                the row the screen exists for.
#   * UNLOCKED — the gate is met but the skill is unbought: says so, because the next
#                action is a purchase in the hub, not more driving.
#   * OWNED    — nothing left to progress.
#
# Read-only and NOT focusable: like the hub's lifetime-stats page, every row is a Label
# and the caller's own dismiss control is the one focusable thing on screen — which is
# what keeps the menu-navigation contract (CLAUDE.md) satisfiable by a plain modal.
#
# NOT A SCENE and not a page — returns a plain Control the caller mounts, same contract as
# CarStatsPanel, so the between-stage modal can stack the two without either knowing about
# the other.


# The read-out for `profile` (a `Save.profile` dict). Two columns, skill name then state,
# reading left-to-right then down — the same shape and reasoning as the hub's
# lifetime-stats page.
static func build(profile: Dictionary) -> Control:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", UITheme.GAP)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for skill in SkillLibrary.all():
		var id := String((skill as Dictionary).get("id", ""))
		if id.is_empty():
			continue
		grid.add_child(UITheme.label("%s:" % SkillLibrary.label_for(id), "dim"))
		grid.add_child(_state_label(id, profile))
	return grid


# The right-hand cell for one skill. Green once there is nothing left to drive for (the
# gate is met, whether or not the skill has been bought yet) so the eye finds the
# actionable rows without reading every line; plain while it is still counting up.
static func _state_label(id: String, profile: Dictionary) -> Label:
	if SkillLibrary.is_unlocked(id, profile):
		var bought: Array = profile.get(Save.KEY_BOUGHT_SKILLS, [])
		return UITheme.label("Owned" if bought.has(id) else "Unlocked — buy in the shop", "green")
	var unlock := SkillLibrary.unlock_of(id)
	var stat := String(unlock.get("stat", ""))
	if stat.is_empty():
		# A skill with no unlock block is not gated on anything countable. It should not
		# exist (test_skill_library pins every entry's unlock stat to a real
		# LifetimeStats id), but a row saying so beats a row saying "0/0".
		return UITheme.label("Locked")
	var threshold := int(unlock.get("threshold", 0))
	var current := int((profile.get(Save.KEY_LIFETIME, {}) as Dictionary).get(stat, 0))
	return UITheme.label("%s %s" % [
		LifetimeStats.label_for(stat), LifetimeStats.progress_text(current, threshold)])
