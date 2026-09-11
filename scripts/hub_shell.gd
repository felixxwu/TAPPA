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
# model" + "Car acquisition — RR's shop"): every boost ladder in one flat list, reached from MAIN rather than from the run's own car-select
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
enum View { TITLE, MAIN, REGION, CAR, SUMMARY, SHOP, SKILLS, STATS, CHALLENGE, SETTINGS,
	FREEPLAY_CAR, FREEPLAY_REGION, FREEPLAY_SETUP }

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
# The Free Play flow's picks, held across its three pages (car -> region -> upgrades).
# Reset whenever the flow is entered from MAIN, so an abandoned half-picked plan never
# survives into a later one. Deliberately shell state, not FreePlay state: FreePlay's
# plan is only written on Start (the moment the choices are final), so a stale plan can
# never leak into a world boot the player backed out of.
var _fp_car := 0
var _fp_region := ""
var _fp_boosts: Array[String] = []

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
	# summary directly rather than the TITLE splash, or the player has to tap through a
	# logo screen with no idea whether they cleared the region — the run's outcome is the
	# whole point of it. A cold boot has no result to show, so it gets the splash and taps
	# through Start into MAIN itself (_enter_game).
	if not RunSession.last_result().is_empty():
		_show(View.SUMMARY)
		# The "a newer native build is out" check (features/update-check.md) — re-homed
		# here from the deleted diegetic hub's title shot. Not awaited: the hub must be
		# interactive while the GET is in flight, and every failure inside is a silent
		# no-op by design. On a cold boot this runs from _enter_game instead, once the
		# player actually reaches MAIN — it is MAIN-only (see _check_for_update), and
		# firing it while the player is still looking at TITLE would race Start.
		_check_for_update()
	else:
		_show(View.TITLE)
	# THE BOOT PULL LANDS AFTER THIS PAGE IS BUILT. A signed-in player's cloud profile
	# is downloaded asynchronously just after boot (Cloud._kick_off_initial_pull), so a
	# run paused on another device — or on this one, before a re-install — only enters
	# Save.profile once MAIN has already decided whether to offer "Resume run". Without
	# this, the front door showed no Resume card on first load and only grew one after
	# the player navigated somewhere and came back. Rebuild MAIN in place when the
	# profile is swapped underneath us; other views are left alone (the player is
	# mid-interaction on them, and every one of them re-reads the profile when next
	# opened anyway).
	if Cloud.has_signal("profile_replaced"):
		Cloud.profile_replaced.connect(_on_profile_replaced)

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


# The cloud pull replaced the local profile (see the connect in _ready). Only MAIN is
# rebuilt: it is the page whose contents depend on the profile the moment it is shown.
func _on_profile_replaced() -> void:
	if _view == View.MAIN and is_instance_valid(_page):
		_show(View.MAIN)


# The heading each view carries. The SUMMARY heading is the one that says something the
# player cannot get anywhere else on that page: whether the run ended by clearing the
# region or by missing a target. MAIN deliberately gets NO heading (the "" default) —
# it is the game's front door and the only page a player can't mistake for another, so
# a "TAPPA" title there said nothing the page's own content didn't.
func _title_for(view: int) -> String:
	match view:
		# TITLE builds its own big logo label straight into the body (see _build_title) —
		# a MenuPage "title" opt renders at TITLE_FONT_SIZE, half the 72px the splash wants.
		View.TITLE: return ""
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
		View.FREEPLAY_CAR: return "Free play — pick a car"
		View.FREEPLAY_REGION: return "Free play — pick a region"
		View.FREEPLAY_SETUP: return "Free play — upgrades"
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
		# Zero body padding too, matching CardUI.build_carousel's own edge-to-edge defaults
		# (CAROUSEL_PAGE_MARGIN/CAROUSEL_PAGE_PADDING) — otherwise MenuPage's default
		# PANEL_PAD inset the body from a margin build_carousel no longer accounts for,
		# leaving a gap between the carousel's cards and the literal screen edge.
		page_opts["padding"] = CardUI.CAROUSEL_PAGE_PADDING
	elif view == View.TITLE:
		# TAPPA stands alone on the splash — no card grid to keep legible against a
		# transparent box here, just the logo itself, so drop the body box's opaque
		# black panel_box background the same way carousel pages do.
		page_opts["alpha"] = 0.0
	_page = MenuPage.open_modal(self, page_opts)
	match view:
		View.TITLE: _build_title()
		View.MAIN: _build_main()
		View.REGION: _build_region()
		View.CAR: _build_car()
		View.SUMMARY: _build_summary()
		View.SHOP: _build_shop()
		View.SKILLS: _build_skills()
		View.STATS: _build_stats()
		View.CHALLENGE: _build_challenge()
		View.SETTINGS: _build_settings()
		View.FREEPLAY_CAR: _build_freeplay_car()
		View.FREEPLAY_REGION: _build_freeplay_region()
		View.FREEPLAY_SETUP: _build_freeplay_setup()
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
		View.FREEPLAY_CAR: _show(View.MAIN)
		View.FREEPLAY_REGION: _show(View.FREEPLAY_CAR)
		View.FREEPLAY_SETUP: _show(View.FREEPLAY_REGION)
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
# Eight screens (MAIN, REGION, CAR, SHOP, SKILLS, the three FREEPLAY steps)
# present their choices
# as a CardCarousel (features/card-carousel.md) instead of a vertical row list: one
# carousel per page, added to the body ahead of any plain labels/rows that page
# still wants (e.g. the "Money: N" readout). CHALLENGE / STATS keep the plain row
# list — they were not in the set this conversion asked for, and STATS in
# particular has nothing choosable to put on a card.

# CARDS AND CAROUSELS LIVE IN CardUI (scripts/card_ui.gd) — the icon loader, the one
# text-card shape and the carousel builder were all extracted there so the between-stage
# pick panel could share them (run_pick_panel.gd), and this file's private copies are
# gone. CAR cards still swap their icon out for a real CarCardPreview once one is built
# (see _sync_car_previews).

# The carousel pages run edge to edge (CardUI.CAROUSEL_PAGE_MARGIN); every other page keeps
# MenuPage's ordinary wide margin.
const _DEFAULT_PAGE_MARGIN := 24.0


func _page_margin_for(view: int) -> float:
	return CardUI.CAROUSEL_PAGE_MARGIN if _is_carousel_view(view) else _DEFAULT_PAGE_MARGIN


func _is_carousel_view(view: int) -> bool:
	return view in [View.MAIN, View.REGION, View.CAR, View.SHOP, View.SKILLS,
		View.FREEPLAY_CAR, View.FREEPLAY_REGION, View.FREEPLAY_SETUP]


# --- TITLE ---------------------------------------------------------------------

# The game's cold-boot splash: TAPPA large in the middle of the screen, Start/Quit at
# the bottom. Skipped on a run-end return to the hub (see _ready) — it is the app's
# front door, not something inserted between every screen and the one before it.
func _build_title() -> void:
	var logo := UITheme.label("TAPPA")
	logo.add_theme_font_size_override("font_size", UITheme.px(72))
	logo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page.body().add_child(logo)

	# Leaving (Quit) is leftmost, proceeding (Start) is rightmost — features/menus.md
	# "Button order". Quit is omitted where it would do nothing (see _quit_applicable).
	if _quit_applicable():
		_action("Quit", func() -> void: get_tree().quit())
	_action("Start", _enter_game)


# A browser tab can't meaningfully close itself from a script, so a Quit button there
# would just sit dead on screen — the same reasoning Platform.is_web() gates elsewhere
# (see fps_setting.gd, web_fullscreen.gd).
func _quit_applicable() -> bool:
	return not Platform.is_web()


# TITLE's Start button. The only path off TITLE, so it always lands on MAIN — a
# finished run never reaches TITLE in the first place (see _ready).
func _enter_game() -> void:
	_show(View.MAIN)
	_check_for_update()


# --- MAIN --------------------------------------------------------------------

func _build_main() -> void:
	var money := UITheme.label("Money: %d" % Save.money())
	_page.body().add_child(money)

	var carousel := CardUI.build_carousel(_page)
	var actions: Array[Callable] = []

	# A paused run is offered FIRST, because the alternative — starting anything else —
	# discards it and burns its attempt (decision 48). Putting Resume anywhere but the top
	# is how a player loses a run they meant to finish.
	var resumable: Dictionary = RunSessionScript.resumable_run(
		Save.profile, int(Time.get_unix_time_from_system()))
	if not resumable.is_empty():
		CardUI.text_card(carousel, "Resume run", "", false, "resume_run")
		actions.append(_resume_run)

	CardUI.text_card(carousel, "New run", "", false, "new_run")
	actions.append(func() -> void: _show(View.REGION))
	# The shop is GATED on owning a car. Every shop ladder is a permanent money sink, so a
	# carless player who spends down there can end up unable to afford ANY car — a dead end
	# with no way back, since money only comes from running stages and a run needs a car.
	# Buying the first car (the CAR page) has to come first.
	var has_car := not (Save.profile.get(Save.KEY_CARS, []) as Array).is_empty()
	CardUI.text_card(carousel, "Shop", "Buy a car first" if not has_car else "",
		not has_car, "shop")
	actions.append(func() -> void:
		if has_car:
			_show(View.SHOP))
	CardUI.text_card(carousel, "Skills", "", false, "skills")
	actions.append(func() -> void: _show(View.SKILLS))
	# Rally challenge sits AFTER Shop/Skills: it is a secondary way to start a run, so
	# it follows the primary one (New run) and its menu-alternatives, rather than
	# splitting them.
	CardUI.text_card(carousel, "Rally challenge", "", false, "rally_challenge")
	actions.append(func() -> void: _show(View.CHALLENGE))
	CardUI.text_card(carousel, "Free play", "", false, "car")
	actions.append(func() -> void: _show(View.FREEPLAY_CAR))
	CardUI.text_card(carousel, "Lifetime stats", "", false, "stats")
	actions.append(func() -> void: _show(View.STATS))
	CardUI.text_card(carousel, "Settings", "", false, "settings")
	actions.append(func() -> void: _show(View.SETTINGS))
	carousel.confirmed.connect(func(i: int) -> void: actions[i].call())

	_action("Quit", func() -> void: get_tree().quit())
	_build_version_label()


# Passive build-version readout, bottom-right corner of the MAIN page, so a Play
# tester can read off which build landed on their device (features/update-check.md).
# Added straight to `_page` (the full-rect modal Control), NOT to body() — it must
# float free of the body box/carousel layout and never join MenuNav's focusable set.
# Hidden entirely for an unstamped build (editor, local run) rather than showing an
# empty/placeholder string.
func _build_version_label() -> void:
	var raw := str(ProjectSettings.get_setting("application/config/version", ""))
	var text := UpdateCheck.display_version(raw)
	if text.is_empty():
		return
	var l := UITheme.label(text, "dim")
	l.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	l.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	l.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var m := Config.data.hub_version_label_margin_px
	l.position -= Vector2(m, m)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page.add_child(l)


# --- Update check (features/update-check.md) ----------------------------------
# Ported from the deleted hq.gd::_check_for_update: native builds only (web is served
# from a build-unique path, so a browser player is always current; headless/editor have
# no stamped build number), Cloud.rest's single HTTPRequest owner is reused rather than
# adding a second client for one GET per boot, and MAIN-ONLY, re-checked AFTER the await
# — the fetch outlives the boot frame, and an update notice landing on top of a screen
# the player walked into is an interruption; the next boot to MAIN raises it instead.
# Dismissal is recorded from the ACTIONS (ConfirmPopup.open returns null when another
# modal owns the screen — a prompt that never appeared must not count as shown).
func _check_for_update() -> void:
	if not UpdateCheck.applicable():
		return
	var latest: int = await UpdateCheck.fetch_latest_build(Cloud.rest)
	if not is_inside_tree() or _view != View.MAIN:
		return
	var current := UpdateCheck.current_build()
	var dismissed := int(Save.get_setting(UpdateCheck.DISMISSED_SETTING, 0))
	if not UpdateCheck.should_prompt(current, latest, dismissed):
		return
	_show_update_prompt(current, latest)


# Split out of _check_for_update so the prompt itself is testable without fighting the
# platform gate (UpdateCheck.applicable() is false under headless by design).
func _show_update_prompt(current: int, latest: int) -> void:
	var remember := func() -> void:
		Save.set_setting(UpdateCheck.DISMISSED_SETTING, latest)
	ConfirmPopup.open(self, "Update available",
		UpdateCheck.prompt_body(current, latest),
		[
			# Leaving is left, proceeding is right (features/menus.md -> "Button order");
			# Back routes to index 0, so Esc / gamepad-B is "Not now".
			{"label": "Not now", "callback": remember},
			{"label": UpdateCheck.store_label(), "callback": func() -> void:
				remember.call()
				OS.shell_open(UpdateCheck.store_url())},
		], 1)


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
	var carousel := CardUI.build_carousel(_page)
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
			CardUI.text_card(carousel, region_name, "Locked — pays $%d/stage" % reward,
				true, "region_locked")
			ids.append("")
			continue
		var mark := "$%d/stage" % reward
		if cleared.has(id):
			mark += " — Cleared"
		CardUI.text_card(carousel, region_name, mark, false, "region")
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

	var carousel := CardUI.build_carousel(_page)
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
	owned.sort_custom(func(a, b) -> bool:
		return int(CarLibrary.for_owned(a).get("cost", 0)) < int(CarLibrary.for_owned(b).get("cost", 0)))
	for car in owned:
		var entry: Dictionary = car
		var iid := int(entry.get("instance_id", -1))
		if iid < 0:
			continue
		var spec: Dictionary = CarLibrary.for_owned(entry)
		var label := String(spec.get("name", entry.get("model_id", "car")))
		var over_cap := _pending_challenge != "" and not eligible_ids.has(iid)
		var card := carousel.add_card(over_cap)
		card.visual.add_child(CardUI.card_icon("car"))
		card.info.add_child(UITheme.card_title(label))
		if over_cap:
			card.info.add_child(UITheme.label("Over the rating cap", "dim"))
			actions.append(null)
		else:
			actions.append(entry)
		car_refs.append(entry)

	var catalogue := CarLibrary.all()
	var shop_indices: Array[int] = []
	shop_indices.assign(range(catalogue.size()))
	shop_indices.sort_custom(func(a: int, b: int) -> bool:
		return int(catalogue[a].get("cost", 0)) < int(catalogue[b].get("cost", 0)))
	for index in shop_indices:
		var spec: Dictionary = catalogue[index]
		var model_id := String(spec.get("id", ""))
		if model_id.is_empty() or Save.owns_model(model_id):
			continue
		var cost := int(spec.get("cost", 0))
		var car_name := String(spec.get("name", model_id))
		var cant_afford := Save.money() < cost
		var card := carousel.add_card(cant_afford)
		card.visual.add_child(CardUI.card_icon("car"))
		card.info.add_child(UITheme.card_title(car_name))
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

	# The spec sheet for whichever card is highlighted. A PAGE ACTION rather than an info
	# icon ON the card: a card's own press already means "start a run with this" / "buy
	# this", and CardCarousel gives a card one confirm, not two — so a per-card icon would
	# either need a pointer (breaking CLAUDE.md's keyboard+gamepad rule) or steal the
	# confirm that buys the car. As an action it sits in the same focusable row as Back and
	# reads the carousel's live selection, so it works identically on a pad.
	_action("Show stats", func() -> void:
		_show_car_stats(car_refs[carousel.selected_index()]))

	_action("Back", func() -> void:
		_show(View.CHALLENGE if _pending_challenge != "" else View.REGION))


# The plain (no comparison) car spec sheet, over the car page. `ref` is a `car_refs` entry:
# an owned-car Dictionary, or a catalogue index for a car the player does not own yet — the
# unowned case passes an EMPTY owned dict, so the sheet reads the showroom car with no
# upgrades, tuning or engine swap resolved onto it, which is exactly what a car you have
# not bought is.
func _show_car_stats(ref: Variant) -> void:
	var owned: Dictionary = ref if ref is Dictionary else {}
	var meta: Dictionary = CarLibrary.for_owned(owned) if ref is Dictionary \
		else CarLibrary.all()[int(ref)]
	if meta.is_empty():
		return
	var page := MenuPage.open_modal(self, {"margin": 24.0,
		"title": String(meta.get("name", "Car"))})
	page.body().add_child(CarStatsPanel.build(CarStats.values(owned, meta)))
	var close := func() -> void:
		# Hide and leave the claimer group BEFORE freeing, because _show() below rebuilds
		# the page underneath in this SAME frame. MenuNav.screen_claimer skips a claimer
		# that is queued for deletion or hidden, but we free the parent CanvasLayer rather
		# than this page, and the deletion flag reports on the node it was called on — so
		# without this the dying modal can still read as the live claimer for a frame and
		# swallow the rebuilt page's input. Same reasoning as
		# world.gd::_teardown_interstitial_page.
		page.hide()
		page.remove_from_group(MenuNav.SCREEN_CLAIMER_GROUP)
		var layer := page.get_parent()
		if is_instance_valid(layer):
			layer.queue_free()
		# Rebuild the page underneath so its carousel re-claims focus.
		_show(_view)
	var back := UITheme.button("Back")
	back.pressed.connect(close)
	page.add_action(back)
	MenuNav.attach(page, {"on_back": close})


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
			card.visual.add_child(CardUI.card_icon("car"))

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


# --- FREE PLAY -------------------------------------------------------------------
# A session-less sandbox drive (scripts/free_play.gd): any catalogue car, any region's
# stage pool (locked regions included — nothing is at stake), any combination of the
# in-run boosts, no clock and no run state. Three pages, each one carousel, each
# confirm advancing to the next; the setup page's Start writes the FreePlay plan and
# boots the run scene, whose session-less branch consumes it (world.gd
# -> _field_free_play_car / FreePlay.event).

func _build_freeplay_car() -> void:
	_fp_car = 0
	_fp_region = ""
	_fp_boosts = []
	var carousel := CardUI.build_carousel(_page)
	# Parallel to the carousel's cards: the CarLibrary INDEX each card represents — the
	# same shape _build_car's car_refs uses, so _sync_car_previews (built for that page)
	# works unchanged here and free play's cars get the same live CarCardPreview instead
	# of a flat "car" icon.
	var fp_catalogue := CarLibrary.all()
	var sorted_indices: Array[int] = []
	sorted_indices.assign(range(fp_catalogue.size()))
	sorted_indices.sort_custom(func(a: int, b: int) -> bool:
		return int(fp_catalogue[a].get("cost", 0)) < int(fp_catalogue[b].get("cost", 0)))
	var indices: Array[int] = []
	for index in sorted_indices:
		var spec: Dictionary = fp_catalogue[index]
		var model_id := String(spec.get("id", ""))
		if model_id.is_empty():
			continue
		var card := carousel.add_card(false)
		card.visual.add_child(CardUI.card_icon("car"))
		card.info.add_child(UITheme.card_title(String(spec.get("name", model_id))))
		card.info.add_child(UITheme.label(
			"Owned" if Save.owns_model(model_id) else "Not owned — free play lends it", "dim"))
		indices.append(index)

	_sync_car_previews(carousel, indices)
	carousel.selection_changed.connect(func(_i): _sync_car_previews(carousel, indices))

	carousel.confirmed.connect(func(i: int) -> void:
		_fp_car = indices[i]
		_show(View.FREEPLAY_REGION))
	_action("Back", func() -> void: _show(View.MAIN))


func _build_freeplay_region() -> void:
	var carousel := CardUI.build_carousel(_page)
	# Parallel to the carousel's cards: the region id each card represents. EVERY
	# region is selectable — the unlock gate is a progression rule for runs, and free
	# play has no progression to protect.
	var ids: Array[String] = []
	for region in RegionLibrary.ordered():
		var id := String(region.get("id", ""))
		if id == "":
			continue
		CardUI.text_card(carousel, String(region.get("name", id)), "Any stage from this region",
			false, "region")
		ids.append(id)
	carousel.confirmed.connect(func(i: int) -> void:
		_fp_region = ids[i]
		_show(View.FREEPLAY_SETUP))
	_action("Back", func() -> void: _show(View.FREEPLAY_CAR))


func _build_freeplay_setup() -> void:
	var carousel := CardUI.build_carousel(_page)
	# Parallel to the carousel's cards: the boost id each card toggles. Confirming a
	# card TOGGLES it (any combination, order-free) and rebuilds the page so every
	# card's Selected/Not state is legible; Start is what actually launches.
	var ids: Array[String] = []
	for id in BoostLibrary.CATALOGUE:
		var boost_id := String(id)
		CardUI.text_card(carousel, BoostLibrary.label_for(boost_id),
			"Selected — tap to remove" if _fp_boosts.has(boost_id) else "Tap to add",
			false, boost_id)
		ids.append(boost_id)
	carousel.confirmed.connect(func(i: int) -> void:
		if _fp_boosts.has(ids[i]):
			_fp_boosts.erase(ids[i])
		else:
			_fp_boosts.append(ids[i])
		_show(View.FREEPLAY_SETUP))
	_action("Start free play", func() -> void: _start_free_play())
	_action("Back", func() -> void: _show(View.FREEPLAY_REGION))


func _start_free_play() -> void:
	if _fp_region == "":
		return
	# One stage drawn from the chosen region's pool, seeded from the clock so every
	# entry can roll a different road (RegionStagePool.draw(region, count, seed)).
	var event: Dictionary = RegionStagePool.draw(_fp_region, 1,
		int(Time.get_unix_time_from_system()))[0]
	FreePlay.begin(_fp_car, event, _fp_boosts)
	Scenes.change_to(get_tree(), Scenes.MAIN)


# --- SUMMARY -----------------------------------------------------------------

# One screen for BOTH outcomes — cleared the region, or stopped by the clock. A run that
# ends on a missed target has no placement to celebrate, and the same information is worth
# reading either way (gameplay.md -> "The run, end to end").
func _build_summary() -> void:
	var result: Dictionary = RunSession.last_result()
	var done := int(result.get("stages_completed", 0))
	var total := int(result.get("stage_count", 0))
	_announce_run_outcome(result, done, total)
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


# The run's END is the biggest moment in the loop — clearing all eight stages, or being
# stopped cold by a missed target (decision 4's one hard fail state) — and the plain stat
# sheet above reads identically for both, which is exactly the "happens a bit silently"
# problem this fixes. A ConfirmPopup fired the instant the summary builds makes the moment
# land: the player has to acknowledge what just happened, in words, before the numbers.
# Refused (returns null) only if another modal already owns the screen — no different from
# any other ConfirmPopup caller in the shell, see features/modals.md → "One modal at a time".
func _announce_run_outcome(result: Dictionary, done: int, total: int) -> void:
	var money := int(result.get("money_earned", 0))
	var cleared := bool(result.get("completed", false))
	var title: String
	var body: String
	if cleared:
		title = "REGION CLEARED!"
		body = "All %d stages cleared. $%d banked." % [total, money]
	else:
		title = "RUN OVER"
		body = "Missed the target on stage %d. $%d banked from the %d stage%s you cleared." % [
			done + 1, money, done, "" if done == 1 else "s"]
	ConfirmPopup.open(self, title, body, [{"label": "OK", "callback": Callable()}])


# --- SHOP ----------------------------------------------------------------------
# Stage 6's meta shop (todo/roguelike-pivot.md "Upgrades — RR's two-tier model" + "Car
# acquisition — RR's shop"). Reached from MAIN, not from the run-starting flow: boost
# levels are permanent purchases available any time, unlike car
# buying, which decision 28 keeps on the CAR page above (see that function's own comment).
#
# ONE flat list — every purchasable sits side by side in the same carousel, no
# boost-levels sub-page: these are all permanent money sinks a player comparison-shops
# between, so burying half of them a click deeper hid them from the exact screen where
# the money gets spent. The Engine Swap is NOT here — it is a genuine, deterministic
# mid-run engine swap now (RunSession._pool_engine_swap_ids, features/engine-swap.md),
# not a leveled purchase.
#
# One card per BoostLibrary.CATALOGUE id: its level (1-based — Save.boost_level's 0 means
# "never upgraded", displayed as "Lv 1" since that's the level whose base magnitude the
# player already has, not "no level"), the current increase that level gives right now
# (BoostLibrary.current_effect_text_for — "how far the level I OWN pushes it", not the
# whole ladder's range or the next level's delta: the total rung count and the "how much
# more" figure are deliberately not shown), and the price of the NEXT level. Confirming a
# card makes the purchase; a card at its cap or the player cannot afford is disabled
# (shown, dimmed — CardCarousel's own disabled convention, same as a locked region card),
# so the cursor's confirm can never land on a dead purchase.
func _build_shop() -> void:
	_page.body().add_child(UITheme.label("Money: %d" % Save.money()))
	var max_level := int(Config.data.boost_level_max)
	var carousel := CardUI.build_carousel(_page)
	var actions: Array[Callable] = []

	for id in BoostLibrary.CATALOGUE:
		var boost_id := String(id)
		var level := Save.boost_level(boost_id)
		var label := BoostLibrary.label_for(boost_id)
		var at_cap := level >= max_level
		var price := Save.boost_level_price(boost_id)
		# The third line is a state ("MAX") or a price ("Next — N"), each with its
		# own theme colour — chosen in a branch, not a ternary, so the two intents
		# stay visibly separate.
		var extra := "Next — %d" % price
		var extra_variant := "gold"
		if at_cap:
			extra = "MAX"
			extra_variant = ""
		CardUI.text_card(carousel, label, "Lv %d, %s" % [level + 1,
				BoostLibrary.current_effect_text_for(boost_id)],
			at_cap or Save.money() < price, boost_id, extra, extra_variant)
		actions.append(func() -> void: _buy_boost_level(boost_id))

	carousel.confirmed.connect(func(i: int) -> void: actions[i].call())
	_action("Back", func() -> void: _show(View.MAIN))


func _buy_boost_level(id: String) -> void:
	if Save.buy_boost_level(id):
		_show(View.SHOP)


# --- SKILLS -----------------------------------------------------------------------
# Stage 7's skills (todo/roguelike-pivot.md "Skills — a straight lift from RR"). One row
# per SkillLibrary.all() entry, in ONE of three states — locked (unlock stat below its
# threshold, shown but not focusable, same idiom as a locked region), purchasable (a Buy
# row), or owned (an Equip/Unequip row, gated on GameConfig.skill_max_equipped once
# every owned slot is full). This page is only the gate/purchase/equip state machine —
# an equipped skill's actual EFFECT is applied at fielding time, not here:
# SkillLibrary.equipped_effects rides the same UpgradeLibrary.EFFECTS + car `boosts` seam
# a run's boosts do (decision 51), merged by world.gd::_owned_with_run_effects.

func _build_skills() -> void:
	# The equipped count is the page's ONE header line, deliberately not joined by a
	# "Money: N" readout: the header must occupy the same height on every visit so the
	# carousel below doesn't jump, and the money a Buy card needs is already on the
	# card itself ("Buy — 5000", dimmed when unaffordable).
	var equipped := Save.equipped_skills()
	var cap := int(Config.data.skill_max_equipped)
	_page.body().add_child(UITheme.label("Equipped: %d/%d" % [equipped.size(), cap]))

	var carousel := CardUI.build_carousel(_page)
	var actions: Array[Callable] = []

	for skill in SkillLibrary.all():
		var id := String(skill.get("id", ""))
		if id.is_empty():
			continue
		var label := SkillLibrary.label_for(id)
		if not SkillLibrary.is_unlocked(id, Save.profile):
			CardUI.text_card(carousel, label, "Locked — %s" % SkillLibrary.unlock_label(id),
				true, id)
			actions.append(func() -> void: pass)
			continue
		if not Save.owns_skill(id):
			var price := SkillLibrary.price_of(id)
			CardUI.text_card(carousel, label, "Buy — %d" % price,
				Save.money() < price, id)
			actions.append(func() -> void: _buy_skill(id))
			continue
		if Save.skill_equipped(id):
			CardUI.text_card(carousel, label, "Equipped — tap to unequip", false, id)
			actions.append(func() -> void: _unequip_skill(id))
		else:
			CardUI.text_card(carousel, label, "Tap to equip",
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
