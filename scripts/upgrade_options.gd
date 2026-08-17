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
		if installed.has(pid):
			out.append({
				"id": pid, "label": label, "current": UpgradeLibrary.is_enabled(owned_car, pid),
				"selectable": true, "price": -1, "locked_reason": "",
			})
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
		out.append({
			"id": pid, "label": label, "current": false,
			"selectable": reason == "",
			"price": -1 if free else Save.part_price(pid),
			"locked_reason": reason,
		})
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
	var named := String(def.get("menu_label", def.get("name", pid)))
	if slot != SLOT_WEIGHT:
		return named
	var mult := float((def.get("effect", {}) as Dictionary).get("mass_mult", 1.0))
	var stock := _stock_mass(owned_car)
	# A weight part with no mass_mult, or a car with no mass to measure against, has no
	# number to show — fall back to the authored name rather than printing "+0".
	if stock <= 0.0 or is_equal_approx(mult, 1.0):
		return named
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
		return "%d stars" % Save.part_price(pid)
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
	var unlocked := UpgradeLibrary.drivetrain_swap_unlocked(owned_car)
	var out: Array[Dictionary] = []
	for mode: int in [CarLibrary.RWD, CarLibrary.AWD, CarLibrary.FWD]:
		var is_stock := mode == stock
		out.append({
			"id": str(mode),
			"label": _drive_name(mode) + (" (Stock)" if is_stock else ""),
			"tile_label": _drive_name(mode),
			"current": mode == current,
			# The car's own layout is always available — reverting is never gated.
			"selectable": is_stock or unlocked,
			"price": -1,
			"locked_reason": "" if (is_stock or unlocked) else "Locked",
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


# A COPY of `owned_car` with `slot` switched to `option_id` — the same end state the
# matching UpgradesGrid._apply_option branch would leave in the save, minus the save.
# "" is Stock (the slot's off state). Pure: the passed-in dict is never touched.
static func build_with(owned_car: Dictionary, slot: String, option_id: String) -> Dictionary:
	var hypo := owned_car.duplicate(true)
	if slot == "drivetrain":
		hypo["drivetrain_override"] = int(option_id)
		return hypo
	var installed: Array = (hypo.get("installed_upgrades", []) as Array).duplicate()
	var disabled: Array = (hypo.get("disabled_upgrades", []) as Array).duplicate()
	# Park the whole slot first, then switch on the pick. Doing it in that order gives the
	# one-part-per-slot rule for free and makes "" (Stock) fall out as the no-pick case,
	# rather than needing a branch of its own.
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) == slot and not disabled.has(def.get("id", "")):
			disabled.append(String(def.get("id", "")))
	if option_id != "":
		if not installed.has(option_id):
			installed.append(option_id)
		disabled.erase(option_id)
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
