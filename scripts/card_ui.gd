class_name CardUI
extends RefCounted
# Docs: features/card-carousel.md — update in the same change as this file.
# Tests: tests/headless/test_card_carousel.gd — extend in the same change.
#
# Shared card-list building blocks: every menu in the game is a CardCarousel of text cards
# (features/card-carousel.md). `card_page` opens the page, `card_list` fills it from a list of
# entry dicts and wires each card's confirm to its action — the one shape every menu uses, so
# a new menu is a list of entries rather than a fresh layout.


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
	# an empty slot — but a MISSING SHIPPED icon stays loud, caught by test_card_carousel's
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
# one, so a card can be rewritten in place and keep its position/focus in the carousel.
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


# The carousel pages run edge to edge, unlike an ordinary MenuPage (whose body box
# deliberately hugs its content with a wide gap to the screen edge — menu_page.gd rule 1).
# A carousel's own clip_contents already keeps it from spilling past the screen, and a wide
# margin is exactly what would squeeze it down to only 2-3 cards' worth of screen space.
# 0.0 means the literal screen edge, a partial card clipped flush against it.
const CAROUSEL_PAGE_MARGIN := 0.0
const CAROUSEL_PAGE_PADDING := 0.0

# The tallest header a card page shows above its cards (the rest stop's name, "Car repaired"
# and the banked line). Every card page reserves this same height via header_slot() below,
# whether or not it has that much to say, so the cards land at the SAME screen position on
# every page. Bump this if a page needs a taller header.
const CAROUSEL_HEADER_LINES := 3

# A fixed-height slot for the plain info line(s) a carousel page puts above its
# cards (or nothing at all). MenuPage hugs and vertically CENTRES its whole panel, so a page whose
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
# spans the row of cards.
static func centered_label(text: String, role: String = "ink") -> Label:
	var l := UITheme.label(text, role)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


# A blank spacer the height of MenuPage's own title row (the title label at
# TITLE_FONT_SIZE, plus the GAP separation before the body — see menu_page.gd's
# `_inner`). card_list adds one on a page built with no title, so its cards land at the
# same height as every titled card page's.
static func title_gap_spacer() -> Control:
	var spacer := Control.new()
	var line_height := UITheme.font().get_height(UITheme.TITLE_FONT_SIZE)
	spacer.custom_minimum_size.y = line_height + UITheme.GAP
	return spacer

# Build a carousel and mount it as `page`'s whole selectable body (any plain,
# non-choosable labels the caller wants above it should be added BEFORE calling this).
# `page_margin`/`body_padding` must match whatever `page` was actually constructed with
# (MenuPage's own "margin"/"padding" opts) — they default to CAROUSEL_PAGE_MARGIN/
# CAROUSEL_PAGE_PADDING (0.0, true edge to edge), which is what card_page opens.
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
		# page rebuild hit "Signal already connected" from the second page opened onward),
		# while each lambda is its own distinct object.
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


# --- Card pages ----------------------------------------------------------------

# Open a card page on `host`: a MenuPage set up edge to edge with a see-through body box, so
# only the cards (and the title above them) sit over whatever is behind. `opts` passes through
# to MenuPage (e.g. "title", "dim"); the margin, padding and alpha are the card page's own.
# With "modal": true it is hosted through MenuPage.open_modal (its own CanvasLayer); otherwise
# it is added straight to `host`, for a host that is already a CanvasLayer.
static func card_page(host: Node, opts: Dictionary = {}) -> MenuPage:
	var o := opts.duplicate()
	o["margin"] = CAROUSEL_PAGE_MARGIN
	o["padding"] = CAROUSEL_PAGE_PADDING
	o["alpha"] = 0.0
	if bool(o.get("modal", false)):
		return MenuPage.open_modal(host, o)
	var page := MenuPage.new(o)
	host.add_child(page)
	return page


# Fill a card page with one card per entry and wire each card's confirm to its action. An entry:
#   "title"    (String)   the card's name
#   "subtitle" (String)   a dim second line (optional)
#   "extra"    (String)   a third line, e.g. a state (optional), coloured by "extra_variant"
#   "icon"     (String)   an icons/cards/ name (optional — generic.svg otherwise)
#   "disabled" (bool)     shown dimmed, never confirmable (optional)
#   "action"   (Callable) run when the card is confirmed (optional — a read-only card)
# `header` is the plain lines shown above the cards, in the fixed-height header slot.
# `selected` seats the cursor on that card (by index) without the snap animation.
static func card_list(page: MenuPage, entries: Array, header: Array = [], selected := 0) -> CardCarousel:
	if page.title_label() == null:
		page.body().add_child(title_gap_spacer())
	var slot := header_slot(page)
	for line in header:
		var l := centered_label(String(line))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		slot.add_child(l)
	var carousel := build_carousel(page)
	for e: Dictionary in entries:
		text_card(carousel, String(e.get("title", "")), String(e.get("subtitle", "")),
			bool(e.get("disabled", false)), String(e.get("icon", "generic")),
			String(e.get("extra", "")), String(e.get("extra_variant", "")))
	carousel.set_meta("entries", entries)
	carousel.confirmed.connect(func(i: int) -> void:
		var action: Variant = entries[i].get("action")
		if action is Callable and (action as Callable).is_valid():
			(action as Callable).call())
	if selected > 0 and selected < entries.size():
		carousel.select(selected, false)
	return carousel


# A car's card subtitle: its power and drive layout, e.g. "180 hp · RWD".
static func car_subtitle(entry: Dictionary) -> String:
	return "%d hp · %s" % [roundi(CarLibrary.horsepower(entry)), CarLibrary.drive_text(int(entry.get("drive_mode", -1)))]


# The titles of a card list's cards, in order — a readout for tests and hosts.
static func titles(carousel: CardCarousel) -> PackedStringArray:
	var out := PackedStringArray()
	for e: Dictionary in carousel.get_meta("entries", []):
		out.append(String(e.get("title", "")))
	return out


# The index of the card whose title starts with `title` (case-insensitive), or -1.
static func index_of(carousel: CardCarousel, title: String) -> int:
	var t := titles(carousel)
	for i in t.size():
		if t[i].to_lower().begins_with(title.to_lower()):
			return i
	return -1


# Select the card titled `title` and confirm it straight away (no flash) — what a player's
# pick does, for tests. Returns false when there is no such card or it is disabled.
static func pick(carousel: CardCarousel, title: String) -> bool:
	var i := index_of(carousel, title)
	if i < 0 or carousel.get_card(i).disabled:
		return false
	carousel.select(i, false)
	carousel._confirm_selected()
	carousel.skip_confirm_flash()
	return true
