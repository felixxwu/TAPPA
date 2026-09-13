class_name SkillProgressPanel
extends RefCounted
# Docs: features/skills.md, features/card-carousel.md — update in the same change as this file.
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
# ONE CARD PER SKILL THAT ACTUALLY MOVED THIS STAGE — build() takes the lifetime-stats
# snapshot from BEFORE the stage (world.gd captures it in _on_stage_started) and only emits
# a card when this stage's delta on that skill's gate stat is > 0; an OWNED skill has
# nothing left to progress so it never gets a card either. Each card shows the skill's
# current state (LOCKED progress fraction / "Unlocked — buy in the shop") plus "+<delta>"
# for what this stage specifically added.
#
# A REAL CARD CAROUSEL, NOT A VERTICAL LIST — this used to build its own VBoxContainer of
# green-bordered PanelContainers, which was rejected twice for not looking like the card
# lists everywhere else in the game. It is now the SAME widget the run-pick panel and the
# hub's car/upgrade pages use: CardUI.build_carousel + CardUI.text_card
# (features/card-carousel.md) — icon slot, drop shadow, dimmed-unless-selected, horizontal
# side-scroll. There is exactly one card shape in this project and this screen now uses it
# instead of a look-alike.
#
# FOCUSABLE NOW, deliberately — the old header said this screen was read-only and NOT
# focusable "so the caller's dismiss control is the one focusable thing on screen". That
# decision is REVERSED: a CardCarousel is one focusable unit by design (left/right move the
# selection, `menu_nav_handles_side`), and a card list the player cannot move through is
# exactly the not-a-real-card-list complaint. The menu-navigation contract (CLAUDE.md) is
# still satisfied — better than before, in fact: the caller attaches MenuNav with the
# carousel as `first`, up/down still leaves it for the Continue action, and the carousel's
# own `confirmed` is wired by the caller to the same "carry on" the button does, so confirm
# is never a dead input. Nothing on this screen chooses anything; the cards are a read-out
# you can scroll, and every path off it goes to the same place.
#
# NOT A SCENE and not a page — build() mounts into the caller's MenuPage (same modal the
# CarStatsPanel step uses) and hands back the carousel so the caller can wire nav/confirm.


# The page margin/padding world.gd's interstitial modal is opened with
# (_swap_interstitial -> MenuPage.open_modal({"margin": 24.0})). CardUI.build_carousel has
# to be told the same numbers or the carousel claims more width than the page actually
# leaves visible — see CardUI.build_carousel's own note. RunPickPanel passes the identical
# pair for the identical reason.
const PAGE_MARGIN := 24.0


# `profile` is `Save.profile` (or a test double of the same shape); `before_lifetime` is
# a snapshot of `profile[Save.KEY_LIFETIME]` taken before this stage ran, so the delta
# per skill's gate stat can be computed. A skill whose stat didn't move this stage (or
# that's already OWNED) gets no card at all; when NOTHING moved, a single "No skill
# progress this stage" card stands in, so the screen is never a blank strip.
#
# Returns the mounted CardCarousel: the caller passes it to MenuNav.attach as `first` and
# connects `confirmed` to whatever its own dismiss action does.
static func build(page: MenuPage, profile: Dictionary, before_lifetime: Dictionary) -> CardCarousel:
	var carousel := CardUI.build_carousel(page, PAGE_MARGIN, UITheme.PANEL_PAD)
	var shown := 0
	for skill in SkillLibrary.all():
		var id := String((skill as Dictionary).get("id", ""))
		if id.is_empty():
			continue
		if _add_card(carousel, id, profile, before_lifetime):
			shown += 1
	if shown == 0:
		# Not disabled: a carousel whose only card is disabled has nowhere for the cursor
		# to land, and there is nothing being refused here anyway — it is a read-out.
		CardUI.text_card(carousel, "No skill progress", "this stage", false, "generic")
	return carousel


# Append one card for `id`, or skip it when it belongs off this screen: OWNED (nothing left
# to progress) or its gate stat didn't move this stage (delta <= 0, including a skill that
# unlocked in an earlier stage and is just sitting there unbought). Returns whether a card
# was actually added.
static func _add_card(carousel: CardCarousel, id: String, profile: Dictionary,
		before_lifetime: Dictionary) -> bool:
	var bought: Array = profile.get(Save.KEY_BOUGHT_SKILLS, [])
	if bought.has(id):
		return false
	var unlock := SkillLibrary.unlock_of(id)
	var stat := String(unlock.get("stat", ""))
	if stat.is_empty():
		# A skill with no unlock block is not gated on anything countable and should not
		# exist (test_skill_library pins every entry's unlock stat to a real
		# LifetimeStats id) — nothing to show progress on either way.
		return false
	var current := int((profile.get(Save.KEY_LIFETIME, {}) as Dictionary).get(stat, 0))
	var before := int(before_lifetime.get(stat, 0))
	var delta := current - before
	if delta <= 0:
		return false
	# icons/cards/ is keyed by boost/skill id (the same lookup the hub's shop cards and
	# RunPickPanel use), so the skill id doubles as the icon name; an id with no authored
	# icon falls back to generic.svg inside CardUI.card_icon.
	CardUI.text_card(carousel, SkillLibrary.label_for(id), _state_text(id, profile), false,
		id, "+%d" % delta, "green")
	return true


# The card's state line, unchanged from the row version: green once there is nothing left
# to drive for (the gate is met, whether or not the skill has been bought yet), plain while
# it is still counting up. Returned as text rather than a Label now — CardUI owns building
# the card's labels so every card on every screen is laid out the same way.
static func _state_text(id: String, profile: Dictionary) -> String:
	if SkillLibrary.is_unlocked(id, profile):
		var bought: Array = profile.get(Save.KEY_BOUGHT_SKILLS, [])
		return "Owned" if bought.has(id) else "Unlocked — buy in the shop"
	var unlock := SkillLibrary.unlock_of(id)
	var stat := String(unlock.get("stat", ""))
	if stat.is_empty():
		return "Locked"
	var threshold := int(unlock.get("threshold", 0))
	var current := int((profile.get(Save.KEY_LIFETIME, {}) as Dictionary).get(stat, 0))
	return "%s %s" % [LifetimeStats.label_for(stat), LifetimeStats.progress_text(current, threshold)]
