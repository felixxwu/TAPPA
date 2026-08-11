class_name UpgradesSimple
extends VBoxContainer
# The SIMPLE upgrades page — what every host mounts now. Someone with no car knowledge
# opens it and leaves with a build that is competitive and legal, without learning what a
# supercharger, a ballast or a detune slider is. See todo/simplified-upgrade-menu.md.
#
# Three things and nothing else:
#   1. a stat block in OUTCOMES (Speed / Grip / Condition / Stability), not part names
#   2. Auto-Upgrade — the shared AutoUpgradeRow, two presses to spend
#   3. the per-row WRENCHES into today's page (UpgradesMenu), unchanged, filtered to the
#      category the wrench belongs to — there is no general "Advanced" button any more,
#      because a category IS the way in and a button beside them offering "all of it at
#      once" only invites the player back into the page this one replaced
#
# It exposes the SAME small interface UpgradesMenu does — setup / bind_close_button /
# first_control / request_close / can_close — so the four hosts (HQ lift, start line,
# reward reveal, car-park over-power popup) changed by one word, and the gated-close
# machinery is reused rather than reimplemented. `can_close` delegates to the Advanced
# page's p/w check, or the Simple page would be a way to escape the start line's cap.
#
# ADVANCED IS A CHILD, NOT A SIBLING PAGE. The UpgradesMenu instance is built once and
# hidden, so a round trip back to Simple keeps its scroll and its focus keys, and so
# there is exactly one component doing Save persistence for this car.

const NO_LIMIT := UpgradesMenu.NO_LIMIT

# The speed the Grip row's aero-inclusive figure is rated at. ~two-thirds of what is
# realistically flat out in this game (GameConfig.speed_lines_full_kmh), i.e. a fast
# corner rather than a straight — which is where lateral grip actually decides a stage.
# ALWAYS SHOWN next to the figure: downforce grows with v², so a speed-dependent grip
# number quoted without its speed reads as a promise.
const GRIP_REFERENCE_KMH := 50.0

# Which upgrades belong to which STAT ROW — the categories the wrench buttons open.
# {slots, detune, swap} per row; a row absent from here gets no wrench.
#
# Disjoint on purpose: every slot belongs to exactly one row, so "where do I change this?"
# has one answer. The judgement calls are that the ENGINE DETUNE and the ENGINE SWAP live
# under Speed (both are power levers, and detune is the one that trades power for
# eligibility), and that the WEIGHT slot — ballast and the lightweight kit — lives under
# Lightness rather than Speed even though it moves power-to-weight too. Naming it under
# the row whose figure is literally its own units is the less surprising of the two.
const CATEGORIES := {
	"Speed": {"slots": ["turbo", "nitrous"], "detune": true, "swap": true},
	"Grip": {"slots": ["aero"], "detune": false, "swap": false},
	"Lightness": {"slots": ["weight"], "detune": false, "swap": false},
	"Stability": {"slots": ["drivetrain"], "detune": false, "swap": false},
}

var _owned: Dictionary = {}
var _on_change: Callable = Callable()
var _on_swap: Callable = Callable()
var _pw_limit: float = NO_LIMIT
var _advanced: UpgradesMenu = null
var _advanced_box: VBoxContainer = null
var _advanced_title: Label = null
var _balance_label: Label = null
var _advanced_balance_label: Label = null
var _simple_box: VBoxContainer = null
var _close_button: Button = null
var _on_close: Callable = Callable()


func setup(owned_car: Dictionary, on_change := Callable(), on_swap := Callable(),
		pw_limit := NO_LIMIT) -> void:
	_owned = owned_car
	_on_change = on_change
	_on_swap = on_swap
	_pw_limit = pw_limit
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)
	rebuild()


func rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_simple_box = VBoxContainer.new()
	_simple_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_simple_box.add_theme_constant_override("separation", 4)
	add_child(_simple_box)

	# Advanced is built FIRST, though it is shown last: the stat rows ask it which
	# categories have anything in them before deciding whether to draw a wrench.
	_build_advanced()
	# The page draws its OWN heading, carrying the star balance on the same line
	# (UpgradesMenu.build_title_row). Hosts used to title this overlay themselves, which is
	# how the balance ended up on the HQ lift alone; owning it here means every host shows
	# it, every rebuild re-reads it, and it costs no row of its own — vertical space on this
	# page is the scarcest thing it has.
	var heading := UpgradesMenu.build_title_row("Upgrades")
	_balance_label = heading["label"]
	_simple_box.add_child(heading["row"])
	for row in _stat_rows():
		_simple_box.add_child(row)

	var auto_row := AutoUpgradeRow.new()
	auto_row.setup(int(_owned.get("instance_id", -1)), _pw_limit, _on_auto_applied)
	if auto_row.worth_showing():
		_simple_box.add_child(auto_row)
	else:
		auto_row.free()

	UITheme.enforce(self)
	MenuNav.attach(_simple_box)
	_wire_summary_nav()
	_refresh_close_button()


# Wire up/down explicitly down the summary column: each row's wrench, then the
# Auto-Upgrade button, then Advanced.
#
# NOT left to Godot's geometric neighbour search, because this column is not a column of
# matching shapes — the wrenches are small controls pinned to the RIGHT edge while
# Auto-Upgrade and Advanced span the full width, and the geometric search can decline a
# neighbour whose projection doesn't overlap. TextField.wire_column already encodes the
# "chain these top to bottom" rule (and skips FOCUS_NONE controls, which is why the
# wrenches are built FOCUS_ALL).
func _wire_summary_nav() -> void:
	var column: Array = []
	for row in _simple_box.get_children():
		if row is StatBar:
			for c in (row as StatBar).get_children():
				if c is Button:
					column.append(c)
		elif row is AutoUpgradeRow:
			var first := (row as AutoUpgradeRow).first_control()
			if first != null:
				column.append(first)
		elif row is Button:
			column.append(row)
	# THE HOST'S BACK BUTTON CLOSES THE CHAIN. It is not a child of _simple_box — it lives in the
	# page's action row, outside the body — so neither MenuNav.attach(_simple_box) nor Godot's
	# geometric neighbour search reliably reaches it, and pressing DOWN from the last wrench went
	# nowhere. Appending it here means the column ends where the player expects to leave.
	if _close_button != null and is_instance_valid(_close_button) \
			and _close_button.focus_mode != Control.FOCUS_NONE:
		column.append(_close_button)
	TextField.wire_column(column)


# Build the Advanced page and its box, hidden. Separate from rebuild()'s body only because
# it has to run BEFORE the stat rows, which query it for which categories are non-empty.
func _build_advanced() -> void:
	# Advanced lives in its own box so the Back button survives UpgradesMenu.rebuild(),
	# which frees the menu's own children on every edit.
	_advanced_box = VBoxContainer.new()
	_advanced_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_advanced_box.visible = false
	add_child(_advanced_box)
	# A heading, so a filtered page says which category it is showing rather than looking
	# like the whole page with most of it missing.
	var advanced_heading := UpgradesMenu.build_title_row("Upgrades")
	_advanced_title = advanced_heading["row"].get_child(0) as Label
	_advanced_balance_label = advanced_heading["label"]
	_advanced_box.add_child(advanced_heading["row"])
	_advanced = UpgradesMenu.new()
	_advanced_box.add_child(_advanced)
	# Back inside Advanced returns to the summary rather than leaving the menu. Set BEFORE
	# setup(), which rebuilds and wires it — the page keeps it across its own rebuilds, so
	# nothing has to re-attach MenuNav afterwards (that re-grabs focus; see set_back_action).
	_advanced.set_back_action(_show_simple)
	_advanced.setup(_owned, _on_advanced_change, _on_swap, _pw_limit)
	_advanced_box.add_child(_nav_button("< Back to summary", _show_simple))
	# Re-bind the host's close button to the NEW Advanced instance. rebuild() throws the
	# old one away, and an unbound page paints nothing — which is how an Auto-Upgrade that
	# brought the car back under the cap could leave "OVER LIMIT — REDUCE TO ..." on screen
	# beside a legal figure, with Start still refused.
	if _close_button != null:
		_advanced.bind_close_button(_close_button, _on_close)



# --- The stat block -----------------------------------------------------------

# Each row is an OUTCOME the player already understands, drawn as a SEGMENTED BAR scaled
# against the whole roster (CarStatBounds) rather than against this car. That scale is the
# point: a bar you can compare to every other car tells a player what they are holding,
# where a per-car bar would show every car as full.
#
# Each filled run is split by COLOUR at the car's stock reading: green up to what the car
# shipped with, gold for what the player's upgrades added on top. See StatBar for why that
# split is safe where the old dimmed "headroom" tier was not.
func _stat_rows() -> Array:
	var entry := CarLibrary.by_id(String(_owned.get("model_id", "")))
	var out: Array = []
	if entry.is_empty():
		return out
	var meta := UpgradeLibrary.effective_meta(_owned, entry)
	# The same car with NOTHING fitted — the baseline the gold blocks are measured from.
	# An empty owned-car dict rather than the real one, so every upgrade, the detune and
	# any drivetrain override drop out and what is left is the car as it shipped.
	var stock := UpgradeLibrary.effective_meta({}, entry)

	# SPEED — power-to-weight, the very figure eligibility is judged on, so the bar can
	# never disagree with the gate. Under a host cap the blocks past the limit go red.
	var pw := CarLibrary.power_to_weight_hp_tonne(meta)
	var limit := -1.0
	if _pw_limit >= 0.0:
		limit = CarStatBounds.fraction("pw", roundi(_pw_limit))
	out.append(StatBar.build("Speed",
		CarStatBounds.fraction("pw", pw), "%d hp/t" % pw,
		CarStatBounds.fraction("pw", CarLibrary.power_to_weight_hp_tonne(stock)), limit,
		_wrench_for("Speed")))

	# GRIP — rated WITH aero, which is the only way fitting the aero kit moves this row at
	# all (downforce is purely a speed effect). The reference speed is NOT printed: it is
	# the same for every car and every row, so the comparison is like-for-like either way,
	# and the label was eating the width the blocks want. GRIP_REFERENCE_KMH is the single
	# place it is set, shared with CarStatBounds so the scale and the figure can't diverge.
	var grip := CarLibrary.max_lateral_g(
		UpgradeLibrary.aero_meta(_owned, entry), Config.data, GRIP_REFERENCE_KMH)
	out.append(StatBar.build("Grip", CarStatBounds.fraction("grip", grip), "%.2f G" % grip,
		CarStatBounds.fraction("grip",
			CarLibrary.max_lateral_g(stock, Config.data, GRIP_REFERENCE_KMH)),
		-1.0, _wrench_for("Grip")))

	# LIGHTNESS — inverted mass, so a longer bar is always better on every row of the page.
	# A bar that means "more is worse" on one line and "more is better" on the others is
	# exactly the kind of trap this page exists to remove.
	var mass := float(meta.get("mass", 0.0))
	out.append(StatBar.build("Lightness",
		1.0 - CarStatBounds.fraction("mass", mass), "%d kg" % roundi(mass),
		1.0 - CarStatBounds.fraction("mass", float(stock.get("mass", mass))),
		-1.0, _wrench_for("Lightness")))

	# CONDITION is deliberately SELF-relative (this car against its own max HP) — comparing
	# damage across the roster would say nothing useful — so it gets no roster scale, just
	# its own percentage. No stock baseline either: every car leaves the showroom at 100%,
	# so a gold tier here would only ever mean "damaged", which is not what gold says.
	var max_hp := float(entry.get("max_hp", 0.0))
	var hp := float(_owned.get("hp", 0.0))
	if max_hp > 0.0:
		var frac := clampf(hp / max_hp, 0.0, 1.0)
		out.append(StatBar.build("Condition", frac,
			"Wrecked" if hp <= 0.0 else "%d%%" % roundi(frac * 100.0)))

	# STABILITY — a bar too, with the word riding alongside it as the figure. The bar is an
	# INDEX, not a measurement (see _stability_index), and it is already 0..1 by
	# construction, so unlike the rows above it needs no roster scale: every car is scored
	# on the same two axes. Its stock baseline is what makes a fitted DRIVETRAIN KIT visible
	# — swapping to AWD is the one upgrade that moves this row.
	out.append(StatBar.build("Stability", _stability_index(meta), _stability_word(meta),
		_stability_index(stock), -1.0, _wrench_for("Stability")))
	return out


# A 0..1 stability INDEX — deliberately an index rather than a measured quantity, because
# stability has no single honest scalar: it is a blend of how much the drivetrain forgives
# (AWD pulls a car straight, RWD lets the back step out) and how close to balanced the
# weight sits. Half the score comes from each, so neither can dominate.
#
# The WORD is still shown beside it, since "Forgiving" is what a newcomer can act on; the
# bar is there so the two cars they are choosing between can be compared at a glance.
func _stability_index(meta: Dictionary) -> float:
	var drive := int(meta.get("drive_mode", -1))
	var drive_term := 0.5
	if drive == CarLibrary.AWD:
		drive_term = 1.0
	elif drive == CarLibrary.FWD:
		drive_term = 0.65
	elif drive == CarLibrary.RWD:
		drive_term = 0.3
	# 1.0 at a 50/50 split, falling to 0 at either extreme.
	var front := clampf(float(meta.get("weight_front", 0.5)), 0.0, 1.0)
	var balance_term := 1.0 - absf(front - 0.5) / 0.5
	return clampf(drive_term * 0.5 + balance_term * 0.5, 0.0, 1.0)


# Stability quietly answers the one thing FWD/RWD/AWD never told a newcomer: which of them
# is the forgiving one.
func _stability_word(meta: Dictionary) -> String:
	var drive := int(meta.get("drive_mode", -1))
	var front := clampf(float(meta.get("weight_front", 0.5)), 0.0, 1.0)
	if drive == CarLibrary.AWD:
		return "Forgiving"
	if drive == CarLibrary.RWD and front < 0.5:
		return "Twitchy"
	return "Balanced"


# A plain key/value line, for the one stat that isn't a bar.
func _stat_row(label: String, value: String) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var key := UITheme.label(label)
	key.custom_minimum_size = Vector2(StatBar.LABEL_MIN_W, 0.0)
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(key)
	var val := UITheme.label(value)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	return row


# --- Simple <-> Advanced ------------------------------------------------------

# A row's wrench, or an unset Callable for a row with no upgrades behind it (Condition —
# nothing in the catalogue repairs damage, so a wrench there would open an empty page).
func _wrench_for(category: String) -> Callable:
	if not CATEGORIES.has(category) or _advanced == null:
		return Callable()
	var rule: Dictionary = CATEGORIES[category]
	# Nothing to open, no wrench. A category can be empty for a whole career — the
	# drivetrain row shows nothing until the swap kit is owned — and a wrench leading to a
	# blank page is worse than no wrench at all.
	if not _advanced.has_rows_for(rule["slots"],
			bool(rule.get("detune", false)), bool(rule.get("swap", false))):
		return Callable()
	return _show_advanced.bind(category)


# Open the Advanced page. With no category it is the whole page (the Advanced button);
# with one it is narrowed to that row's own upgrades, which is what makes the summary a
# category INDEX rather than just a readout — each bar is the handle for the thing it
# measures.
func _show_advanced(category := "") -> void:
	var rule: Dictionary = CATEGORIES.get(category, {})
	_advanced.set_filter(rule.get("slots", []),
		bool(rule.get("detune", true)), bool(rule.get("swap", true)))
	_advanced.rebuild()
	_advanced_title.text = UITheme.caps(category if category != "" else "Upgrades")
	# Re-read the balance: the summary's own heading refreshes on rebuild, but stepping
	# INTO a category doesn't rebuild, and a purchase made in the last category would
	# otherwise leave a stale number over this one.
	if is_instance_valid(_advanced_balance_label):
		_advanced_balance_label.text = "%d" % Save.stars_available()
	_simple_box.visible = false
	_advanced_box.visible = true
	UITheme.focus_grab(_advanced.first_control())


func _show_simple() -> void:
	# The Advanced page may have changed the build; the stat block has to catch up, and
	# the Auto row's plan with it.
	_resync_owned()
	rebuild()
	UITheme.focus_grab(first_control())


# Re-read the car after an edit. A car that isn't in the save (a synthetic owned-car dict,
# as the component tests and the reward reveal's preview use) keeps the dict it was handed
# rather than being blanked to {}.
func _resync_owned() -> void:
	var fresh := Save.get_car(int(_owned.get("instance_id", -1)))
	if not fresh.is_empty():
		_owned = fresh


func _nav_button(text: String, on_press: Callable) -> Button:
	# FOCUS_ALL by hand: UITheme.button sets FOCUS_NONE, which would make this page
	# pointer-only (features/menus.md → Menu navigation).
	var b := Button.new()
	b.text = UITheme.caps(text)
	b.focus_mode = Control.FOCUS_ALL
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(on_press)
	return b


func _on_auto_applied() -> void:
	_resync_owned()
	rebuild()
	if _on_change.is_valid():
		_on_change.call()


func _on_advanced_change() -> void:
	_resync_owned()
	_refresh_close_button()
	if _on_change.is_valid():
		_on_change.call()


# --- The host interface (identical to UpgradesMenu's) -------------------------

# The Advanced page this Simple page wraps. Public because the p/w gate, the detune
# slider and the per-slot rows all still live there — Simple owns the summary, not the
# machinery.
func advanced() -> UpgradesMenu:
	return _advanced


# The balance row's digits (test readout; "" before the first rebuild).
func balance_text() -> String:
	return _balance_label.text if is_instance_valid(_balance_label) else ""


func first_control() -> Control:
	return UITheme.first_focusable(_simple_box if _simple_box != null else self)


func bind_close_button(button: Button, on_close: Callable) -> void:
	_close_button = button
	_on_close = on_close
	if not button.pressed.is_connected(request_close):
		button.pressed.connect(request_close)
	# The Advanced page owns the p/w gate's painting; hand it the same button so the two
	# pages can never disagree about whether the player may leave.
	if _advanced != null:
		_advanced.bind_close_button(button, on_close)
	# The column is wired during rebuild(), which may have run BEFORE the host bound its button — so
	# re-wire now that there is something to chain to.
	if _simple_box != null:
		_wire_summary_nav()
	_refresh_close_button()


func request_close() -> void:
	if can_close() and _on_close.is_valid():
		_on_close.call()


# Delegated, not re-derived: a Simple page with its own opinion of the cap would be a way
# to walk out of the start line still over it.
func can_close() -> bool:
	return _advanced == null or _advanced.can_close()


func over_pw_limit() -> bool:
	return _advanced != null and _advanced.over_pw_limit()


func _refresh_close_button() -> void:
	if _advanced != null and _close_button != null:
		_advanced._refresh_close_button()
