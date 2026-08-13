class_name AutoUpgradeRow
extends VBoxContainer
# One button that fits the best build a car can afford, plus a line saying what it would
# do. The player-facing half of UpgradeLibrary.auto_build_plan — the solver owns the rule,
# this owns the two presses and the words.
#
# Shared by the Simple upgrades page and the Advanced one (UpgradesMenu) rather than
# written twice: "what does Auto do" is one answer, and a second copy is how the two pages
# start disagreeing about it. See todo/simplified-upgrade-menu.md §3b.
#
# TWO PRESSES, ALWAYS, and the preview is a MODAL rather than a line under the button.
# Pressing opens a confirm popup naming the parts, the cost and the before → after p/w;
# confirming there commits. Auto spends stars irreversibly, and the page it replaces gave
# no preview at all — press, two stars gone, and the only visible change was one slider
# label. The popup rather than an inline summary because the row sits in a stat block the
# player is reading at a glance: a paragraph that appears under one button pushes the
# whole page around and is easy to press straight past.

var _instance_id := -1
var _pw_limit := UpgradesMenu.NO_LIMIT
var _on_applied: Callable = Callable()
var _button: Button


# `pw_limit` is the host's power-to-weight ceiling (UpgradesMenu.NO_LIMIT for none);
# `on_applied` runs after a commit so the host can re-field the car and refresh itself.
func setup(instance_id: int, pw_limit := UpgradesMenu.NO_LIMIT, on_applied := Callable()) -> void:
	_instance_id = instance_id
	_pw_limit = pw_limit
	_on_applied = on_applied
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 2)
	rebuild()


# Whether this row has anything to offer at all.
#
# ONLY UNDER A TARGET. Auto exists to answer "make this car legal for THIS event", so it
# appears at the start line, the car-park over-power prompt and the reward reveal — the
# hosts that pass a power-to-weight ceiling — and never on the HQ lift, which has no event
# in mind. Without a target the only objective left is "spend everything on power", which
# is a decision the player should be making deliberately on the Advanced page, not one a
# button should make for them the moment they walk into the garage.
#
# And then only when it would actually do something: a permanently dead control is exactly
# the "when do I get this?" prompt the rest of the menu already hides locked options to
# avoid.
func worth_showing() -> bool:
	if _instance_id < 0 or _pw_limit < 0.0:
		return false
	return bool(_plan_now().get("changed", false))


func rebuild() -> void:
	for c in get_children():
		c.queue_free()
	if _instance_id < 0:
		return
	var plan := _plan_now()
	var actionable := bool(plan.get("changed", false))
	var cost := int(plan.get("cost", 0))
	var label := "Auto-Upgrade" if actionable else "Auto-Upgrade — nothing to add"
	# Built by hand rather than via UITheme.button: that helper sets FOCUS_NONE, which
	# would leave this row reachable by pointer only — and every menu here has to answer to
	# keyboard and gamepad (features/menus.md → Menu navigation).
	_button = Button.new()
	_button.text = UITheme.caps(label if cost <= 0 else "%s — %d" % [label, cost])
	_button.focus_mode = Control.FOCUS_ALL
	_button.pressed.connect(_on_pressed)
	_button.disabled = not actionable
	_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button.set_meta("upgrade_focus_key", "auto_upgrade")
	if actionable and cost > 0:
		_button.icon = StarRow.price_icon()
	add_child(_button)


func first_control() -> Control:
	return _button


# The plan for this car under whatever cap the host set. The solver owns the rule; this
# only translates the host's bare p/w ceiling into the restriction shape it takes.
func _plan_now() -> Dictionary:
	var car := Save.get_car(_instance_id)
	if car.is_empty():
		return {}
	var restriction := {} if _pw_limit < 0.0 else {"pw_max": _pw_limit}
	return UpgradeLibrary.auto_build_plan(car, CarLibrary.for_owned(car),
		Save.profile, Save.stars_available(), restriction)


# Press: show what Auto would do and ask. Nothing is spent until the popup is confirmed,
# and the plan is RE-COMPUTED at that point rather than trusted from the preview, so stars
# spent elsewhere while the popup was up can't let a stale plan overdraw the balance.
func _on_pressed() -> void:
	var plan := _plan_now()
	if not bool(plan.get("changed", false)):
		return
	ConfirmPopup.open(self, "Auto-Upgrade", _summary(plan), [
		{"label": "Cancel", "callback": Callable()},
		{"label": _confirm_label(plan), "callback": _commit},
	], 1, 0)


func _confirm_label(plan: Dictionary) -> String:
	var cost := int(plan.get("cost", 0))
	return "Do it" if cost <= 0 else "Buy — %d stars" % cost


# The popup's confirm action.
func _commit() -> void:
	var applied := Save.apply_build_plan(_instance_id, _plan_now())
	rebuild()
	if applied and _on_applied.is_valid():
		_on_applied.call()


# What Auto would do, in outcome words — the popup body, and the preview the two-press
# rule exists to give. Part NAMES are named for the buys (a star spend deserves to say
# what it bought) but the free half is described by outcome, since "fits parts you already
# own" is the sentence a player who doesn't know what a supercharger is can act on.
func _summary(plan: Dictionary) -> String:
	if not bool(plan.get("changed", false)):
		var blocked := String(plan.get("blocked", ""))
		return blocked if blocked != "" else "This car is already running its best build."
	var car := Save.get_car(_instance_id)
	var entry := CarLibrary.for_owned(car)
	var before := CarLibrary.power_to_weight_hp_tonne(UpgradeLibrary.effective_meta(car, entry))
	var after := CarLibrary.power_to_weight_hp_tonne(
		UpgradeLibrary.effective_meta(_previewed_car(car, plan), entry))
	var parts: Array = []
	for item_id in plan.get("buy", []):
		parts.append(String(UpgradeLibrary.by_id(item_id).get("name", item_id)))
	var bits: Array = []
	if not parts.is_empty():
		bits.append("Buys %s" % ", ".join(parts))
	if not (plan.get("enable", []) as Array).is_empty():
		bits.append("fits parts you already own")
	if not (plan.get("strip", []) as Array).is_empty():
		bits.append("removes what is holding it back")
	bits.append("%d to %d hp/t" % [before, after])
	return "%s." % ". ".join(bits)


# The car as the previewed plan would leave it, for the before → after figure. A pure
# projection — the save is not touched until the popup is confirmed.
func _previewed_car(car: Dictionary, plan: Dictionary) -> Dictionary:
	var out := car.duplicate(true)
	var installed: Array = (out.get("installed_upgrades", []) as Array).duplicate()
	var disabled: Array = (out.get("disabled_upgrades", []) as Array).duplicate()
	for item_id in plan.get("buy", []):
		installed.append(item_id)
	for item_id in (plan.get("buy", []) as Array) + (plan.get("enable", []) as Array):
		disabled.erase(item_id)
	for item_id in plan.get("strip", []):
		if not disabled.has(item_id):
			disabled.append(item_id)
	out["installed_upgrades"] = installed
	out["disabled_upgrades"] = disabled
	out["tuning"] = {"engine_detune": float(plan.get("detune", 1.0))}
	return out
