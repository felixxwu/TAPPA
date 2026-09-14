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
	fill_card(card, title, subtitle, icon, extra, extra_variant)


# Same content as text_card, but written into an ALREADY-ADDED card rather than creating
# one — the seam run_pick_panel.gd uses to first add a card as a "?" placeholder and
# later overwrite it in place once the player reveals it (RunPickPanel.open_pick), so
# the card keeps its position/focus in the carousel across the reveal.
static func fill_card(card: CardCarousel.Card, title: String, subtitle: String,
		icon: String, extra := "", extra_variant := "") -> void:
	for child in card.visual.get_children():
		card.visual.remove_child(child)
		child.queue_free()
	for child in card.info.get_children():
		card.info.remove_child(child)
		child.queue_free()
	card.visual.add_child(card_icon(icon))
	var title_label := UITheme.card_title(title)
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
#
# 0.0, not some small-but-nonzero inset: "edge to edge" was asked to mean the literal
# screen edge, cards (and now a partial card — see card_carousel.gd) clipped flush against
# it, not a page still floating a few pixels in from the corner. the `RunPickPanel` step builders
# (run_pick_panel.gd) are the callers that do NOT want this — each page keeps a real
# 24px margin like an ordinary MenuPage — so it passes its own `page_margin`/`body_padding`
# through to build_carousel rather than taking these defaults.
const CAROUSEL_PAGE_MARGIN := 0.0
const CAROUSEL_PAGE_PADDING := 0.0

# The tallest header hub_shell's carousel pages ever show above the cards — CAR's
# "Money" + conditional "Rating cap" line, when a challenge pick is pending. Every
# carousel page in that family reserves this same height via header_slot() below,
# whether or not it actually has that much to say, so the carousel — and therefore
# the cards — land at the SAME screen position on every page. Bump this if a future
# page needs a taller header than CAR's two lines.
const CAROUSEL_HEADER_LINES := 2

# A fixed-height slot for the plain info line(s) a carousel page puts above its
# cards (a "Money: N" readout, CAR's extra "Rating cap: N" line, or nothing at
# all). MenuPage hugs and vertically CENTRES its whole panel, so a page whose
# header is one line one time and two lines (or zero) another time moves its own
# carousel up/down between visits — the reported bug this exists to fix. Reserving
# the SAME height regardless of content, with the content bottom-aligned against
# the carousel below, keeps the cards' vertical position fixed across every page in
# the family. Every caller must add its label(s) (if any) to the returned
# container INSTEAD OF page.body(), and must call this before build_carousel().
static func header_slot(page: MenuPage) -> VBoxContainer:
	var slot := VBoxContainer.new()
	slot.alignment = BoxContainer.ALIGNMENT_END
	slot.add_theme_constant_override("separation", 0)
	var line_height := UITheme.font().get_height(UITheme.FONT_SIZE)
	slot.custom_minimum_size.y = line_height * CAROUSEL_HEADER_LINES
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.body().add_child(slot)
	return slot


# A UITheme.label(), pre-centred and widened to fill its container — for a line added to
# header_slot()'s container: an ordinary UITheme.label() stays left-aligned and only as
# wide as its text, which reads off-centre against the carousel below it once the body box
# spans the row of cards (CAR/SHOP/SKILLS' "Money"/"Rating cap"/"Equipped" readouts).
static func centered_label(text: String, role: String = "ink") -> Label:
	var l := UITheme.label(text, role)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


# A blank spacer the height of MenuPage's own title row (the title label at
# TITLE_FONT_SIZE, plus the GAP separation before the body — see menu_page.gd's
# `_inner`). MAIN is the one carousel page hub_shell.gd builds with NO title (a
# deliberate "front door" decision — see hub_shell.gd::_title_for), so without this
# its body has that much less chrome above the carousel than every titled carousel
# page (REGION/CAR/SHOP/SKILLS/CARS/the FREEPLAY steps), and its cards land higher
# on screen than theirs. Add this to page.body() before header_slot() on any
# carousel page built with an empty title, to keep it in the same family.
static func title_gap_spacer() -> Control:
	var spacer := Control.new()
	var line_height := UITheme.font().get_height(UITheme.TITLE_FONT_SIZE)
	spacer.custom_minimum_size.y = line_height + UITheme.GAP
	return spacer

# Build a carousel and mount it as `page`'s whole selectable body (any plain,
# non-choosable labels the caller wants above it — e.g. a "Money: N" readout — should be
# added to page.body() BEFORE calling this). `page_margin`/`body_padding` must match
# whatever `page` was actually constructed with (MenuPage's own "margin"/"padding" opts) —
# they default to CAROUSEL_PAGE_MARGIN/CAROUSEL_PAGE_PADDING (0.0, true edge to edge),
# which is what every hub_shell.gd carousel page uses; a caller that opened its page with
# a real margin (any RunPickPanel step's 24px) must pass that same value here too, or the
# carousel claims more width than the page's own clip_contents actually leaves visible.
static func build_carousel(page: MenuPage, page_margin: float = CAROUSEL_PAGE_MARGIN,
		body_padding: float = CAROUSEL_PAGE_PADDING) -> CardCarousel:
	var carousel := CardCarousel.new()
	page.body().add_child(carousel)
	_refit_carousel(page, carousel, page_margin, body_padding)
	# The fit above only accounts for the window size AT THE MOMENT the page opened — a
	# player who resizes/maximizes the window (or rotates a device) while the page stays
	# open kept whichever width that was, reported as "the card list doesn't extend to the
	# edges of the screen, it clips at a certain width". Re-run the same fit on every later
	# resize so the carousel keeps tracking the window instead of freezing at its first size.
	var window := page.get_window()
	if window != null:
		# A LAMBDA, not `Callable(CardUI, "_refit_carousel").bind(page, carousel, ...)` —
		# bound Callables to the same static method compare equal for
		# `is_connected`/duplicate-connect checks regardless of their bound arguments (every
		# carousel page rebuild in hub_shell.gd's `_show` hit "Signal already connected"
		# from the SECOND page opened onward, since all of them bind the same underlying
		# method), while each lambda is its own distinct object.
		var refit := func() -> void: _refit_carousel(page, carousel, page_margin, body_padding)
		window.size_changed.connect(refit)
		# Windows outlive any one page, so the connection must be torn down with the
		# carousel it targets or it would silently pile up (and keep firing into a freed
		# `page`/`carousel` pair) every time a carousel page opens and closes.
		carousel.tree_exiting.connect(func() -> void:
			if window.size_changed.is_connected(refit):
				window.size_changed.disconnect(refit))
	return carousel


# Re-derive the carousel's width from the current window size and re-apply it — the body
# of build_carousel's own initial fit, factored out so the size_changed hookup above can
# reuse it verbatim.
static func _refit_carousel(page: MenuPage, carousel: CardCarousel,
		page_margin: float, body_padding: float) -> void:
	if not is_instance_valid(page) or not is_instance_valid(carousel):
		return
	# Claim the full logical frame width, minus the page's own margin/padding chrome —
	# fit_to_available_width claims that whole budget (a partial card can peek in at the
	# clipped edge; see card_carousel.gd), and set_body_width feeds the same width to the
	# (otherwise content-hugging) MenuPage box so it actually grows to it.
	var avail := WorldPanel.layout_frame_size(page, Vector2(480.0, 360.0)).x
	var chrome := page_margin * 2.0 + body_padding * 2.0
	carousel.fit_to_available_width(avail - chrome)
	page.set_body_width(carousel.custom_minimum_size.x)
