class_name RallyDetail
extends RefCounted
# Docs: features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_menu_flow.gd, tests/headless/test_menu_nav.gd, tests/headless/test_menu_page.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'RallyDetail' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).
# THE rally-detail panel: the card that names a rally, says which of your cars may enter it,
# shows your best finish, and offers "Enter Rally — choose car". One implementation, hosted by
# whoever is showing it.
#
# WHY IT IS ITS OWN CLASS. It used to be split across HqController — built by
# HqOverlays.build_detail_overlay, filled by HqTable._show_detail, with its nine widget handles
# and its open flag living on the HQ node itself — which made it reachable only from inside
# `hq.tscn`. The overworld hub (docs/superpowers/specs/2026-08-17-overworld-hq-design.md,
# slice 2) opens the SAME panel when the player drives into a rally's zone, and a second
# implementation of it would be two panels that drift. So the build half, the fill half and the
# state all moved here, behind a host-agnostic seam: `build()` takes the Node that will PARENT
# the panel, `fill()` takes a rally and a profile.
#
# EXTRACTED PER todo/hq-split.md, whose failure categories all apply to a move like this one:
# this is a RefCounted, so it has no `add_child`, no `get_tree()`, no signals of its own, and
# `self` is never a valid parent — every node operation goes through the `host` handed to
# build(), or through a node this class made itself. Grep it for `self` and `emit_signal` before
# trusting a green parse. Nothing in here touches HqController, deliberately: the dependency runs
# one way
# (hq.gd knows about RallyDetail) so both hubs can use it and neither class cycles.
#
# The statics below are the panel's shared vocabulary rather than its private business: the
# three widget builders and the modal width rule, plus the eligibility / restriction /
# qualifying-name text derivations. `HqController` keeps thin wrappers over them
# (`label`, `detail_heading`, `detail_wrap_label`, `_modal_body_width`, `_restriction_text`,
# `_entry_plan`, `_convertible_for`, `_eligibility_summary`, `_qualifying_cars_text`,
# `_stars_for`) because hq_challenge.gd, hq_carpark.gd, hq_overlays.gd and the tests all reach
# for them at those names — one derivation, every existing caller unchanged.

# The qualifying-car read-out names at most this many cars and tails the rest as "+N more", so
# a big garage can't blow the panel out. A pure display knob. HqController re-exports it as
# `MAX_QUALIFY_NAMES` (the name test_rally_detail.gd reads) rather than declaring a second copy.
const MAX_QUALIFY_NAMES := 1

# The panel's own body-width floor. Shared with the challenge screen's number on purpose: the
# two open from the same map and read as one panel shape, so a few px between them looks like
# a bug rather than a choice.
const BODY_WIDTH := 480.0

var layer: CanvasLayer            # the panel's own CanvasLayer (the host toggles its visible)
var page: MenuPage                # the scrolled body + pinned footer shape
var open := false                 # the panel is up (a sub-state of whatever view hosts it)

# The nine widget handles the fill half writes. They lived on HqController until this cut; the
# state moved with the code that owns it.
var title: Label                  # "<rally name> - N stages"
var region: Label                 # region tag under the title (muted)
var special: Label                # gold "SPECIAL EVENT" chip on the header row
var restriction: Label            # the eligibility restriction summary
var qualify: Label                # the qualifying cars, named (GREEN / RED / muted)
var adjust: Label                 # "N need a drivetrain conversion" caution (GOLD, hidden at 0)
var record: Label                 # best-finish text beside the StarRow
var stars: StarRow                # medal row for the player's best finish
var back_button: Button            # "< Map" — the host may retitle it (the overworld says "< Back")
var enter_button: Button          # "Enter Rally" — disabled when no owned car can qualify
var dev_win_button: Button        # DEV ONLY: win the rally outright; null in a release build


# --- Build -------------------------------------------------------------------

# Build the panel under `host` and wire its three controls. `on_dev_win` may be an empty
# Callable, in which case no dev button is built at all.
#
# Scrolled body + pinned actions row (MenuPage.open_modal — read menu_page.gd for why): the
# eligibility column is three autowrapped labels whose height depends on the rally's
# restriction text and the player's garage, and on a narrow phone frame they wrap to several
# lines each. Before that they could push "< Map" off the bottom of the canvas, and menu_back
# is Esc / gamepad B only — no way back by touch.
func build(host: Node, on_back: Callable, on_enter: Callable, on_dev_win: Callable) -> void:
	page = MenuPage.open_modal(host, {"margin": 24.0})
	layer = page.get_parent() as CanvasLayer
	var root: VBoxContainer = page.body()
	var footer: HBoxContainer = page.actions()
	# NO full-rect backing here: MenuPage's body box IS the panel, and it hugs its contents
	# so the map stays visible around it. A full-screen ColorRect behind it would paint over
	# the whole map table and undo that.

	# A WIDTH FLOOR, for the same reason the challenge screen has one: this page is re-filled
	# per rally (build() runs once, fill() rewrites it), and rally names, restriction strings
	# and star counts all differ in length — so a box that only hugs its contents is a
	# different width for every pin you open. Floored so it reads as one panel you keep
	# opening rather than a new one each time.
	page.set_body_width(body_width(host, BODY_WIDTH))  # clamped to the current logical canvas

	# Everything below is uppercased + locked to one font size by UITheme.enforce
	# (via the host's menu normalisation on each view change), so hierarchy comes from layout,
	# colour and separators — not font size. Stars are a polygon StarRow, since
	# Syne Mono has no ★ glyph.

	# --- Header: title + region on the left, a gold SPECIAL EVENT chip on the right.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	# AUTOWRAP both: set_body_width is only a FLOOR, so a non-wrapping label that wants more
	# still widens the box past it. A long rally name ("Archipelago Trial - 3 stages") is
	# exactly that, which would leave the width floored but still varying per pin. Everything
	# else in this page already wraps (wrap_label).
	title = plain_label("", 30)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(title)
	region = plain_label("", 16)
	region.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	region.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	region.add_theme_color_override("font_color", UITheme.MUTED)
	titles.add_child(region)
	special = plain_label("SPECIAL EVENT", 16)
	special.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	special.add_theme_color_override("font_color", UITheme.GOLD)
	header.add_child(special)

	root.add_child(HSeparator.new())

	# --- One full-width status column. The old per-stage breakdown (surface mix per
	# event) was more detail than the player needs here and cost half the panel; the
	# stage COUNT now rides on the header title instead ("Coastal Sprint - 3 stages"),
	# which frees the whole width for the eligibility read-out on small screens.
	var right := VBoxContainer.new()
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 4)
	root.add_child(right)
	right.add_child(heading("Eligibility"))
	# All sidebar text wraps within the column so a long restriction / caution can't
	# draw past the panel edge (Labels don't clip by default).
	restriction = wrap_label()
	right.add_child(restriction)
	qualify = wrap_label()
	right.add_child(qualify)
	adjust = wrap_label()
	adjust.add_theme_color_override("font_color", UITheme.GOLD)
	right.add_child(adjust)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 12)
	right.add_child(gap)
	right.add_child(heading("Your record"))
	var record_row := HBoxContainer.new()
	record_row.add_theme_constant_override("separation", 10)
	right.add_child(record_row)
	record = plain_label("", 16)
	record_row.add_child(record)
	stars = StarRow.new()
	stars.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	record_row.add_child(stars)

	# The actions row is the pinned footer, so both controls are always on screen.
	# "< Map" stays FOCUS_NONE deliberately: this panel has no MenuNav and no button
	# cursor — the host drives it directly from its own _unhandled_input (menu_select
	# enters, menu_back hides it), so making one of the two buttons focusable would
	# create a half-built focus graph with nothing to seed or move the cursor. Pinning is
	# what makes it reachable by touch; keyboard/gamepad already have menu_back.
	var back := Button.new()
	back.text = "< Map"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(on_back)
	footer.add_child(back)
	# Exposed so a host that did NOT come from the map table can retitle it — the overworld hub
	# opens this card by driving into a zone, where "< Map" names a screen the player never saw.
	back_button = back
	var enter := Button.new()
	enter.text = "Enter Rally — choose car >"
	enter.focus_mode = Control.FOCUS_NONE
	enter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enter.pressed.connect(on_enter)
	footer.add_child(enter)
	enter_button = enter

	# DEV ONLY: win this rally outright without driving it. Built only when the host offers a
	# callback AND dev tools are on (SettingsMenu.dev_tools_enabled — the same gate the dev
	# settings pages use), so a release export never has the node at all, rather than having a
	# hidden one.
	#
	# Per-rally rather than the mass "3-star all" cheat in Settings, because reveal is
	# geometric: completing ONE rally lights the circle around that pin and opens its
	# neighbours, so this walks the exploration graph a step at a time. The mass cheat
	# lights the whole map at once and can't show the progression at all.
	# FOCUS_NONE like its neighbours — this panel has no MenuNav, so a focusable button would
	# build a half-wired focus graph. The keyboard/gamepad route is the dev_complete_rally
	# action instead; see the host's input handler.
	if not on_dev_win.is_null() and SettingsMenu.dev_tools_enabled():
		var dev := Button.new()
		dev.text = "DEV: win"
		dev.focus_mode = Control.FOCUS_NONE
		dev.pressed.connect(on_dev_win)
		footer.add_child(dev)
		dev_win_button = dev


# --- Fill --------------------------------------------------------------------

# Re-fill the panel for `rally` against `profile`, and mark it open. `rally_id` is the id the
# RECORD half is looked up under; "" falls back to the rally's own id, which is what every
# caller with a resolved rally wants. The host is responsible for making the layer visible —
# it is the one that knows whether its view is on screen (see HqController.update_overlays).
func fill(rally: Dictionary, profile: Dictionary, rally_id := "") -> void:
	var id := rally_id if rally_id != "" else String(rally.get("id", ""))
	# The stage COUNT is all the per-stage detail the panel shows now — it rides on the
	# title ("Coastal Sprint - 3 stages") instead of a whole left-hand column.
	var stage_count: int = (rally.get("events", []) as Array).size()
	title.text = "%s - %d %s" % [
		String(rally.get("name", "?")), stage_count,
		"stage" if stage_count == 1 else "stages"]
	var region_id := String(rally.get("region", ""))
	region.text = region_id  # UITheme.enforce uppercases it
	region.visible = region_id != ""
	# Difficulty is a hidden tier (it drives reward value, not anything the player
	# sees) — the eligible-car requirement is the visible gate. The gold chip marks a
	# star-gated special event.
	special.visible = RallyLibrary.is_special(rally)

	# --- Eligibility: restriction + how many of the player's cars can enter.
	restriction.text = restriction_text(rally.get("restriction", {}))
	var elig := eligibility_summary(rally, profile.get(Save.KEY_CARS, []))
	var total := int(elig["total"])
	var qualifying := int(elig["qualify"])
	if total == 0:
		qualify.text = "No cars owned yet"
		qualify.add_theme_color_override("font_color", UITheme.INK_DIM)
	elif qualifying == 0:
		qualify.text = "No cars qualify"
		qualify.add_theme_color_override("font_color", UITheme.RED)
	else:
		qualify.text = qualifying_cars_text(elig["names"])
		qualify.add_theme_color_override("font_color", UITheme.GREEN)
	var adjustable := int(elig["adjust"])
	adjust.visible = adjustable > 0
	adjust.text = "%d need a drivetrain conversion to fit" % adjustable
	# Gated on the lineup having ANYTHING in it: a car that qualifies, or one the player
	# could convert to make it qualify. Not on `qualify` alone — a garage whose only route
	# in is "convert the AWD car" should still let the player walk in and be told that. Not
	# on owning a car either — if nothing can be made to fit, the car park is an empty room
	# and the button would be a dead end.
	enter_button.disabled = qualifying + adjustable == 0

	# --- Record: best finish + medal stars.
	var best := Save.best_placement(id)
	record.text = "Best: P%d" % best if best > 0 else "Not yet completed"
	# The star row always shows, unrun or not — an empty row of three reads as
	# "no medals yet" and keeps the record line's layout stable between rallies.
	stars.visible = true
	stars.setup(stars_for(id), RallyLibrary.MAX_STARS_PER_RALLY)

	open = true


# --- Shared widget builders --------------------------------------------------

# A plain Label with `text` and a `font_size` override — the Label.new() + font-size idiom
# repeated across the station overlays. Deliberately NOT UITheme.label, which forces a role
# colour + uppercase (a different look). Any further overrides (alignment, colour, autowrap,
# size flags) are applied by the caller after this returns.
static func plain_label(text: String, size: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	return lbl


# A quiet section heading for the rally-detail card. UITheme.enforce flattens every
# label to one size + uppercase, so a heading reads as a heading only by its dimmer
# colour and the grouping/spacing around it — not a larger font.
static func heading(text: String) -> Label:
	var lbl := plain_label(text, 16)
	lbl.add_theme_color_override("font_color", UITheme.INK_DIM)
	return lbl


# A sidebar Label that wraps to its column width instead of drawing off the panel edge.
static func wrap_label() -> Label:
	var lbl := plain_label("", 16)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(1, 0)  # don't let the longest word dictate column width
	return lbl


# The widest a centred modal column may ask for on the CURRENT logical canvas. The frame's
# width is not a constant — it is DESIGN_HEIGHT * device_aspect / horizontal_stretch (see
# display_stretch.gd), so a narrow/portrait phone aspect can give well under the authored
# preferred width, and a hard-coded 460-wide column can already be wider than the whole
# screen. `chrome` is the horizontal space the surrounding container costs (overlay margins,
# panel padding). Desktop keeps the authored `preferred` width; only the narrow tiers shrink.
#
# `host` is the node the sized content will actually live under. Pass the real host: inside a
# WorldPanel the canvas is the panel's own frame, unrelated to the main viewport width, and a
# column measured off the wrong one is either clipped or absurdly narrow.
static func body_width(host: Node, preferred: float, chrome := 88.0) -> float:
	var w := WorldPanel.layout_frame_size(host, Vector2.ZERO).x
	if w <= 0.0:
		return preferred
	return maxf(160.0, minf(preferred, w - chrome))


# --- Shared text / eligibility derivations -----------------------------------

# Human-readable summary of a rally's restriction (the detail panel + the car banner).
# Every gate is categorical — what KIND of car may enter, never how fast it is.
# One-line car summary shown in the car-select overlay: drive layout,
# peak horsepower, kerb weight, and condition. Health reads as a percentage (kept
# distinct so it doesn't read as the horsepower figure now shown alongside it); a
# spent (0 HP) car is flagged so the lineup makes clear how badly it will drive.
# The power-to-weight ratio lives only in the upgrades-menu detune readout. A fitted
# nitrous bottle is named LAST, after health — it's invisible to effective_meta (never
# moves HP/kg/power-to-weight, see features/nitrous.md) so it can only ever be a trailing
# addition, never something the earlier fields need to account for. Omitted entirely
# when the car has none, so the common case stays exactly the line it was.
#
# LIVES HERE, not on HqController, for the same reason `restriction_text` does: the overworld's
# diegetic car picker (`OverworldPicker`) shows the same summary for the same cars, and a second
# copy of this string is exactly the drift this project keeps paying for — the garage forked hq's
# repair button once and lost a web-export fix with it. `hq.gd::_car_stats_text` delegates here.
#
# A CAR THE PLAYER DOES NOT OWN YET (the starter pick's candidates, and any catalogue preview)
# CARRIES NO CONDITION, so the health field is OMITTED rather than invented. It has no `hp` and no
# instance id: reading the missing key as 0 would print `WRECKED` for a brand-new car, and
# defaulting it to full would print a figure the grant is free to contradict. Health is a property
# of an owned INSTANCE, not of a model — the line is honest one field shorter. (The field is
# already optional-shaped, exactly as the nitrous suffix is.)
static func car_stats_text(owned: Dictionary, entry: Dictionary) -> String:
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(owned.get("hp", 0.0))
	var owns_it := owned.has("hp") and int(owned.get("instance_id", -1)) >= 0
	var hp_text: String
	if not owns_it:
		hp_text = ""
	elif max_hp > 0.0 and hp <= 0.0:
		hp_text = "WRECKED"
	else:
		hp_text = "Health %d%%" % roundi(clampf(hp / max_hp, 0.0, 1.0) * 100.0) if max_hp > 0.0 else "Health ?"
	var meta := UpgradeLibrary.effective_meta(owned, entry)
	var stats := "%s | %.0f HP | %.0f kg" % [
		CarLibrary.drive_text(int(entry.get("drive_mode", -1))),
		CarLibrary.horsepower(meta),
		float(meta.get("mass", 0.0)),
	]
	if hp_text != "":
		stats += " | %s" % hp_text
	var nitrous_id := UpgradeLibrary.fitted_nitrous_id(owned)
	if nitrous_id != "":
		stats += " | %s" % String(UpgradeLibrary.by_id(nitrous_id).get("name", ""))
	return stats


static func restriction_text(rally_restriction: Dictionary) -> String:
	if rally_restriction.is_empty():
		return "any car"
	var parts: Array[String] = []
	if rally_restriction.has("drive_mode"):
		parts.append("%s cars" % CarLibrary.drive_text(int(rally_restriction["drive_mode"])))
	if rally_restriction.has("country"):
		parts.append("%s cars" % String(rally_restriction["country"]))
	if rally_restriction.has("car_type"):
		parts.append("%s body" % String(rally_restriction["car_type"]))
	if rally_restriction.has("doors_min"):
		parts.append(">= %d doors" % int(rally_restriction["doors_min"]))
	if rally_restriction.has("doors_max"):
		parts.append("<= %d doors" % int(rally_restriction["doors_max"]))
	# Engine-derived gates (displacement / cylinder count) are judged against the car's
	# CURRENT engine, so a swap changes them (RallyLibrary.ineligibility_reason).
	if rally_restriction.has("engine_min_l"):
		parts.append("engine >= %.1f L" % float(rally_restriction["engine_min_l"]))
	if rally_restriction.has("engine_max_l"):
		parts.append("engine <= %.1f L" % float(rally_restriction["engine_max_l"]))
	if rally_restriction.has("cylinders_min"):
		parts.append(">= %d cylinders" % int(rally_restriction["cylinders_min"]))
	if rally_restriction.has("cylinders_max"):
		parts.append("<= %d cylinders" % int(rally_restriction["cylinders_max"]))
	return ", ".join(parts)


# The eligibility decision for one owned `car` against `rally`, derived in ONE place so
# the pin-flag check (HqController._has_eligible_car) and the car-park lineup
# (hq_carpark.gd::_build_eligible_lineup) can't drift. Returns {eligible}: whether the car,
# exactly as the player left it, can enter this rally.
#
# Entry is purely CATEGORICAL (body/country/doors/cylinders/displacement/drive mode), so
# there is no "too fast" or "too slow" car — only a car of the wrong kind. It judges the
# car AS BUILT and proposes nothing: a wrong-drivetrain car is simply ineligible, and
# converting it is a garage decision the player makes themselves, where the conversion's
# star price is on screen (features/upgrade-catalogue.md).
static func entry_plan(rally: Dictionary, car: Dictionary) -> Dictionary:
	var entry := CarLibrary.for_owned(car)
	return {"eligible": RallyLibrary.is_eligible(rally, UpgradeLibrary.effective_meta(car, entry))}


# Whether this car is ineligible ONLY on drive mode — i.e. converting it (which the player
# does themselves in the garage, for stars) would let it in. Requires the conversion
# capability to be unlocked at all, so the panel never suggests a fix the player cannot buy.
static func convertible_for(rally: Dictionary, car: Dictionary, entry: Dictionary) -> bool:
	var r: Dictionary = rally.get("restriction", {})
	if not r.has("drive_mode"):
		return false
	if not UpgradeLibrary.drivetrain_swap_unlocked(Save.profile):
		return false
	var switched := UpgradeLibrary.effective_meta(car, entry).duplicate()
	switched["drive_mode"] = int(r["drive_mode"])
	return RallyLibrary.is_eligible(rally, switched)


# How many of the player's owned `cars` can enter `rally`, tallied on top of entry_plan so
# this agrees exactly with the green/grey map pin (_has_eligible_car) and the car-park lineup
# — the ONE eligibility decision, never re-derived here.
# Returns {total, qualify, adjust, names}: `total` counts owned cars whose model still
# resolves (a removed model is skipped, not counted); `qualify` = can enter as built
# (matches the pin); `adjust` = cars that CANNOT enter as built but WOULD after a
# drivetrain conversion. `names` lists the qualifying cars' display names, in roster
# order, so the panel can name them instead of just counting them.
#
# `adjust` used to be a subset of `qualify`, because the car park silently switched such a
# car at the Start button and counted it as qualifying. That switch is gone — a
# wrong-drivetrain car is simply ineligible — so `adjust` is now DISJOINT from `qualify`:
# it counts cars the player could convert themselves, which is exactly the prompt the
# panel line is for.
static func eligibility_summary(rally: Dictionary, cars: Array) -> Dictionary:
	var total := 0
	var qualify_count := 0
	var adjust_count := 0
	var names: Array[String] = []
	for car in cars:
		var entry := CarLibrary.for_owned(car)
		if entry.is_empty():
			continue  # a stale / removed model — not a countable car
		total += 1
		if bool(entry_plan(rally, car)["eligible"]):
			qualify_count += 1
			names.append(EngineSwap.display_name(entry, car))
		elif convertible_for(rally, car, entry):
			adjust_count += 1
	return {"total": total, "qualify": qualify_count, "adjust": adjust_count, "names": names}


# The qualifying-car read-out: name the cars rather than counting them. Caps the list at
# MAX_QUALIFY_NAMES and tails the rest as "+N more" so a big garage can't blow the panel
# out. Callers only reach this with a non-empty list (empty is its own RED message).
static func qualifying_cars_text(names: Array) -> String:
	if names.size() <= MAX_QUALIFY_NAMES:
		return ", ".join(names)
	var shown: Array[String] = []
	for i in MAX_QUALIFY_NAMES:
		shown.append(String(names[i]))
	return "%s, +%d more" % [", ".join(shown), names.size() - MAX_QUALIFY_NAMES]


# Stars earned in a rally from the player's best finish: 1st → 3, 2nd → 2, 3rd → 1,
# anything else (or never placed) → 0.
static func stars_for(rally_id: String) -> int:
	return RallyLibrary.stars_for_placement(Save.best_placement(rally_id))
