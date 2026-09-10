class_name CardUI
extends RefCounted
# Docs: features/card-carousel.md — update in the same change as this file.
# Tests: tests/headless/test_run_pick_panel.gd, tests/headless/test_hub_shell.gd — extend in the same change.
#
# Shared card-carousel building blocks, pulled out of hub_shell.gd so a second screen
# (run_pick_panel.gd) can use the exact same card shape without duplicating it inline.
#
# TEMPORARY DUPLICATION, DELIBERATE: hub_shell.gd still carries its own private copies of
# _card_icon / _text_card / _build_carousel (it belongs to a sibling agent mid-edit at the
# time this file was written) — those will be consolidated onto CardUI afterwards. Until
# then, treat this file as the canonical version and hub_shell.gd's copies as the ones
# that will eventually be deleted in favour of it.


# A card's visual-slot icon — one white-outline SVG from icons/cards/, named by what the
# card IS (a boost/skill id, "car", "region", …). The whole set shares one style: white
# only, uniform 6px stroke, round caps/joins — so the carousels read as one system rather
# than a mix of clip-art.
# How far the icon's rect is inset from the visual slot's edges, as a fraction of the slot
# per side — the icon used to fill the whole top half of the card, which read as a
# full-bleed illustration rather than an icon; a ~55%-width mark leaves the card room to
# breathe around it. A look constant, not a tunable (no designer retune expected).
const CARD_ICON_INSET := 0.22

static func card_icon(icon: String) -> Control:
	var path := "res://icons/cards/%s.svg" % icon
	# A fallback for ids with no authored icon (a test fixture's fx_* id, say) rather than
	# an empty slot — but a MISSING SHIPPED icon stays loud, caught by test_hub_shell's
	# every-catalogue-icon-exists guard instead of degrading here.
	if not ResourceLoader.exists(path):
		path = "res://icons/cards/generic.svg"
	var tex := TextureRect.new()
	tex.texture = load(path)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.anchor_left = CARD_ICON_INSET
	tex.anchor_right = 1.0 - CARD_ICON_INSET
	tex.anchor_top = CARD_ICON_INSET * 0.8
	tex.anchor_bottom = 1.0 - CARD_ICON_INSET * 0.8
	tex.offset_left = 0.0
	tex.offset_right = 0.0
	tex.offset_top = 0.0
	tex.offset_bottom = 0.0
	return tex


# Append a text-card (icon + centred title/subtitle, and an optional third state/price
# line) to `carousel` — the ONE card shape across every page, so the carousels read as a
# system. Mirrors the old row-button's disabled-and-unfocusable convention: a disabled
# card stays on screen (shown, dimmed) but neither lands the cursor's confirm nor fires
# `on_confirm` (CardCarousel.confirmed simply never emits for a disabled index).
static func text_card(carousel: CardCarousel, title: String, subtitle: String,
		disabled: bool, icon: String, extra := "", extra_variant := "") -> void:
	var card := carousel.add_card(disabled)
	card.visual.add_child(card_icon(icon))
	var title_label := UITheme.label(title)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.info.add_child(title_label)
	if subtitle != "":
		var sub := UITheme.label(subtitle, "dim")
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.info.add_child(sub)
	if extra != "":
		var line := UITheme.label(extra, extra_variant)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.info.add_child(line)


# The carousel pages want to run edge to edge, unlike an ordinary MenuPage (whose body box
# deliberately hugs its content with a wide gap to the screen edge — menu_page.gd rule 1).
# A carousel's own clip_contents already keeps it from spilling past the screen, so it
# doesn't need that margin doing the same job twice, and a wide margin is exactly what
# would squeeze it down to only 2-3 cards' worth of screen space.
const CAROUSEL_PAGE_MARGIN := 8.0

# Build a carousel and mount it as `page`'s whole selectable body (any plain,
# non-choosable labels the caller wants above it — e.g. a "Money: N" readout — should be
# added to page.body() BEFORE calling this).
static func build_carousel(page: MenuPage) -> CardCarousel:
	var carousel := CardCarousel.new()
	page.body().add_child(carousel)
	# Claim the full logical frame width, minus the page's own margin/padding chrome —
	# `fit_to_available_width` then rounds DOWN to a whole number of cards so a card is
	# never chopped in half at the visible edge, and set_body_width feeds that width to
	# the (otherwise content-hugging) MenuPage box so it actually grows to it.
	var avail := WorldPanel.layout_frame_size(page, Vector2(480.0, 360.0)).x
	var chrome := CAROUSEL_PAGE_MARGIN * 2.0 + UITheme.PANEL_PAD * 2.0
	carousel.fit_to_available_width(avail - chrome)
	page.set_body_width(carousel.custom_minimum_size.x)
	return carousel
