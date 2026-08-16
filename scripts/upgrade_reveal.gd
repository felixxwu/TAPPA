extends Control
class_name UpgradeReveal
# A self-contained reward card: a slot-machine spin that lands on a won upgrade,
# then an Upgrades/Next action row — normal parts are granted fitted-disabled to
# the driven car and enabled later in the upgrades menu (no Apply/Keep here); Next
# continues past the card, Upgrades opens the same real UpgradesGrid component the
# pre-stage start line / HQ garage use (features/upgrade-catalogue.md) so the player
# can slot the just-won part right away, gated by the same rally p/w-limit warning.
# Consumables and the drivetrain kit skip straight to the Upgrades/Next row. Emits
# `finished` once the reveal (or Next/Upgrades-done) resolves. Used by the standings interstitial;
# visually matches the podium reward card (features/menus.md,
# features/reward-system.md). A "Skip >" button appears only while the reel is
# actually animating (real play, non-zero spin time) and fast-forwards straight
# to the actual won item — see _on_skip_pressed.

signal finished()

var _car_instance_id := -1
var _reveal_done := false
var _headless := false
var _slot_tween: Tween

var _slot_label: Label
var _slot_caption: Label
var _skip_button: Button
# Shown once the reveal lands (e.g. "Install it at the
# next stage"): Upgrades jumps straight into the real garage upgrades menu so the
# player can slot the just-won part immediately; Next continues exactly as the bare
# `finished.emit()` used to. See _show_actions / _on_upgrades_pressed.
var _action_box: HBoxContainer
var _upgrades_button: Button
var _next_button: Button
var _upgrades_menu: UpgradesGrid
var _upgrades_overlay: CanvasLayer
var _upgrades_back: Button
# The spin target + landing callback, stashed so a skip can run the SAME landing
# steps a natural finish would (see _on_skip_pressed) — the result is always the
# actual won item, never a random reel stop.
var _spin_target := ""
var _spin_on_done: Callable


func _ready() -> void:
	_headless = Platform.is_headless()
	_build_ui()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Anchor the reward card to the bottom of the screen so it doesn't block the
	# view of the car in the replay behind it. A full-rect VBox aligned to the end
	# drops the (shrink-centred) panel to the bottom, with a margin off the edge.
	# Kept small: this Control fills the space ABOVE the host's Continue/Next
	# button (standings.gd stacks one right below it with its own separation), so
	# this margin is the only gap between the card and that button — a large value
	# here reads as a big dead gap, not screen-edge breathing room.
	var bottom := VBoxContainer.new()
	bottom.set_anchors_preset(Control.PRESET_FULL_RECT)
	bottom.alignment = BoxContainer.ALIGNMENT_END
	bottom.add_theme_constant_override("separation", 0)
	add_child(bottom)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_bottom", 12)
	bottom.add_child(margin)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.add_theme_stylebox_override("panel", UITheme.reward_card_box())
	margin.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	_slot_label = Label.new()
	_slot_label.add_theme_font_size_override("font_size", 40)
	_slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slot_label.custom_minimum_size = Vector2(_card_width(), 0)
	# Wrap at the card width so a long part name doesn't stretch the card off-screen.
	_slot_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_slot_label)

	_slot_caption = Label.new()
	_slot_caption.add_theme_font_size_override("font_size", 16)
	_slot_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slot_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_slot_caption)

	# Fast-forward for impatient players: visible only while the reel is actually
	# spinning (headless / zero spin-time reveals resolve instantly and never show
	# it — see _start_slot). Lands on the real won item, not a random reel stop.
	_skip_button = Button.new()
	_skip_button.focus_mode = Control.FOCUS_ALL
	_skip_button.text = "Skip >"
	_skip_button.visible = false
	_skip_button.pressed.connect(_on_skip_pressed)
	col.add_child(_skip_button)

	# The Upgrades/Next action row, shown once the reveal has landed. (There is no
	# Apply/Keep choice box any more — the won-repair-kit offer it existed for is gone
	# along with repair kits themselves; see _offer_choice.)
	_action_box = HBoxContainer.new()
	_action_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_action_box.add_theme_constant_override("separation", 12)
	_action_box.visible = false
	col.add_child(_action_box)
	_upgrades_button = Button.new()
	_upgrades_button.focus_mode = Control.FOCUS_ALL
	_upgrades_button.text = "Upgrades"
	_upgrades_button.pressed.connect(_on_upgrades_pressed)
	_action_box.add_child(_upgrades_button)
	_next_button = Button.new()
	_next_button.focus_mode = Control.FOCUS_ALL
	_next_button.text = "Next"
	_next_button.pressed.connect(_on_next_pressed)
	_action_box.add_child(_next_button)

	UITheme.enforce(self)


# The reveal card's content width: the 520px design width, shrunk on narrow
# viewports (`viewport_width`) so the card (plus panel padding/border) never
# overflows the screen. Shared with the podium's car-reveal card. Pure.
static func card_width(viewport_width: float) -> float:
	return minf(520.0, viewport_width * 0.8)


func _card_width() -> float:
	return card_width(get_viewport().get_visible_rect().size.x)


# Public entry: spin to the won item, then offer (or auto-resolve) the choice.
func reveal(item_id: String, car_instance_id: int) -> void:
	_car_instance_id = car_instance_id
	var target := String(UpgradeLibrary.by_id(item_id).get("name", item_id))
	_start_slot(Registry.names(UpgradeLibrary.UPGRADES), target, func() -> void: _offer_choice(item_id, target))


# Drive `label` (owned by `host`) through a slot-machine spin over `reel_names`,
# decelerating to a stop on `target`, then run `on_done`. Returns the running Tween,
# or null when it resolves instantly (headless / non-positive `spin_time` / empty
# reel) so tests step straight through. Shared with the podium's car-reveal. Pure
# apart from mutating `label` + driving the returned tween.
static func start_spin(host: Node, label: Label, reel_names: Array, target: String,
		spin_time: float, headless: bool, on_done: Callable) -> Tween:
	if headless or spin_time <= 0.0 or reel_names.is_empty():
		label.text = UITheme.caps(target)
		if on_done.is_valid():
			on_done.call()
		return null
	var reel := build_reel(reel_names, target)
	var tween := host.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_method(
		func(p: float) -> void:
			var i := clampi(int(round(p)), 0, reel.size() - 1)
			label.text = UITheme.caps(String(reel[i])),
		0.0, float(reel.size() - 1), spin_time)
	tween.tween_callback(func() -> void:
		label.text = UITheme.caps(target)
		if on_done.is_valid():
			on_done.call())
	return tween


# A reel that cycles the candidate names a few times and ends on the target, so the
# tween that walks it slows to a stop on the won item. Pure.
static func build_reel(names: Array, target: String) -> Array:
	var reel: Array = []
	var count := maxi(14, names.size() * 3)
	for i in count:
		reel.append(String(names[i % names.size()]))
	reel.append(target)
	return reel


# Spin to the won item, then run `on_done`. Wraps the shared `start_spin` with this
# card's reveal-done gate and tween bookkeeping.
func _start_slot(reel_names: Array, target: String, on_done: Callable) -> void:
	_reveal_done = false
	_slot_caption.text = ""
	_spin_target = target
	_spin_on_done = on_done
	if _slot_tween != null and _slot_tween.is_valid():
		_slot_tween.kill()
	_slot_tween = start_spin(self, _slot_label, reel_names, target,
		Config.data.podium_slot_spin_time, _headless, func() -> void:
			_reveal_done = true
			_skip_button.visible = false
			on_done.call())
	# start_spin returns null (and resolves synchronously) when headless or the
	# configured spin time is non-positive — no running animation to skip, so the
	# button only appears for a real, currently-spinning tween.
	_skip_button.visible = _slot_tween != null
	if _skip_button.visible:
		# Framework: focus + WASD/arrow/gamepad nav onto Skip (no on_back — the host
		# owns back). Re-attach is cheap.
		MenuNav.attach(self, {first = _skip_button})


# The won part is already fitted (disabled) to the driven car; the reveal just
# reports that and emits `finished` — no Apply/Keep, the player enables it later
# in the garage. Consumables just land in inventory, and the drivetrain kit installs
# enabled (its FWD/RWD/AWD selection is made later in the garage).
func _offer_choice(item_id: String, item_name: String) -> void:
	var driven := Save.get_car(_car_instance_id)
	# NO REPAIR CHOICE. This used to intercept a won REPAIR KIT and offer to spend it
	# on the just-driven car ("Repair now" / "Save it"). Repair kits no longer exist —
	# damage is one-way apart from the free between-event field repair — so every won
	# consumable now falls straight through to the plain "added to your inventory"
	# path below. See features/damage.md.
	if driven.is_empty() or UpgradeLibrary.slot_of(item_id) == "" or UpgradeLibrary.is_consumable(item_id):
		_slot_caption.text = UITheme.caps("%s — added to your inventory" % item_name)
		_show_actions()
		return
	if UpgradeLibrary.slot_of(item_id) == "drivetrain":
		Save.set_upgrade_enabled(_car_instance_id, item_id, true)
		_slot_caption.text = UITheme.caps("Pick a drive mode in the garage")
		_show_actions()
		return
	# Normal slottable part: grant it to the garage (already fitted-disabled by
	# rally_session) and let the player install it later in the upgrades menu, or
	# right now via the Upgrades button below — no caption needed here, the reel
	# above already names the won part and the Upgrades/Next row says what's next.
	_show_actions()


# Fast-forwards a running spin straight to the landed result — impatient players
# don't have to sit through the full slot-machine animation. Kills the tween and
# runs the exact landing steps a natural finish would (set the label to the
# target + call the stashed on_done), so skipping always lands on the actual
# won item and every downstream choice/finish path behaves identically to letting
# it play out.
func _on_skip_pressed() -> void:
	if _slot_tween == null or not _slot_tween.is_valid():
		return
	_slot_tween.kill()
	_slot_label.text = UITheme.caps(_spin_target)
	_reveal_done = true
	_skip_button.visible = false
	if _spin_on_done.is_valid():
		_spin_on_done.call()


# Show the Upgrades/Next action row: hop into the real Upgrades menu right now, or
# move on. Shown in place of an immediate `finished.emit()` once the reveal lands.
func _show_actions() -> void:
	_action_box.visible = true
	UITheme.enforce(self)
	# Framework: focus + WASD/arrow/gamepad nav across Upgrades/Next (no on_back — the
	# host owns back). Seats the cursor on Next so a repeated confirm-press continues
	# past the reveal instead of landing on Upgrades.
	MenuNav.attach(self, {first = _next_button})


# Next: continue past the reveal exactly as the bare `finished.emit()` used to.
func _on_next_pressed() -> void:
	finished.emit()


# Upgrades: open the SAME UpgradesGrid component the pre-stage start line / HQ garage
# use (features/upgrade-catalogue.md), fed the driven car + the active rally's p/w
# ceiling so the over-limit warning (UpgradesGrid.bind_close_button/request_close)
# behaves identically to the pre-stage usage — no bespoke warning logic here.
func _on_upgrades_pressed() -> void:
	if _upgrades_overlay == null:
		_build_upgrades_overlay()
	var owned: Dictionary = Save.get_car(_car_instance_id)
	# One accessor for the ceiling, so a CHALLENGE run's cap applies here too. This
	# used to read RallySession.rally_id()'s restriction directly, which resolves to
	# "no limit" mid-challenge (rally_id() is "") — the reveal's Upgrades overlay had
	# no performance gate at all for a challenge car.
	var rating_limit := DrivingContext.rating_limit_for_car(_car_instance_id)
	_upgrades_menu.setup(owned, Callable(), Callable(), rating_limit)
	_upgrades_menu.bind_close_button(_upgrades_back, _close_upgrades)
	_upgrades_overlay.visible = true
	get_viewport().gui_release_focus()
	MenuNav.attach(_upgrades_overlay.get_child(0), {
		"first": _upgrades_menu.first_control(),
		"on_back": _upgrades_menu.request_close,
	})


# Done (or back) in the Upgrades overlay: only reachable once UpgradesGrid.can_close()
# is satisfied (the same p/w gate as the pre-stage popup). Hide the overlay and
# continue exactly as Next would — the player is never stuck once they're done editing.
func _close_upgrades() -> void:
	_upgrades_overlay.visible = false
	_on_next_pressed()


# Build the Upgrades overlay once: same CanvasLayer-over-CenterContainer-over-panel
# shape as start_line._build_menu_overlay / hq's upgrades popup, just built locally
# since this card doesn't have a shared host overlay builder to call into.
func _build_upgrades_overlay() -> void:
	_upgrades_menu = UpgradesGrid.new()
	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := UITheme.panel(UITheme.PANEL.a)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UITheme.GAP)
	col.custom_minimum_size = Vector2(380.0, 0)
	panel.add_child(col)
	# No title here: UpgradesGrid draws its own heading, which is what carries the star
	# balance (UpgradesGrid.build_title_row).
	col.add_child(_upgrades_menu)
	_upgrades_back = UITheme.button("Done")
	_upgrades_back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(_upgrades_back)
	UITheme.enforce(layer)
	_upgrades_overlay = layer
