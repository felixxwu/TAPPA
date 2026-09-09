class_name HubShell
extends Control
# Docs: features/hub-shell.md, features/skills.md, features/lifetime-stats.md — update in the same change as this file.
# Tests: tests/headless/test_hub_shell.gd — extend in the same change. Before you change
# behaviour here, `grep -rn 'HubShell' tests/headless/` and read what is pinned.
#
# THE FLAT SHELL: the game's main scene, and the only way into a run.
#
# It replaces the diegetic 3D hub (`hq.tscn`, 3527 lines) and the overworld, both deleted
# in stage 2b of todo/roguelike-pivot-plan.md. Decision 9 chose a flat 2D UI outright, so
# there is no 3D station, no camera pose, no spatial navigation — every screen here is a
# flat MenuPage and every one of them is keyboard + gamepad navigable through
# MenuNav.attach, which CLAUDE.md requires of every menu in the game.
#
# DELIBERATELY PLAIN. Stage 3's bar is "the loop runs start to finish", not "the loop looks
# good": this is four stacked pages of buttons. Stages 4-8 replace the region and car pages
# with real screens (a shop, boost levels, skills, lifetime stats) and this file is expected
# to be rewritten around them. Do not invest in its looks now, and do not grow it into the
# place those features live — give each its own script when it lands.
#
# WHY ONE SCRIPT AND ONE SCENE: the pages share nothing but a host and a back stack, and
# the whole shell is smaller than any one of the nine hub collaborators it replaces.
# Splitting it now would be four files that each do one `for` loop.

# The pages, as a plain stack. `_page` is the live MenuPage; `_view` says which screen it
# is showing, so `_back()` knows where to go and the tests can assert a screen without
# reading button text.
#
# SHOP is stage 6's meta shop (todo/roguelike-pivot.md "Upgrades — RR's two-tier
# model" + "Car acquisition — RR's shop"): every boost ladder and the Engine Swap
# unlock in one flat list, reached from MAIN rather than from the run's own car-select
# flow, since they are permanent purchases available any time, not something tied to
# picking a car for THIS run. Car BUYING, per decision 28's wording ("the car select
# screen offers a Buy action for unowned cars"), is folded into the existing CAR page
# instead of living here — see _build_car().
#
# CHALLENGE is stage 9's MINIMAL entry point for the Daily/Weekly/Monthly challenge
# (decision 15 keeps the mode; RunSession has always been able to drive it through
# ChallengeRunMode). It is deliberately the SMALLEST screen that makes the mode
# reachable: pick a period, pick an eligible car, go. There is no cloud board, no
# placement table and no ceiling explainer here — those were `hq_challenge.gd`'s and are
# not rebuilt; see features/rally-challenge.md for what a full screen would owe.
#
# SKILLS / STATS are stage 7 (todo/roguelike-pivot.md "Skills — a straight lift from RR" +
# "Lifetime global stats"), both reached from MAIN like SHOP: permanent, run-independent
# pages. STATS is pure read-out (LifetimeStats.IDS, one row each) — CLAUDE.md's menu-nav
# trap for a page like this is that a wall of Labels leaves nothing focusable at all, so
# its Back action is the page's ONE focusable control; see _build_stats().
enum View { MAIN, REGION, CAR, SUMMARY, SHOP, SKILLS, STATS, CHALLENGE, SETTINGS }

# RunSession is an autoload with no class_name, so its STATIC members must be reached
# through the script resource — calling a static via the autoload instance is a
# STATIC_CALLED_ON_INSTANCE warning, which test_smoke.gd treats as a failure.
const RunSessionScript = preload("res://scripts/run_session.gd")

var _view: int = View.MAIN
var _page: MenuPage = null
# The region the player picked on the REGION page, held while they pick a car on the next.
var _pending_region := ""
# The challenge KIND picked on the CHALLENGE page, held over the same car pick. Non-empty
# is what makes the CAR page a challenge car pick rather than a region one — the two flows
# share that page, since "which of my cars" is the identical question. Cleared on every
# entry to REGION so a back-and-forth cannot start a region run as a challenge.
var _pending_challenge := ""
# The shared SettingsMenu instance while the SETTINGS page is live — null otherwise. Held so
# _back()/the page's own Back button can give it first refusal (its own sub-pages back out
# to its category list before this shell backs out to MAIN), mirroring pause_menu.gd's
# AccountMenu/SettingsMenu "first refusal" pattern (see features/menus.md → Account page).
var _settings_menu: SettingsMenu = null

# The live 3D background behind every page (todo/menu-background-showcase.md,
# phase-1 prototype) — a Node3D can sit anywhere under this Control; 3D always
# composites BEHIND this Control's CanvasItems in the same Viewport, so nothing
# about the pages above needs to know it's there. Skipped under headless: it costs
# a real (if small) track generation, which every hub test would otherwise pay for
# no visual benefit — see test_menu_showcase.gd for the dedicated coverage of the
# scene itself.
var _showcase: Node3D = null

# True whenever there is a screen to paint on (false under headless, where there is
# nothing to show and tests must not pay a per-frame warming wait). While true, _ready()
# holds a LoadingScreen over the pages until CarPreviewCache has EVERY car cached — see
# the call site. Tests set it true explicitly to cover that path headlessly.
var _warm_behind_loading_screen := not Platform.is_headless()


func _ready() -> void:
	if not Platform.is_headless():
		_showcase = load("res://menu_showcase.tscn").instantiate()
		add_child(_showcase)
	# A run that ended hands control back here (world.gd -> Scenes.hub_path()). Show its
	# summary rather than the main menu, or the player is dropped at a title screen with no
	# idea whether they cleared the region — the run's outcome is the whole point of it.
	if not RunSession.last_result().is_empty():
		_show(View.SUMMARY)
	else:
		_show(View.MAIN)
	# Warms CarPreviewCache so that by the time a player reaches the CAR page, every car's
	# preview is already built and the selection can move between them with no per-car lag
	# at all. Idempotent: cheap to call on every hub visit, since a car already cached is
	# skipped.
	#
	# INTERACTIVE loads hold the hub's loading stage up until warming has genuinely
	# finished: MenuShowcase._build() already shows its own LoadingScreen for the
	# background-track half of hub startup, and this one covers the CAR half — the pages
	# exist beneath it the whole time, but nothing is clickable through the black overlay,
	# so the per-car CarProp.spawn cost lands where the player reads it as loading instead
	# of as a stuttering menu. The old fire-and-forget trickle ran those same synchronous
	# build chunks INSIDE interactive frames — the hub hitched for its first seconds, and a
	# player who reached the CAR page before the trickle got there paid synchronous builds
	# on page open. Headless keeps the trickle (there is no screen to hold, and tests must
	# not block on warming).
	if _warm_behind_loading_screen:
		var loading := LoadingScreen.new()
		add_child(loading)
		loading.set_title("Loading…")
		await CarPreviewCache.warm_all()
		if is_instance_valid(loading):
			loading.finish()
	else:
		CarPreviewCache.warm_all()


# The heading each view carries. The SUMMARY heading is the one that says something the
# player cannot get anywhere else on that page: whether the run ended by clearing the
# region or by missing a target. MAIN deliberately gets NO heading (the "" default) —
# it is the game's front door and the only page a player can't mistake for another, so
# a "TAPPA" title there said nothing the page's own content didn't.
func _title_for(view: int) -> String:
	match view:
		View.REGION: return "Pick a region"
		View.CAR: return "Pick a car"
		View.SUMMARY:
			var completed := bool(RunSession.last_result().get("completed", false))
			return "Region cleared" if completed else "Run over"
		View.SHOP: return "Shop"
		View.SKILLS: return "Skills"
		View.STATS: return "Lifetime stats"
		View.CHALLENGE: return "Rally challenge"
		View.SETTINGS: return "Settings"
		_: return ""


# --- Page plumbing -----------------------------------------------------------

# A CarCardPreview actively shown on a card (i.e. never parked, because its card was
# still in the carousel's visible window) is about to be freed as a normal side effect of
# freeing whatever page hosts it — but CarPreviewCache still references it by car ref, and
# the NEXT request for that car would hand back a dangling node. Rescuing it into the
# cache's own (page-, and HubShell-, independent) graveyard first is what avoids that;
# called from BOTH _show (an ordinary page change) and _exit_tree (HubShell itself being
# torn down — a run starting, or just this test's own teardown — which frees the CURRENT
# page WITHOUT ever going through _show). Harmless no-op on every non-CAR page
# (find_children just finds nothing).
func _park_live_car_previews() -> void:
	if not is_instance_valid(_page):
		return
	for preview in _page.find_children("*", "CarCardPreview", true, false):
		CarPreviewCache.park(preview as CarCardPreview)


func _exit_tree() -> void:
	_park_live_car_previews()


# Tear the current page down and build the next. Every screen goes through here, so there
# is exactly one place that can leave a stale page parked under the tree.
func _show(view: int) -> void:
	_view = view
	_settings_menu = null
	if is_instance_valid(_page):
		_park_live_car_previews()
		var layer := _page.get_parent()
		if is_instance_valid(layer):
			layer.queue_free()
		_page = null
	# The heading is a CONSTRUCTION option, not a settable property: MenuPage builds no
	# label at all when "title" is absent, and title_label() is then null.
	# Carousel pages get a fully TRANSPARENT body box (alpha 0), not just a narrower margin
	# (_page_margin_for) — the box's own opaque black background was painting over the 3D
	# menu_showcase behind it everywhere the gap between cards should have shown it through.
	# Cards stay opaque regardless (their own stylebox — card_carousel.gd's _card_stylebox
	# — is independent of the page they sit on), so only the empty space around them opens up.
	var page_opts := {"margin": _page_margin_for(view), "title": _title_for(view)}
	if _is_carousel_view(view):
		page_opts["alpha"] = 0.0
	_page = MenuPage.open_modal(self, page_opts)
	match view:
		View.MAIN: _build_main()
		View.REGION: _build_region()
		View.CAR: _build_car()
		View.SUMMARY: _build_summary()
		View.SHOP: _build_shop()
		View.SKILLS: _build_skills()
		View.STATS: _build_stats()
		View.CHALLENGE: _build_challenge()
		View.SETTINGS: _build_settings()
	# `remember: false` — each page is rebuilt from scratch, so there is no earlier focus
	# on it worth restoring; the first action is always the right landing spot.
	MenuNav.attach(_page, {"on_back": _back})


# Esc / gamepad B. MAIN and SUMMARY are roots — backing out of them does nothing rather
# than dropping the player into a page they never opened.
func _back() -> void:
	match _view:
		View.REGION: _show(View.MAIN)
		# The CAR page serves BOTH flows, so Esc must return to whichever one opened it —
		# the page's own Back button already does. A back that always went to region
		# select would drop a challenge picker into a flow they never opened.
		View.CAR: _show(View.CHALLENGE if _pending_challenge != "" else View.REGION)
		View.SHOP: _show(View.MAIN)
		View.SKILLS: _show(View.MAIN)
		View.STATS: _show(View.MAIN)
		View.CHALLENGE: _show(View.MAIN)
		# Give the shared SettingsMenu first refusal: its own sub-pages (Audio, Account's
		# sign-in form, …) back out to its category list before this shell backs out to MAIN.
		View.SETTINGS: _settings_back()
		_: pass


func _action(text: String, on_press: Callable) -> Button:
	var b := UITheme.button(text)
	b.pressed.connect(on_press)
	return _page.add_action(b)


# A body row that reads as a list entry. Buttons rather than labels because every row here
# is chooseable, and MenuNav only walks focusable controls — a label row would be invisible
# to the keyboard and break the navigation contract.
func _row(text: String, on_press: Callable) -> Button:
	var b := UITheme.button(text)
	b.pressed.connect(on_press)
	_page.body().add_child(b)
	return b


# --- Card carousel plumbing ---------------------------------------------------
#
# Five screens (MAIN, REGION, CAR, SHOP, SKILLS) present their choices
# as a CardCarousel (features/card-carousel.md) instead of a vertical row list: one
# carousel per page, added to the body ahead of any plain labels/rows that page
# still wants (e.g. the "Money: N" readout). CHALLENGE / STATS keep the plain row
# list — they were not in the set this conversion asked for, and STATS in
# particular has nothing choosable to put on a card.

# A card's visual-slot icon — one white-outline SVG from icons/cards/, named by what
# the card IS (a boost/skill id, "car", "region", …). The whole set shares one style:
# white only, uniform 6px stroke, round caps/joins — so the carousels read as one
# system rather than a mix of clip-art. CAR cards swap this out for a real
# CarCardPreview once it is built (see _sync_car_previews).
func _card_icon(icon: String) -> Control:
	var path := "res://icons/cards/%s.svg" % icon
	# A fallback for ids with no authored icon (a test fixture's fx_* id, say) rather
	# than an empty slot — but a MISSING SHIPPED icon stays loud, caught by
	# test_hub_shell's every-catalogue-icon-exists guard instead of degrading here.
	if not ResourceLoader.exists(path):
		path = "res://icons/cards/generic.svg"
	var tex := TextureRect.new()
	tex.texture = load(path)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	return tex


# The five carousel pages want to run edge to edge, unlike every other MenuPage (whose
# body box deliberately hugs its content with a wide gap to the screen edge — menu_page.gd
# rule 1). A carousel's own clip_contents already keeps it from spilling into the 3D scene,
# so it doesn't need that margin doing the same job twice, and a wide margin is exactly what
# was squeezing it down to only 2-3 cards' worth of screen space.
const _CAROUSEL_PAGE_MARGIN := 8.0
const _DEFAULT_PAGE_MARGIN := 24.0

func _page_margin_for(view: int) -> float:
	return _CAROUSEL_PAGE_MARGIN if _is_carousel_view(view) else _DEFAULT_PAGE_MARGIN


func _is_carousel_view(view: int) -> bool:
	return view in [View.MAIN, View.REGION, View.CAR, View.SHOP, View.SKILLS]


# Build a carousel and mount it as the page's whole selectable body (any plain,
# non-choosable labels the caller wants above it — e.g. "Money: N" — should be
# added to _page.body() BEFORE calling this).
func _build_carousel() -> CardCarousel:
	var carousel := CardCarousel.new()
	_page.body().add_child(carousel)
	# Claim the full logical frame width, minus the page's own margin/padding chrome —
	# `fit_to_available_width` then rounds DOWN to a whole number of cards so a card is
	# never chopped in half at the visible edge, and set_body_width feeds that width to
	# the (otherwise content-hugging) MenuPage box so it actually grows to it.
	var avail := WorldPanel.layout_frame_size(_page, Vector2(480.0, 360.0)).x
	var chrome := _CAROUSEL_PAGE_MARGIN * 2.0 + UITheme.PANEL_PAD * 2.0
	carousel.fit_to_available_width(avail - chrome)
	_page.set_body_width(carousel.custom_minimum_size.x)
	return carousel


# Append a text-card (icon placeholder + title/subtitle) to `carousel`. Mirrors the
# old _row()'s disabled-and-unfocusable convention: a disabled card stays on screen
# (shown, dimmed) but neither lands the cursor's confirm nor fires `on_confirm`
# (CardCarousel.confirmed simply never emits for a disabled index).
func _text_card(carousel: CardCarousel, title: String, subtitle: String,
		disabled: bool, icon: String) -> void:
	var card := carousel.add_card(disabled)
	card.visual.add_child(_card_icon(icon))
	var title_label := UITheme.label(title)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.info.add_child(title_label)
	if subtitle != "":
		var sub := UITheme.label(subtitle, "dim")
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.info.add_child(sub)


# --- MAIN --------------------------------------------------------------------

func _build_main() -> void:
	var money := UITheme.label("Money: %d" % Save.money())
	_page.body().add_child(money)

	var carousel := _build_carousel()
	var actions: Array[Callable] = []

	# A paused run is offered FIRST, because the alternative — starting anything else —
	# discards it and burns its attempt (decision 48). Putting Resume anywhere but the top
	# is how a player loses a run they meant to finish.
	var resumable: Dictionary = RunSessionScript.resumable_run(
		Save.profile, int(Time.get_unix_time_from_system()))
	if not resumable.is_empty():
		_text_card(carousel, "Resume run", "", false, "resume_run")
		actions.append(_resume_run)

	_text_card(carousel, "New run", "", false, "new_run")
	actions.append(func() -> void: _show(View.REGION))
	_text_card(carousel, "Shop", "", false, "shop")
	actions.append(func() -> void: _show(View.SHOP))
	_text_card(carousel, "Skills", "", false, "skills")
	actions.append(func() -> void: _show(View.SKILLS))
	# Rally challenge sits AFTER Shop/Skills: it is a secondary way to start a run, so
	# it follows the primary one (New run) and its menu-alternatives, rather than
	# splitting them.
	_text_card(carousel, "Rally challenge", "", false, "rally_challenge")
	actions.append(func() -> void: _show(View.CHALLENGE))
	_text_card(carousel, "Lifetime stats", "", false, "stats")
	actions.append(func() -> void: _show(View.STATS))
	_text_card(carousel, "Settings", "", false, "settings")
	actions.append(func() -> void: _show(View.SETTINGS))
	carousel.confirmed.connect(func(i: int) -> void: actions[i].call())

	_action("Quit", func() -> void: get_tree().quit())


func _resume_run() -> void:
	if RunSession.resume(int(Time.get_unix_time_from_system())):
		Scenes.change_to(get_tree(), Scenes.MAIN)


# --- REGION ------------------------------------------------------------------

# Regions in AUTHORED order (RegionLibrary.ordered), not table order — the table's own
# header says array position is meaningless, and the player meets these in progression
# order or the list is nonsense.
#
# A locked region is SHOWN, named, and says what opens it. Hiding it would leave a new
# player with one row and no idea the game continues; showing it unpressable with no
# explanation is worse. Its button is disabled, so MenuNav skips it and the keyboard
# cannot land on a dead row.
func _build_region() -> void:
	_pending_challenge = ""
	var carousel := _build_carousel()
	var ids: Array[String] = []
	var cleared: Array = Save.profile.get(Save.KEY_REGIONS_CLEARED, [])
	for region in RegionLibrary.ordered():
		var id := String(region.get("id", ""))
		if id == "":
			continue
		var region_name := String(region.get("name", id))
		var reward := RegionRunMode.base_stage_reward(id)
		if not RegionLibrary.is_unlocked(id, Save.profile):
			# Just "Locked" + the pay rate — NOT the gate ("clear <region>") it hides
			# behind: the locked card is one glance wide, and the gate region's own card
			# sitting a swipe away already answers "what unlocks this" better than a
			# second-hand name on a locked card does.
			_text_card(carousel, region_name, "Locked — pays $%d/stage" % reward,
				true, "region_locked")
			ids.append("")
			continue
		var mark := "$%d/stage" % reward
		if cleared.has(id):
			mark += " — Cleared"
		_text_card(carousel, region_name, mark, false, "region")
		ids.append(id)
	carousel.confirmed.connect(func(i: int) -> void:
		if ids[i] != "":
			_pending_region = ids[i]
			_show(View.CAR))
	_action("Back", func() -> void: _show(View.MAIN))


# --- CAR ---------------------------------------------------------------------

# Owned cars are selectable to start the run; unowned cars offer a Buy action, per
# decision 28's own wording ("the car select screen offers a Buy action for unowned
# cars") — one combined screen rather than a separate shop page for cars, so buying and
# picking share the exact same list a player is already looking at. This is also what
# retires the old dead end: a fresh profile owns nothing, but decision 28 seeds it with
# money (GameConfig.run_starting_money), so the same page that used to say "no cars yet"
# now lists something it can actually afford.
func _build_car() -> void:
	_page.body().add_child(UITheme.label("Money: %d" % Save.money()))
	# A CHALLENGE pick judges every owned car against the period's rating ceiling
	# (ChallengeRunMode.classify_cars — the ONE implementation of that rule; this page
	# does not re-derive it). An over-ceiling car is SHOWN and unfocusable rather than
	# hidden, for the same reason a locked region is: a player whose only car is too fast
	# needs to see why the list is empty. A region pick has no such gate and lists them all.
	var eligible_ids := {}
	if _pending_challenge != "":
		var now := int(Time.get_unix_time_from_system())
		var classified := ChallengeRunMode.classify_cars(_pending_challenge, Save.profile, now)
		for car in (classified["eligible"] as Array):
			eligible_ids[int((car as Dictionary).get("instance_id", -1))] = true
		_page.body().add_child(UITheme.label(
			"Rating cap: %d" % int(classified["ceiling"])))

	var carousel := _build_carousel()
	# Parallel to the carousel's cards: either an owned-car Dictionary to start a run
	# with, or a model id String to buy — whichever `confirmed` should act on.
	var actions: Array = []
	# Parallel to the carousel's cards too: the CarProp.spawn ref (an owned-car Dictionary
	# or a catalogue index — see CarCardPreview._ready) each card's preview would show, so
	# _refresh_car_previews can build one lazily. null for a card that doesn't get a live
	# preview at all (there isn't one — every car card wants one — but keeping this as an
	# Array of Variant rather than a typed Array[Dictionary] keeps the int/Dictionary mix
	# CarCardPreview already accepts).
	var car_refs: Array = []

	var owned: Array = Save.profile.get(Save.KEY_CARS, [])
	for car in owned:
		var entry: Dictionary = car
		var iid := int(entry.get("instance_id", -1))
		if iid < 0:
			continue
		var spec: Dictionary = CarLibrary.for_owned(entry)
		var label := String(spec.get("name", entry.get("model_id", "car")))
		var over_cap := _pending_challenge != "" and not eligible_ids.has(iid)
		var card := carousel.add_card(over_cap)
		card.visual.add_child(_card_icon("car"))
		card.info.add_child(UITheme.label(label))
		if over_cap:
			card.info.add_child(UITheme.label("Over the rating cap", "dim"))
			actions.append(null)
		else:
			actions.append(entry)
		car_refs.append(entry)

	var catalogue := CarLibrary.all()
	for index in catalogue.size():
		var spec: Dictionary = catalogue[index]
		var model_id := String(spec.get("id", ""))
		if model_id.is_empty() or Save.owns_model(model_id):
			continue
		var cost := int(spec.get("cost", 0))
		var car_name := String(spec.get("name", model_id))
		var cant_afford := Save.money() < cost
		var card := carousel.add_card(cant_afford)
		card.visual.add_child(_card_icon("car"))
		card.info.add_child(UITheme.label(car_name))
		card.info.add_child(UITheme.label("Buy — %d" % cost, "gold"))
		# Appended in a branch rather than a ternary: a null/String ternary is an
		# INCOMPATIBLE_TERNARY warning, which the strict-error tests treat as a failure.
		# The list is deliberately mixed (Dictionary = start the run, String = buy, null =
		# can't afford it right now) — confirmed's handler below dispatches on exactly that.
		var action = null
		if not cant_afford:
			action = model_id
		actions.append(action)
		car_refs.append(index)

	# A live CarCardPreview is a real SubViewport + a full car.tscn instantiation (every
	# embedded car glb body, before pruning) — genuinely expensive PER CAR, not just per
	# viewport. Every car card gets the cheap letter-icon placeholder up front, and
	# _sync_car_previews asks the CarPreviewCache autoload (car_preview_cache.gd) for a
	# preview per car in the visible window rather than building one itself — the cache is
	# warmed in the background from HubShell._ready(), so by the time a player reaches
	# this page every car is normally already built, and even a cache miss only costs one
	# car's spawn, never a whole burst.
	_sync_car_previews(carousel, car_refs)
	carousel.selection_changed.connect(func(_i): _sync_car_previews(carousel, car_refs))

	carousel.confirmed.connect(func(i: int) -> void:
		var action = actions[i]
		if action is Dictionary:
			_start_run(action)
		elif action is String:
			_buy_car(action))

	_action("Back", func() -> void:
		_show(View.CHALLENGE if _pending_challenge != "" else View.REGION))


# Keep a live CarCardPreview on every card the carousel can ACTUALLY show at once
# (CardCarousel.visible_card_count(), centred on the current selection). Previews come
# from CarPreviewCache (car_preview_cache.gd), a SESSION-lifetime autoload cache keyed by
# car ref — not something this page owns itself, since HubShell is rebuilt from scratch
# on every hub visit and a page-scoped cache would forget every car each time. A card
# that stays in the visible window across a selection move is left untouched entirely.
func _sync_car_previews(carousel: CardCarousel, car_refs: Array) -> void:
	@warning_ignore("integer_division")  # floor division is intentional: the visible window's radius in whole card units
	var radius := carousel.visible_card_count() / 2
	var selected := carousel.selected_index()
	var wanted := {}
	for i in range(maxi(0, selected - radius), mini(car_refs.size(), selected + radius + 1)):
		wanted[i] = true

	# Park every card that fell OUT of the window's preview back in the cache's own
	# graveyard — NOT freed, so revisiting this car later (a swipe back, say) is a plain
	# reparent rather than a fresh CarProp.spawn.
	for i in car_refs.size():
		if wanted.has(i):
			continue
		var card := carousel.get_card(i)
		if card.visual.get_child_count() > 0 and card.visual.get_child(0) is CarCardPreview:
			var preview: CarCardPreview = card.visual.get_child(0)
			card.visual.remove_child(preview)
			CarPreviewCache.park(preview)
			card.visual.add_child(_card_icon("car"))

	# Give every card that entered the window its car's preview — cached already (a car
	# seen earlier this visit, or warmed in the background) or built fresh otherwise. A
	# card that STAYED in the window across this call already shows the right thing and
	# is left untouched.
	for i in wanted:
		var card := carousel.get_card(i)
		if card.visual.get_child_count() > 0 and card.visual.get_child(0) is CarCardPreview:
			continue
		for child in card.visual.get_children():
			card.visual.remove_child(child)
			child.queue_free()
		card.visual.add_child(CarPreviewCache.get_or_build(car_refs[i]))


# The letter a placeholder card icon shows for a car ref (see _sync_car_previews) — an
# owned-car Dictionary or a CarLibrary catalogue index, the same two shapes
# CarCardPreview._ready already accepts.
func _car_ref_name(car_ref) -> String:
	if car_ref is Dictionary:
		return String(CarLibrary.for_owned(car_ref).get("name", "car"))
	return String(CarLibrary.all()[int(car_ref)].get("name", "car"))


func _buy_car(model_id: String) -> void:
	if Save.buy_car(model_id):
		# Rebuild in place: the bought car now belongs in the owned list above and must
		# drop out of the buy list below it.
		_show(View.CAR)


# Start the region run — but a PAUSED run of either kind is a single slot (decision 27),
# so starting this one throws that one away and burns its attempt (decision 48). The
# confirm has to say so in those words: the rule is defensible, discovering it after the
# fact is not.
func _start_run(owned_car: Dictionary) -> void:
	var now := int(Time.get_unix_time_from_system())
	if RunSessionScript.resumable_run(Save.profile, now).is_empty():
		_begin_run(owned_car)
		return
	ConfirmPopup.open(self, "Abandon your paused run?",
		"You have a run paused. Starting a new one throws it away, and the attempt is "
		+ "used — you cannot go back to it.",
		[{"label": "Keep it", "callback": func() -> void: pass},
		 {"label": "Abandon it", "callback": func() -> void:
			RunSession.discard_run(now)
			_begin_run(owned_car)}])


# The one place the two flows diverge. RunSession.start refuses a challenge whose period
# is already finished (one attempt per period) and start_region refuses nothing, so a
# refusal here simply leaves the player on the page rather than changing scene — which is
# why the CHALLENGE page marks a finished period rather than relying on this.
func _begin_run(owned_car: Dictionary) -> void:
	var started := false
	if _pending_challenge != "":
		started = RunSession.start(_pending_challenge, owned_car,
			int(Time.get_unix_time_from_system()))
	else:
		started = RunSession.start_region(_pending_region, owned_car)
	if started:
		Scenes.change_to(get_tree(), Scenes.MAIN)


# --- CHALLENGE ---------------------------------------------------------------

# The three periods, one row each, in ascending length. THE MINIMUM that makes decision
# 15's retained mode reachable: it names the period, its stage count and its rating cap,
# and hands off to the shared CAR page. It does NOT show the cloud leaderboard, the
# player's standing, or the placement reward rule — `hq_challenge.gd` did, and it is
# deleted; features/rally-challenge.md carries what a full screen would owe.
#
# A period ALREADY FINISHED (completed or DNF'd) is shown, named and unfocusable rather
# than hidden or silently dead: it is one attempt per period (RunSession.start refuses a
# second), so a row that looked live and did nothing would read as a bug.
const CHALLENGE_KINDS: Array[String] = [
	ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY,
]


func _build_challenge() -> void:
	var now := int(Time.get_unix_time_from_system())
	for kind in CHALLENGE_KINDS:
		var period := ChallengeLibrary.current_period(kind, now)
		if period.is_empty():
			continue  # an unknown kind names no period — skip rather than show a dead row
		var label := "%s — %d stage(s), rating cap %d" % [
			kind.capitalize(), int(period.get("stage_count", 0)),
			ChallengeRunMode.displayed_ceiling(kind, now)]
		if ChallengeRunMode.is_period_finished(kind, Save.profile, now):
			var done_row := _row(label + " — already run", func() -> void: pass)
			done_row.disabled = true
			done_row.set_meta("menu_nav_skip", true)
			done_row.focus_mode = Control.FOCUS_NONE
			continue
		var kind_id := kind
		_row(label, func() -> void:
			_pending_challenge = kind_id
			_show(View.CAR))
	_action("Back", func() -> void: _show(View.MAIN))


# --- SUMMARY -----------------------------------------------------------------

# One screen for BOTH outcomes — cleared the region, or stopped by the clock. A run that
# ends on a missed target has no placement to celebrate, and the same information is worth
# reading either way (gameplay.md -> "The run, end to end").
func _build_summary() -> void:
	var result: Dictionary = RunSession.last_result()
	var done := int(result.get("stages_completed", 0))
	var total := int(result.get("stage_count", 0))
	_page.body().add_child(UITheme.label("Stages cleared: %d / %d" % [done, total]))
	_page.body().add_child(UITheme.label("Money earned: %d" % int(result.get("money_earned", 0))))

	var times: Array = result.get("stage_times_ms", [])
	for i in times.size():
		var ms := int(times[i])
		_page.body().add_child(UITheme.label(
			"Stage %d: %.2fs" % [i + 1, float(ms) / 1000.0]))

	# Clearing the stored result is what makes this screen one-shot: _ready() shows the
	# summary whenever one is parked, so leaving it set would trap the player here.
	_action("Continue", func() -> void:
		RunSession.clear_last_result()
		_show(View.MAIN))


# --- SHOP ----------------------------------------------------------------------
# Stage 6's meta shop (todo/roguelike-pivot.md "Upgrades — RR's two-tier model" + "Car
# acquisition — RR's shop"). Reached from MAIN, not from the run-starting flow: boost
# levels and the Engine Swap unlock are permanent purchases available any time, unlike car
# buying, which decision 28 keeps on the CAR page above (see that function's own comment).
#
# ONE flat list — every purchasable sits side by side in the same carousel, no
# boost-levels sub-page: these are all permanent money sinks a player comparison-shops
# between, so burying half of them a click deeper hid them from the exact screen where
# the money gets spent.
#
# One card per BoostLibrary.CATALOGUE id: its level (out of GameConfig.boost_level_max),
# the price of the NEXT level, and the effect range the whole ladder covers (decision 42
# — "the shop shows the effect range per level ... so the purchase is legible without a
# live car to compute against"; BoostLibrary.effect_range_text is that formatting), then
# the Engine Swap unlock card. Confirming a card makes the purchase; a card at its cap,
# already bought, or the player cannot afford is disabled (shown, dimmed — CardCarousel's
# own disabled convention, same as a locked region card), so the cursor's confirm can
# never land on a dead purchase.
func _build_shop() -> void:
	_page.body().add_child(UITheme.label("Money: %d" % Save.money()))
	var max_level := int(Config.data.boost_level_max)
	var carousel := _build_carousel()
	var actions: Array[Callable] = []

	for id in BoostLibrary.CATALOGUE:
		var boost_id := String(id)
		var level := Save.boost_level(boost_id)
		var label := BoostLibrary.label_for(boost_id)
		var at_cap := level >= max_level
		var price := Save.boost_level_price(boost_id)
		var card := carousel.add_card(at_cap or Save.money() < price)
		card.visual.add_child(_card_icon(boost_id))
		var title := UITheme.label(label)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.info.add_child(title)
		var sub := UITheme.label("Lv %d/%d, rolls %s" % [level, max_level,
			BoostLibrary.effect_range_text(boost_id)], "dim")
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.info.add_child(sub)
		# Appended in a branch rather than a ternary: the two strings' intent differs
		# (a state vs a price) and each wants its own theme colour, not just its own text.
		if at_cap:
			var max_lbl := UITheme.label("MAX")
			max_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			card.info.add_child(max_lbl)
		else:
			var price_lbl := UITheme.label("Next — %d" % price, "gold")
			price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			card.info.add_child(price_lbl)
		actions.append(func() -> void: _buy_boost_level(boost_id))

	var unlocked := Save.engine_swap_unlocked()
	var swap_price := Save.engine_swap_unlock_price()
	_text_card(carousel, "Engine Swap",
		"Unlocked" if unlocked else "Unlock — %d" % swap_price,
		unlocked or Save.money() < swap_price, "engine_swap")
	actions.append(_buy_engine_swap_unlock)

	carousel.confirmed.connect(func(i: int) -> void: actions[i].call())
	_action("Back", func() -> void: _show(View.MAIN))


func _buy_engine_swap_unlock() -> void:
	if Save.buy_engine_swap_unlock():
		_show(View.SHOP)


func _buy_boost_level(id: String) -> void:
	if Save.buy_boost_level(id):
		_show(View.SHOP)


# --- SKILLS -----------------------------------------------------------------------
# Stage 7's skills (todo/roguelike-pivot.md "Skills — a straight lift from RR"). One row
# per SkillLibrary.all() entry, in ONE of three states — locked (unlock stat below its
# threshold, shown but not focusable, same idiom as a locked region), purchasable (a Buy
# row), or owned (an Equip/Unequip row, gated on GameConfig.skill_max_equipped once
# every owned slot is full). NO GAMEPLAY EFFECT YET — see SkillLibrary's own header —
# this page is the gate/purchase/equip state machine, not a stat-boosting one.

func _build_skills() -> void:
	# The equipped count is the page's ONE header line, deliberately not joined by a
	# "Money: N" readout: the header must occupy the same height on every visit so the
	# carousel below doesn't jump, and the money a Buy card needs is already on the
	# card itself ("Buy — 5000", dimmed when unaffordable).
	var equipped := Save.equipped_skills()
	var cap := int(Config.data.skill_max_equipped)
	_page.body().add_child(UITheme.label("Equipped: %d/%d" % [equipped.size(), cap]))

	var carousel := _build_carousel()
	var actions: Array[Callable] = []

	for skill in SkillLibrary.all():
		var id := String(skill.get("id", ""))
		if id.is_empty():
			continue
		var label := SkillLibrary.label_for(id)
		if not SkillLibrary.is_unlocked(id, Save.profile):
			_text_card(carousel, label, "Locked — %s" % SkillLibrary.unlock_label(id),
				true, id)
			actions.append(func() -> void: pass)
			continue
		if not Save.owns_skill(id):
			var price := SkillLibrary.price_of(id)
			_text_card(carousel, label, "Buy — %d" % price,
				Save.money() < price, id)
			actions.append(func() -> void: _buy_skill(id))
			continue
		if Save.skill_equipped(id):
			_text_card(carousel, label, "Equipped — tap to unequip", false, id)
			actions.append(func() -> void: _unequip_skill(id))
		else:
			_text_card(carousel, label, "Tap to equip",
				equipped.size() >= cap, id)
			actions.append(func() -> void: _equip_skill(id))

	carousel.confirmed.connect(func(i: int) -> void: actions[i].call())
	_action("Back", func() -> void: _show(View.MAIN))


func _buy_skill(id: String) -> void:
	if Save.buy_skill(id):
		_show(View.SKILLS)


func _equip_skill(id: String) -> void:
	if Save.equip_skill(id):
		_show(View.SKILLS)


func _unequip_skill(id: String) -> void:
	if Save.unequip_skill(id):
		_show(View.SKILLS)


# --- STATS -------------------------------------------------------------------------
# Stage 7's lifetime stats (todo/roguelike-pivot.md "Lifetime global stats"). Pure
# read-out, one row per PAIR of LifetimeStats.IDS — THE TRAP HERE, per CLAUDE.md, is
# that a wall of read-only rows has nothing focusable at all if every row is a Label;
# every row here IS a Label (nothing on this page is chooseable), so Back — a real
# Button — is deliberately the page's ONLY focusable control, same as MenuNav requires
# of every menu in the game.
#
# TWO COLUMNS (a 2-wide GridContainer, ids in table order reading left-to-right then
# down): ten stats as ten single-column rows ran the page too tall for the screen, and
# each row is short enough that two sit comfortably side by side.

func _build_stats() -> void:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", UITheme.GAP)
	_page.body().add_child(grid)
	for id in LifetimeStats.IDS:
		var stat_id := String(id)
		grid.add_child(UITheme.label(
			"%s: %d" % [LifetimeStats.label_for(stat_id), Save.lifetime_stat(stat_id)]))
	_action("Back", func() -> void: _show(View.MAIN))


# --- SETTINGS ------------------------------------------------------------------

# The shared SettingsMenu (also hosted by pause_menu.gd's in-run overlay) mounted as a
# hub page — this is the only route to it OUTSIDE an active run (audio, display,
# gearbox, key bindings, mobile controls, account/cloud save, and Reset progress all
# live only here or in-run; a fresh player with no paused run had no way to reach any
# of them before this page existed).
func _build_settings() -> void:
	# NOT wrapped in a second TouchScrollContainer: _page.body() is ALREADY the scrollable
	# area (MenuPage's own _scroll). A ScrollContainer deliberately reports a near-zero
	# minimum size (menu_page.gd::_sync_body_height's own comment on why that container isn't
	# EXPAND_FILL) — nesting one here made body()'s measured content collapse to that
	# near-zero size, so the whole page rendered as an almost-empty box with none of
	# SettingsMenu's rows visible, even though the node was mounted.
	_settings_menu = SettingsMenu.new()
	_settings_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.body().add_child(_settings_menu)
	# No camera_changed/scheme_changed hookup: the hub has no live CameraManager or
	# MobileControls scene to apply to immediately (same reasoning as the HQ title-screen
	# host in features/menus.md) — the choice is simply saved and takes effect next run.
	_action("Back", _settings_back)


# Give the shared menu's own sub-pages first refusal (Audio/Account/etc. back out to its
# category list before this shell backs out to MAIN) — the same pattern pause_menu.gd's
# _on_settings_back uses.
func _settings_back() -> void:
	if _settings_menu == null or not _settings_menu.go_back():
		_show(View.MAIN)
