extends RefCounted
class_name UpgradeOptions

# What a single upgrade SLOT offers a given car, as pure data — no UI.
#
# The grid tile needs to render one line ("turbo: Small") and the popup needs the whole
# list, so both ask this rather than each walking UpgradeLibrary with its own idea of
# what counts as available. Keeping it here also means the buy / gate / prerequisite
# rules exist once: those are the rules that decide whether a press spends stars, and
# duplicating them is how a menu ends up offering something the save then refuses.
#
# See features/upgrade-catalogue.md.

# A slot the grid shows that is NOT an UpgradeLibrary slot. Both are real choices the
# player makes about the car, so they get tiles like everything else rather than being
# special-cased into their own rows — see features/menus.md.
const SLOT_ENGINE := "engine"
const SLOT_TUNE := "tune"

# Grid order. The seven catalogue slots keep UpgradeLibrary.SLOTS' order (which is also
# the order _best_part_per_slot reports in), then the two pseudo-slots.
static func grid_slots() -> Array[String]:
	var out: Array[String] = []
	for slot in UpgradeLibrary.SLOTS:
		out.append(String(slot))
	out.append(SLOT_ENGINE)
	out.append(SLOT_TUNE)
	return out


# Every option in `slot` for `owned_car`, in the order the popup should list them.
#
# Each entry: {
#   id: String,          # part id, "" for Stock, or a mode/engine id for the pseudo-slots
#   label: String,       # what the popup line reads
#   current: bool,       # this is what the car is running now
#   selectable: bool,    # can be picked right now (false => greyed, focus skips it)
#   price: int,          # stars to buy, -1 when it is not a purchase
#   locked_reason: String # why it is greyed, "" when selectable
# }
#
# NOT included: the rating each option would give the car. It is a simulated benchmark
# lap (CarPerformance.rating), and this function is on the GRID's hot path — every tile
# calls it through current_label and has_choice on every rebuild, so stamping a rating on
# each row here would make opening the garage pay for ~30 sims before drawing anything.
# The popup asks for them one row at a time instead, via rating_with below.
static func options_for(owned_car: Dictionary, slot: String) -> Array[Dictionary]:
	match slot:
		# Neither pseudo-slot is a list of options:
		#   engine — a swap TRADES engines with another car you own, so the tile hands
		#            off to the car picker rather than offering the catalogue.
		#            Listing every engine implied you could simply fit one, which is not a
		#            thing the game lets you do.
		#   tune   — continuous, so it opens a slider.
		SLOT_ENGINE, SLOT_TUNE: return []
		"drivetrain": return _drivetrain_options(owned_car)
		_: return _part_options(owned_car, slot)


# What a grid tile calls this slot. Short by design: a tile is one square of a 3-across
# grid on a phone, and the label must fit ONE line — it does not wrap, because a wrapped
# tile is a taller tile and a grid of uneven rows stops reading as a grid. The full slot
# name still names the popup's subject via the tile the player just pressed.
const _TILE_SLOT_NAMES := {
	"drivetrain": "drive",
	"nitrous": "nos",
	"gearbox": "gears",
}

static func tile_slot_name(slot: String) -> String:
	return String(_TILE_SLOT_NAMES.get(slot, slot))


# One line at the top of a slot's picker saying what the slot actually DOES, written for a
# player who knows nothing about cars (features/upgrade-catalogue.md).
#
# The picker deliberately has no title — the tile the player just pressed already names the
# slot, and a heading repeating "TURBO" over a list of turbos is a line of nothing. This is
# the opposite: it is the line that tells someone who has never heard of a limited-slip
# differential why they might want one. It is what earns the space a bare title would waste.
#
# House rules that shaped the copy: every label in the game renders UPPERCASE
# (UITheme.enforce), which is tiring to read in long sentences, and the panel is only 300px
# wide. So each entry is two short sentences at most — what it is, then what it does for
# you — and avoids jargon rather than explaining it.
const _SLOT_DESCRIPTIONS := {
	"turbo": "Forces more air into the engine for extra power. Turbos surge once spinning; superchargers pull from low revs.",
	"gearbox": "How fast the car changes gear. Quicker shifts lose less speed.",
	"aero": "Wings that press the car onto the road at speed. More grip in fast corners.",
	"tires": "The rubber you drive on. The biggest single change to grip.",
	"weight": "How heavy the car is. Lighter turns, stops and accelerates better.",
	"drivetrain": "Which wheels get the power. Front is stable, rear slides, all-wheel grips best on loose ground.",
	"nitrous": "A gas bottle for a short burst of power. Refills at every stage start.",
	SLOT_TUNE: "Turns engine power down on purpose. Use it to get under a rally's power limit.",
}


# The description for `slot`, or "" for a slot with none — the popup then simply draws no
# description row rather than an empty gap, so an unlisted slot degrades quietly.
static func slot_description(slot: String) -> String:
	return String(_SLOT_DESCRIPTIONS.get(slot, ""))


# The one-line value the grid tile shows after the slot name — "Small", "Stock", "V8".
static func current_label(owned_car: Dictionary, slot: String) -> String:
	if slot == SLOT_TUNE:
		return "%d%%" % roundi(_detune_of(owned_car) * 100.0)
	if slot == SLOT_ENGINE:
		return _layout_short(String(EngineLibrary.by_id(
			EngineSwap.current_engine_id(owned_car,
				String(CarLibrary.for_owned(owned_car).get("engine", "")))).get("layout", "")))
	for opt in options_for(owned_car, slot):
		if bool(opt.get("current", false)):
			# `tile_label` when an option carries one: the popup can afford a qualifier the
			# tile cannot. Drivetrain's "(Stock)" marker tells you which layout the car was
			# built with, which is worth a line in the list and eight wasted characters on a
			# tile that has to fit three across a phone.
			return String(opt.get("tile_label", opt.get("label", "")))
	return "Stock"


static func _detune_of(owned_car: Dictionary) -> float:
	return clampf(float(owned_car.get("tuning", {}).get("engine_detune", 1.0)), 0.0, 1.0)


# Whether pressing this slot's tile would give the player an actual choice.
#
# False when the ONLY thing they could pick is the state the slot is already in — a turbo
# slot whose one turbo is still locked behind a rally offers "Stock" and a greyed line, so
# opening it teaches nothing and costs a press to back out of. The tile greys instead, and
# the locked ladder is still readable from the popup of any slot that does open.
#
# Tune is always a choice (it is a continuous slider). Engine has its own rules — a swap
# needs the capability unlocked and a partner car, see engine_swap_blocked_reason.
static func has_choice(owned_car: Dictionary, slot: String) -> bool:
	if slot == SLOT_TUNE:
		return true
	if slot == SLOT_ENGINE:
		return engine_swap_blocked_reason(owned_car) == ""
	for opt in options_for(owned_car, slot):
		# A choice means somewhere ELSE the car could go: an option that is selectable AND
		# is not the one already fitted.
		#
		# Testing "is it current" rather than "is it Stock" matters for drivetrain, whose
		# options are drive MODES ("0"/"1"/"2") with no empty-id Stock entry. Keying on the
		# id left a locked drivetrain slot looking choosable, because the car's own layout is
		# always selectable — you can always revert to it, but reverting to where you already
		# are is not a decision.
		if bool(opt.get("selectable", false)) and not bool(opt.get("current", false)):
			return true
	return false


# --- Catalogue slots ---------------------------------------------------------

static func _part_options(owned_car: Dictionary, slot: String) -> Array[Dictionary]:
	var installed: Array = owned_car.get("installed_upgrades", [])
	var instance_id := int(owned_car.get("instance_id", -1))
	var out: Array[Dictionary] = []
	# Stock is always first and always available: it is the "off" state, and without it a
	# fitted part could never be taken back off from this screen.
	out.append({
		"id": "", "label": "Stock", "current": _slot_current_id(owned_car, slot) == "",
		"selectable": true, "price": -1, "locked_reason": "",
	})
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) != slot or bool(def.get("consumable", false)):
			continue
		var pid := String(def.get("id", ""))
		var label := _option_label(owned_car, slot, def, pid)
		var tile := _option_tile_label(owned_car, slot, def)
		if installed.has(pid):
			var row := {
				"id": pid, "label": label, "current": UpgradeLibrary.is_enabled(owned_car, pid),
				"selectable": true, "price": -1, "locked_reason": "",
			}
			if tile != "":
				row["tile_label"] = tile
			out.append(row)
			continue
		# Not on this car. A FREE part (ballast) is fitted on the spot; anything else is a
		# purchase. Either way it is listed even when it cannot be taken yet — greyed with
		# the reason — so the slot shows its whole ladder.
		#
		# NOTE this deliberately reverses the older behaviour, which omitted parts the
		# player had not yet unlocked on the grounds that the MAP answers "when do I get
		# the big turbo?" by standing the part on the rally that awards it. Showing the
		# ladder here trades that for legibility inside one screen.
		var reason := _lock_reason(owned_car, instance_id, pid)
		var free := UpgradeLibrary.is_free(pid)
		var row := {
			"id": pid, "label": label, "current": false,
			"selectable": reason == "",
			"price": -1 if free else Save.part_price(pid),
			"locked_reason": reason,
		}
		if tile != "":
			row["tile_label"] = tile
		out.append(row)
	return out


# The WEIGHT slot, whose parts are named. Every other slot reads its label off the part.
const SLOT_WEIGHT := "weight"


# What one part's row reads. Normally the part's own `menu_label` / `name`.
#
# THE WEIGHT SLOT IS THE EXCEPTION: its parts are named "Heavy Ballast" / "Light Ballast" /
# "Weight Reduction", which is three words for a slot that is really one number, on a tile
# that has to fit three across a phone. What the player is choosing between is how much
# mass to add or shed, so the row states exactly that and nothing else — "+240", "-190".
#
# The kilos are DERIVED, not authored: these parts carry a mass MULTIPLIER (`mass_mult`), so
# the same ballast is a different number of kilos on a light car than on a heavy one, and
# quoting the multiplier would make the player do the arithmetic. Measured against the car
# with the slot EMPTY (build_with ... "") rather than against its current mass, so swapping
# one ballast for another reports what the new part weighs rather than the difference
# between the two.
static func _option_label(owned_car: Dictionary, slot: String, def: Dictionary,
		pid: String) -> String:
	var bare := _weight_delta_label(owned_car, slot, def)
	if bare == "":
		return String(def.get("menu_label", def.get("name", pid)))
	# UNITS in the popup, none on the tile (_option_tile_label). A bare "+600" is a number
	# with no meaning to a player who does not already know this slot deals in mass; the
	# popup has the width for "kg" and the tile — three across a phone — does not.
	return "%s kg" % bare


# The bare signed kilos for a weight-slot part ("+600", "-200"), or "" for any other slot,
# any part with no mass_mult, and any car with no mass to measure against — all of which
# fall back to the part's authored name rather than printing "+0".
static func _weight_delta_label(owned_car: Dictionary, slot: String, def: Dictionary) -> String:
	if slot != SLOT_WEIGHT:
		return ""
	var mult := float((def.get("effect", {}) as Dictionary).get("mass_mult", 1.0))
	var stock := _stock_mass(owned_car)
	if stock <= 0.0 or is_equal_approx(mult, 1.0):
		return ""
	# ROUNDED TO THE NEAREST 100. The exact figure is derived from a multiplier against
	# this particular car, so it lands on values like 243 or 187 — precision the player has
	# no use for and cannot act on, where a round number reads as a decision. Floored at a
	# magnitude of 100 so a real part on a light car never reads "+0", which would say the
	# option does nothing.
	var delta := stock * (mult - 1.0)
	var rounded := roundi(delta / 100.0) * 100
	if rounded == 0:
		rounded = 100 if delta > 0.0 else -100
	return "%+d" % rounded


# What the GRID TILE shows for this option, when it differs from the popup row. "" means
# "no separate tile label — use the row's". The weight slot is the only user: its tile drops
# the "kg" the popup carries, because a tile has to fit three across a phone on one line.
static func _option_tile_label(owned_car: Dictionary, slot: String, def: Dictionary) -> String:
	return _weight_delta_label(owned_car, slot, def)


# The car's mass with the weight slot empty — the baseline the deltas above are quoted
# against. Goes through effective_meta so an engine swap's mass is already in it.
static func _stock_mass(owned_car: Dictionary) -> float:
	var bare := build_with(owned_car, SLOT_WEIGHT, "")
	return float(UpgradeLibrary.effective_meta(bare, CarLibrary.for_owned(bare)).get("mass", 0.0))


# Why `pid` cannot be taken for this car right now, or "" when it can. Ordered so the
# most actionable answer wins: a part you have not discovered is not "too expensive".
static func _lock_reason(owned_car: Dictionary, instance_id: int, pid: String) -> String:
	if not UpgradeLibrary.rally_gate_met(pid, Save.profile):
		return "Locked"
	if not UpgradeLibrary.prerequisite_met(pid, owned_car):
		return "Needs %s" % _part_name(UpgradeLibrary.by_id(pid).get("requires_upgrade_id", ""))
	if UpgradeLibrary.is_free(pid):
		return ""
	if not Save.can_buy_part(instance_id, pid):
		# "Locked", not the price. A greyed row quoting "2 STARS" reads as a price tag on
		# something you can buy — it is the same shape the AFFORDABLE rows carry beside the
		# star icon — when what it actually means is "you cannot take this". One word for
		# every unavailable option, whatever the reason, so a row the cursor skips always
		# says the same thing.
		return "Locked"
	return ""


static func _part_name(pid: String) -> String:
	var def := UpgradeLibrary.by_id(String(pid))
	return String(def.get("menu_label", def.get("name", pid)))


static func _slot_current_id(owned_car: Dictionary, slot: String) -> String:
	# BOTH conditions. UpgradeLibrary.is_enabled only asks whether the part is in the
	# car's `disabled_upgrades` list — it assumes the caller has already established the
	# car HAS the part. Without the installed check every uninstalled part reads as
	# enabled, so a slot the car is running stock reported a part as fitted and its "Stock"
	# entry never looked current.
	var installed: Array = owned_car.get("installed_upgrades", [])
	for def in UpgradeLibrary.all():
		var pid := String(def.get("id", ""))
		if String(def.get("slot", "")) != slot:
			continue
		if installed.has(pid) and UpgradeLibrary.is_enabled(owned_car, pid):
			return pid
	return ""


# --- Drivetrain: modes, not parts --------------------------------------------

static func _drivetrain_options(owned_car: Dictionary) -> Array[Dictionary]:
	var entry := CarLibrary.for_owned(owned_car)
	var stock := int(entry.get("drive_mode", CarLibrary.RWD))
	# -1 is the "no override" sentinel a fresh car is created with (Save's default), NOT a
	# drive mode. Treating it as one left every unmodified car matching no option, so the
	# tile fell back to reading "Stock" instead of naming the layout the car actually has.
	var override := int(owned_car.get("drivetrain_override", -1))
	var current := override if override >= 0 else stock
	# GARAGE-WIDE capability (won once), but each non-stock conversion is BOUGHT per car —
	# so a row is one of three things: free (the car's stock layout, or a mode it has
	# already paid for), a purchase quoting its star price, or locked because the special
	# that unlocks conversion has not been won.
	var unlocked := UpgradeLibrary.drivetrain_swap_unlocked(Save.profile)
	var instance_id := int(owned_car.get("instance_id", -1))
	var out: Array[Dictionary] = []
	for mode: int in [CarLibrary.RWD, CarLibrary.AWD, CarLibrary.FWD]:
		var is_stock := mode == stock
		var owned_mode := Save.drive_mode_available(owned_car, mode)
		var price := -1
		var reason := ""
		if not owned_mode:
			if not unlocked:
				reason = "Locked"
			elif Save.can_buy_drive_mode(instance_id, mode):
				price = Save.drive_mode_price()
			else:
				# Unlocked and unbought, but the stars are not there. "Locked", not the
				# price — the same single word every unavailable row uses, whatever the
				# reason (see _lock_reason). A greyed row quoting a figure reads as a price
				# tag on something buyable.
				reason = "Locked"
		out.append({
			"id": str(mode),
			"label": _drive_name(mode) + (" (Stock)" if is_stock else ""),
			"tile_label": _drive_name(mode),
			"current": mode == current,
			# The car's own layout is always available — reverting is never gated or charged.
			"selectable": owned_mode or price >= 0,
			"price": price,
			"locked_reason": reason,
		})
	return out


# --- "What would this option make the car?" ----------------------------------
#
# Every option row carries the performance rating the car WOULD have if that option were
# taken, so the slot's ladder can be read as numbers instead of names the player has to
# already know. There is deliberately no "412 -> 455" progression on each row: Stock is
# always the first row and always shows where the car is now, so the before-figure is
# stated once at the top rather than repeated on every line.
#
# Built by making the edit on a THROWAWAY COPY of the owned-car dict and rating that, so
# this shares one definition of "what a build is worth" with the live readout instead of
# re-deriving the effect of each part. Nothing is written to the save.
#
# Cheap despite the rating being a simulated benchmark lap: CarPerformance.rating memoises
# on the meta, so a slot's rows cost one sim each the first time the popup is opened and
# nothing on every reopen.
static func rating_with(owned_car: Dictionary, slot: String, option_id: String) -> int:
	if owned_car.is_empty():
		return 0
	var hypo := build_with(owned_car, slot, option_id)
	return CarPerformance.rating(CarPerformance.merged_meta(hypo, CarLibrary.for_owned(hypo)))


# THE ONE DESCRIPTION of what taking `option_id` in `slot` MEANS.
#
# Both the hypothetical build (build_with, below) and the real apply
# (UpgradesGrid._apply_option) read this, so the two cannot disagree about which edit a
# pick stands for. They still perform it differently — the hypothetical mutates a copy, the
# real one goes through Save's mutators so exclusivity, purchase re-checks and the reward
# flow are untouched — but the DECISION is made once.
#
# They used to be two independent `match slot` ladders held together by a comment asserting
# they agreed. They did not: the drivetrain arm of one marked the layout paid for while the
# other did not, so the picker quoted every drive-mode row at the unconverted car's rating.
# That class of drift is what this removes.
#
# Kinds:
#   "none"        — nothing this pipeline can model. The engine slot is a host-owned flow
#                   (it needs a partner car to pick) and tune is a continuous slider; both
#                   are handled entirely outside the option pipeline. Returning an explicit
#                   "none" is what stops them falling into the PART branch, where an engine
#                   id or a percentage would be appended to installed_upgrades as if it
#                   were a part.
#   "clear_slot"  — the slot's off state ("Stock").
#   "enable_part" — the part is already on the car; switch it on.
#   "fit_part"    — the part is not on the car; acquire it (free, or bought), then enable.
#   "drive_mode"  — set the car's layout, buying it first if unpaid.
static func option_edit(owned_car: Dictionary, slot: String, option_id: String) -> Dictionary:
	if slot == SLOT_ENGINE or slot == SLOT_TUNE:
		return {"kind": "none"}
	if slot == "drivetrain":
		# "" is the universal Stock sentinel in this file, and for a LAYOUT that has to mean
		# the car's authored mode. int("") is 0, which is a real drive mode (RWD) — so
		# without this the off-state sentinel would silently convert every non-RWD car to
		# RWD, and mark it paid for.
		var mode := (UpgradeLibrary.stock_drive_mode(owned_car) if option_id == ""
			else int(option_id))
		return {"kind": "drive_mode", "mode": mode}
	if option_id == "":
		return {"kind": "clear_slot"}
	if (owned_car.get("installed_upgrades", []) as Array).has(option_id):
		return {"kind": "enable_part", "id": option_id}
	return {"kind": "fit_part", "id": option_id, "free": UpgradeLibrary.is_free(option_id)}


# A COPY of `owned_car` with `slot` switched to `option_id` — the same end state the
# matching UpgradesGrid._apply_option branch would leave in the save, minus the save and
# minus the payment. "" is Stock (the slot's off state). Pure: the passed-in dict is never
# touched.
#
# Both paths branch on option_edit above, so "same end state" is now structural rather than
# a claim in a comment. The differential test in test_upgrades_grid.gd holds them to it.
static func build_with(owned_car: Dictionary, slot: String, option_id: String) -> Dictionary:
	var hypo := owned_car.duplicate(true)
	var edit := option_edit(owned_car, slot, option_id)
	match String(edit.get("kind", "none")):
		"none":
			# Not modellable as a slot edit (engine swap / detune). The honest hypothetical
			# is the car exactly as it stands.
			return hypo
		"drive_mode":
			var mode := int(edit["mode"])
			hypo["drivetrain_override"] = mode
			# Marked PAID FOR in the hypothetical: resolve_drive_override ignores an unbought
			# override, so without this the copy would rate as the unconverted car and every
			# drive-mode row would quote the same figure. The question being asked is "what
			# would this car rate if converted", so the copy is a converted car.
			var bought: Array = (hypo.get("drivetrain_modes_bought", []) as Array).duplicate()
			if not bought.has(mode):
				bought.append(mode)
			hypo["drivetrain_modes_bought"] = bought
			return hypo
	var installed: Array = (hypo.get("installed_upgrades", []) as Array).duplicate()
	var disabled: Array = (hypo.get("disabled_upgrades", []) as Array).duplicate()
	# Park the whole slot first, then switch on the pick. Doing it in that order gives the
	# one-part-per-slot rule for free and makes "clear_slot" (Stock) fall out as the
	# no-pick case, rather than needing a branch of its own.
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) == slot and not disabled.has(def.get("id", "")):
			disabled.append(String(def.get("id", "")))
	var pick := String(edit.get("id", ""))
	if pick != "":
		if not installed.has(pick):
			installed.append(pick)
		disabled.erase(pick)
	hypo["installed_upgrades"] = installed
	hypo["disabled_upgrades"] = disabled
	return hypo


static func _drive_name(mode: int) -> String:
	match mode:
		CarLibrary.AWD: return "AWD"
		CarLibrary.FWD: return "FWD"
		_: return "RWD"


# --- Engine swap -------------------------------------------------------------

# Why the engine tile cannot be pressed right now, or "" when it can.
#
# Swapping is a CAPABILITY unlocked by a special rally — ONE gate, and once it is open the
# tile stays permanently accessible: swaps are free and unlimited. The "no other car to swap
# with" case is deliberately NOT checked here: it needs the garage, which this file does
# not read, and hq.gd's picker already reports it properly with a hint.
# `_owned_car` is unused now that the token gate is gone — the one remaining gate is
# garage-wide. Kept in the signature because both call sites pass a car and the "no partner
# to swap with" case, if it ever moves here, is per-car.
static func engine_swap_blocked_reason(_owned_car: Dictionary) -> String:
	if not RallyLibrary.engine_swaps_unlocked(Save.profile):
		return "Locked"
	return ""


# "v12_uneven" -> "V12". The layout ids carry a firing-order qualifier the tile has no room
# for and the player is not picking on; everything before the first underscore is the
# cylinder arrangement itself.
static func _layout_short(layout: String) -> String:
	if layout == "":
		return "?"
	return layout.split("_")[0].to_upper()
