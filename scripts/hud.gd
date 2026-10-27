extends CanvasLayer
# Docs: features/hud.md, features/stage.md — update in the same change as this file.
# Tests: tests/headless/test_hud.gd, tests/headless/test_hud_gauge.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'hud' tests/headless/` and read the assertions that pin what you are about to change (6 test files touch this script).
# On-screen readout of the car's airspeed — the chassis velocity magnitude,
# not wheel rotation, so wheelspin and lockup don't affect the number.

@export var car: VehicleBody3D

@onready var _speed_label: Label = $SpeedLabel
@onready var _gear_label: Label = $GearLabel
@onready var _rpm_label: Label = $RPMLabel
# Turbo boost readout, part of the H debug overlay. Built in code (no scene node)
# and stacked under the rpm/gear labels; shows the live boost pressure as a
# percentage of full boost, or "N/A" on a naturally-aspirated engine.
var _boost_label: Label
# Last DISPLAYED boost percent (-1 = naturally aspirated) and the turbo flag it
# was formatted under, so the label only re-formats when the readout changes.
var _last_boost_pct := -999
var _last_turbo := false
# Last DISPLAYED nitrous percent (-1 = no nitrous fitted), gating the nitrous gauge
# writes the same way _last_boost_pct gates the boost bar's.
var _last_nitrous_pct := -999
# Track-seed readout, part of the H debug overlay. Built in code and stacked
# under the boost label; shows the current world seed (Config.data.track_seed)
# so a run can be identified/reproduced.
var _seed_label: Label
var _last_seed := -999999
# Per-tire grip readout, part of the H debug overlay: how far up its grip curve each tire
# is — 100% = exactly on the limit, and it keeps climbing past that while the tire slides
# (see Drivetrain.grip_fraction).
#
# Laid out as a 2x2 grid in the car's own plan view — front axle on the top row, left
# wheel in the left column — so a reading maps onto a corner of the car without being
# read off a label. Built in code and stacked under the seed label. Indexed by CORNER
# (see corner_index), NOT by the order the wheels come out of the scene tree.
var _grip_labels: Array[Label] = []
var _last_grip_pct: Array[int] = [-999, -999, -999, -999]
# Corner order of _grip_labels, which is also the grid's fill order (2 columns, so the
# first two entries are the top row).
const _GRIP_CORNERS: Array[String] = ["FL", "FR", "RL", "RR"]
# Grid geometry: each cell is one column wide, and the whole block sits below the seed
# label. Kept here rather than inline so the block moves as one.
const _GRIP_TOP := 108.0
const _GRIP_CELL_W := 76.0 * UITheme.UI_SCALE
# The grid's parent, so the H toggle flips one node instead of four labels.
var _grip_grid: GridContainer
# Where a cell stops reading as neutral: gold approaching the limit, red at or past it.
# Not tuning values in the GameConfig sense — they're the readout's own legend, and the
# limit is 1.0 because that IS peak grip, the point grip_fraction is measured against.
const _GRIP_WARN_FRAC := 0.9
const _GRIP_LIMIT_FRAC := 1.0
# The bottom-centre gauge row (features/hud.md): each is a HudGauge vertical strip, laid
# out edge to edge by _layout_gauges with health first.
#
# In-run damage readout (features/damage.md): the health gauge grades green→red with
# remaining HP and pulses when low, plus a red screen flash on each HP-losing impact.
# The pulse rides on the FILL's alpha, not `modulate`, so the needle, name and icon stay
# legible instead of pulsing red along with the fill.
@onready var _hp_gauge: HudGauge = $HPGauge
# Boost. Shown only on a car with forced induction fitted — turbo
# OR supercharger — and its fill tracks the live boost fraction. See
# features/forced-induction.md.
@onready var _boost_gauge: HudGauge = $BoostGauge
# Nitrous. Shown only when nitrous is fitted
# (GameConfig.has_nitrous()); its fill is the tank fraction left this stage
# (EngineSim.nitrous_fraction()). A turbocharged car with nitrous shows BOTH flankers at
# once, hence the distinct violet hue. See features/nitrous.md.
@onready var _nitrous_gauge: HudGauge = $NitrousGauge
# Free roam's engine temperature gauge (DamageModel.thermal): optional, so the stage scene
# simply has none. Fill = DamageModel.temp_fraction (0 °C empty, full at the overheat threshold), blue to
# red, pulsing while the engine overheats; a label under the gauges warns when the cooling
# has failed.
@onready var _temp_gauge: HudGauge = get_node_or_null("TempGauge")
var _cooling_label: Label
var _temp_pulse_t := 0.0
@onready var _impact_flash: ColorRect = $ImpactFlash

# Low-HP warning pulse speed (rad/s) and the impact-flash response curve: each
# HP-losing hit bumps the red overlay's alpha by (loss fraction) * GAIN, capped at
# MAX, and the overlay fades back out at DECAY alpha/sec.
const _HP_PULSE_SPEED := 9.0
const _IMPACT_FLASH_GAIN := 6.0
const _IMPACT_FLASH_MAX := 0.6
const _IMPACT_FLASH_DECAY := 2.0

# The bottom gauges are ONE family: same saturation and value, distinguished only by
# hue. Every tint comes from _gauge_color so retuning the family moves them all — the
# health bar GRADES its hue with remaining HP (green -> red), while boost (blue) and
# nitrous (violet) are FIXED, since neither has a "danger" end to grade toward.
# Deliberately desaturated and dark: the gauges sit on a solid black plate over the
# driving view, and a bright fill there reads as an alarm going off every time you glance
# down. Muted keeps them legible as a background readout you consult, not a light show.
const _GAUGE_SAT := 0.55
const _GAUGE_VAL := 0.60
const _HP_HUE_FULL := 0.33   # hue at full health; scaled by the HP fraction, so 0 = red
const _BOOST_HUE := 0.58
# Violet, deliberately well away from the boost blue: nitrous and forced induction are
# separate slots, so both bars can be on screen together and must not read as one gauge.
const _NITROUS_HUE := 0.70
# Gap between the gauge row and the bottom of the screen.
const _GAUGE_BOTTOM_MARGIN := 8.0

# Last displayed values, so _process only re-formats + re-assigns a label when
# its value actually changes (avoids per-frame string allocation / GC churn).
var _last_speed := -1
var _last_gear := -999
var _last_rpm := -1
# Working HP last frame, to detect HP-losing impacts (fire the flash); -1 = no
# reading yet / gauge hidden. _hp_pulse_t advances the low-HP warning oscillation.
var _last_hp := -1.0
var _hp_pulse_t := 0.0
# Which gauges were visible at the last row layout, as a bitmask; -1 = never laid out.
var _gauge_layout_mask := -1
# The debug readout (membership: DEBUG_READOUT_NODES below — do not re-list it here,
# a second copy is a second thing to rot) is a dev diagnostic, hidden by default and
# toggled with H (`toggle_debug_arrows`) — the same gate as the debug force
# arrows, and like them only in a debug build (release/web ignore the key).
var _debug_readout := false
# SINGLE SOURCE OF TRUTH for which HUD elements belong to the H-key debug readout.
# Both the startup "hidden" pass in _ready and the H toggle in _timed_process derive
# from this list, and tests/headless/test_hud.gd binds to it directly (it iterates
# DEBUG_READOUT_NODES rather than naming labels), so moving an element in or out of
# the debug overlay is a ONE-LINE edit here — nothing else needs to change.
# Removing a name from this list makes that element permanently visible; that is a
# behaviour change the bound tests will report by name.
#
# Each entry here is gated DELIBERATELY, one label at a time: move only the label whose
# visibility your change is actually about, never its neighbours (they are separate
# product decisions). The docs (features/hud.md, features/debug-tools.md) describe the
# gate per-membership — they point at this constant instead of listing it — so a
# membership move normally needs NO doc edit; tests/headless/test_hud_docs.gd goes red
# if either doc contradicts this list in either direction.
const DEBUG_READOUT_NODES: Array[StringName] = [
	&"SpeedLabel", &"GearLabel", &"RPMLabel", &"BoostLabel", &"SeedLabel",
	&"GripGrid",
]


# The debug-readout elements themselves, resolved from DEBUG_READOUT_NODES. Only valid
# once _ready has built the code-built members (boost / seed / difficulty / grip grid).
func debug_readout_elements() -> Array[CanvasItem]:
	var out: Array[CanvasItem] = []
	for n in DEBUG_READOUT_NODES:
		var node := get_node_or_null(NodePath(String(n)))
		if node is CanvasItem:
			out.append(node)
	return out


func _ready() -> void:
	visible = Config.data.hud_enabled
	# Always-processing so _process can notice the tree pausing/unpausing (see
	# _sync_paused_look). A pausable HUD would never run its own un-hide.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_boost_label()
	_build_seed_label()
	_build_grip_grid()
	# Every member of the debug readout starts hidden until H reveals it. Driven by
	# DEBUG_READOUT_NODES so this pass and the H toggle can never disagree.
	for element in debug_readout_elements():
		element.visible = false
	# Boost gauge starts hidden — _update_boost_gauge reveals it once a car with forced
	# induction is fielded (an NA car never shows an always-empty gauge). Tinted a FIXED
	# blue: unlike health there's no "danger" end to grade toward, and a distinct hue
	# keeps it from reading as a second health gauge.
	_boost_gauge.visible = false
	_boost_gauge.fill_color = _gauge_color(_BOOST_HUE)
	# Same deal for nitrous: hidden until _update_nitrous_gauge sees a fitted tank, and a
	# fixed violet from the same family so it can sit alongside boost unconfused.
	_nitrous_gauge.visible = false
	_nitrous_gauge.fill_color = _gauge_color(_NITROUS_HUE)
	if _temp_gauge != null:
		_temp_gauge.visible = false
		_cooling_label = Label.new()
		_cooling_label.name = "CoolingLabel"
		_cooling_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_cooling_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		_cooling_label.offset_left = -160
		_cooling_label.offset_right = 160
		_cooling_label.offset_top = -126
		_cooling_label.offset_bottom = -104
		_cooling_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.25))
		_cooling_label.visible = false
		add_child(_cooling_label)


# Build a debug readout label in code (no scene node), stacked top-left below the
# rpm/gear labels at font size 14. Hidden until H reveals it. `top` sets the row;
# `right` its width.
func _make_debug_label(node_name: String, top: float, right: float) -> Label:
	var lbl := Label.new()
	lbl.name = node_name
	lbl.offset_left = 8.0
	lbl.offset_top = top
	lbl.offset_right = right
	lbl.offset_bottom = top + 20.0
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	lbl.visible = false
	add_child(lbl)
	return lbl


# Build the debug boost readout, just below the rpm/gear labels.
func _build_boost_label() -> void:
	_boost_label = _make_debug_label("BoostLabel", 48.0, 128.0)


# Debug boost readout text: the live boost as a percentage of full boost, or
# "N/A" on a naturally-aspirated engine (neither turbo nor blower fitted). Pure so
# it's unit-testable without the HUD scene.
static func boost_text(forced_induction: bool, boost: float) -> String:
	if not forced_induction:
		return "Boost N/A"
	return "Boost %d%%" % roundi(clampf(boost, 0.0, 1.0) * 100.0)


# Build the debug seed readout, just below the boost label.
func _build_seed_label() -> void:
	_seed_label = _make_debug_label("SeedLabel", 68.0, 168.0)


# Debug seed readout text. Pure so it's unit-testable without the HUD scene.
static func seed_text(track_seed: int) -> String:
	return "Seed %d" % track_seed


# Build the per-tire grip readout: four labels in a 2x2 GridContainer under the seed
# label, one per corner of the car in _GRIP_CORNERS order.
func _build_grip_grid() -> void:
	var grid := GridContainer.new()
	grid.name = "GripGrid"
	grid.columns = 2
	grid.offset_left = 8.0
	grid.offset_top = _GRIP_TOP
	grid.visible = false
	# The grid is a diagnostic laid OVER the drive view; it must never eat a click or
	# swallow a touch-control drag aimed at the road behind it.
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(grid)
	for corner in _GRIP_CORNERS:
		var lbl := Label.new()
		lbl.name = "Grip" + corner
		lbl.custom_minimum_size.x = _GRIP_CELL_W
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
		lbl.text = grip_text(corner, -1.0)
		grid.add_child(lbl)
		_grip_labels.append(lbl)
	# Nothing lays this grid out for us — it hangs off the CanvasLayer, not a container —
	# so without this its rect stays 0 tall and both rows collapse onto each other. Size it
	# to its own contents and let the offsets above place it.
	grid.reset_size()
	# One parent to toggle, so the H handler doesn't flip four labels by hand.
	_grip_grid = grid


# Which cell of the 2x2 grid a wheel belongs in: the car's plan view, front axle on the
# top row and the left wheel in the left column, matching _GRIP_CORNERS. `rear` is the
# wheel's use_as_traction flag (the drivetrain's own front/rear split — see
# Drivetrain._omega_of) and `local_x` its hardpoint offset across the car, which is
# positive to the RIGHT in Godot's basis. Pure/static so the mapping is testable without
# a car: getting it wrong would silently mirror or flip the whole readout, which is the
# one bug a grid like this can hide.
static func corner_index(rear: bool, local_x: float) -> int:
	return (2 if rear else 0) + (1 if local_x > 0.0 else 0)


# One grip cell's text. `fraction` is how far up its grip curve the tire is
# (Drivetrain.grip_fraction), so it is NOT clamped to 100%: over-100 is the useful part of
# the readout, meaning the tire is slipping past peak grip. NEGATIVE means no reading — the
# wheel is off the ground, or the drivetrain isn't publishing readouts — and shows as a
# dash rather than 0%, since "airborne" and "on the ground using no grip" are different
# things to a driver.
static func grip_text(corner: String, fraction: float) -> String:
	if fraction < 0.0:
		return "%s  --" % corner
	return "%s %d%%" % [corner, roundi(fraction * 100.0)]


# A grip cell's tint: neutral ink with grip in reserve, gold approaching the limit, red at
# or past it (the tire is sliding). Static so the thresholds live in one place next to the
# text they colour.
static func grip_color(fraction: float) -> Color:
	if fraction < 0.0:
		return UITheme.INK
	if fraction >= _GRIP_LIMIT_FRAC:
		return UITheme.RED
	if fraction >= _GRIP_WARN_FRAC:
		# The house palette has no amber; GOLD is its warm mid-tone. Used here purely as
		# "approaching the limit", not with its usual money/reward meaning — this is a dev
		# diagnostic, not player-facing chrome.
		return UITheme.GOLD
	return UITheme.INK


# Refresh the four grip cells from the drivetrain's per-wheel readouts. Absent wheel =
# no contact (or readouts not being published), which reads as a dash.
func _update_grip_grid() -> void:
	var drivetrain: Drivetrain = car.drivetrain
	var fractions: Array[float] = [-1.0, -1.0, -1.0, -1.0]
	for wheel: VehicleWheel3D in drivetrain.readouts:
		var hardpoint: Vector3 = drivetrain.hardpoints.get(wheel, Vector3.ZERO)
		var idx := corner_index(wheel.use_as_traction, hardpoint.x)
		fractions[idx] = float(drivetrain.readouts[wheel].get("grip", 0.0))
	for i in _grip_labels.size():
		# Keyed on the DISPLAYED integer percent like the boost readout: the underlying
		# fraction moves every physics tick, so formatting unconditionally would build
		# four Strings a frame to discover they're identical.
		var pct := roundi(fractions[i] * 100.0) if fractions[i] >= 0.0 else -1
		if pct == _last_grip_pct[i]:
			continue
		_last_grip_pct[i] = pct
		_grip_labels[i].text = grip_text(_GRIP_CORNERS[i], fractions[i])
		_grip_labels[i].add_theme_color_override("font_color", grip_color(fractions[i]))


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"hud", Time.get_ticks_usec() - __t)


# While the tree is paused (a pause/rest-stop/map/stats page is up) the HUD's Control children
# are made fully transparent: the gauges would otherwise sit behind the page and its Back/action
# row would overlap the health gauge. Done with `modulate.a`, NOT `visible`, so it can never
# fight the writers of `visible` (hud_enabled, world.gd's photo-mode chrome, the gauges' own
# fitted-or-not logic). Only touches the children on a pause TRANSITION.
var _paused_look := false


func _sync_paused_look() -> bool:
	var paused := get_tree().paused
	if paused != _paused_look:
		_paused_look = paused
		for child in get_children():
			if child is Control:
				(child as Control).modulate.a = 0.0 if paused else 1.0
	return paused


func _timed_process(_delta: float) -> void:
	if _sync_paused_look():
		return  # frozen world: nothing to refresh, and the car readouts would only repeat
	# Toggle the debug readout (DEBUG_READOUT_NODES) with H, gated on
	# SettingsMenu.dev_tools_enabled() like the force arrows. Text below still refreshes while hidden, so it's correct the
	# instant it's shown.
	if SettingsMenu.dev_tools_enabled() and Input.is_action_just_pressed("toggle_debug_arrows"):
		_debug_readout = not _debug_readout
		# Membership comes from DEBUG_READOUT_NODES (the single source of truth above),
		# not from a hand-maintained list of assignments.
		for element in debug_readout_elements():
			element.visible = _debug_readout
	var engine: EngineSim = car.drivetrain.engine
	var speed := roundi(car.linear_velocity.length() * 3.6)
	if speed != _last_speed:
		_last_speed = speed
		_speed_label.text = "%d km/h" % speed
	if engine.gear != _last_gear:
		_last_gear = engine.gear
		_gear_label.text = _gear_text(engine.gear)
	var rpm := roundi(engine.rpm())
	if rpm != _last_rpm:
		_last_rpm = rpm
		_rpm_label.text = "%d rpm" % rpm
	# Compare the underlying values, not formatted strings: building a String every
	# frame purely to discover it's identical is the allocation the cache exists to
	# avoid. Boost is keyed on the displayed integer percent (plus the turbo flag).
	# "Is there boost to show" and "how much" are both the MODEL's answers, not the HUD's:
	# GameConfig owns the predicate (next to the fields whose encoding it interprets) and
	# EngineSim.boost_reading() owns combining the turbo and belt readings, so a blown
	# engine reports through this same gauge without the HUD knowing which part is fitted.
	var turbo := Config.data.has_forced_induction()
	var live_boost := clampf(engine.boost_reading(), 0.0, 1.0)
	var boost_pct := roundi(live_boost * 100.0) if turbo else -1
	if boost_pct != _last_boost_pct or turbo != _last_turbo:
		_last_boost_pct = boost_pct
		_last_turbo = turbo
		_boost_label.text = boost_text(turbo, live_boost)
		_update_boost_gauge(turbo, live_boost)
	# Nitrous is gated the same way: the displayed integer percent (-1 = not fitted) is
	# the cache key, so a continuous drain only touches the bar when the reading moves.
	var nitrous_fitted := Config.data.has_nitrous()
	var nitrous_frac := clampf(engine.nitrous_fraction(), 0.0, 1.0)
	var nitrous_pct := roundi(nitrous_frac * 100.0) if nitrous_fitted else -1
	if nitrous_pct != _last_nitrous_pct:
		_last_nitrous_pct = nitrous_pct
		_update_nitrous_gauge(nitrous_fitted, nitrous_frac)
	var track_seed: int = Config.data.track_seed
	if track_seed != _last_seed:
		_last_seed = track_seed
		_seed_label.text = seed_text(track_seed)
	# Unlike the readouts above, this one does NOT refresh while hidden: its source is the
	# drivetrain's per-wheel readouts, which the car only publishes while the debug overlay
	# is up (Drivetrain.publish_readouts), so there is nothing to read when it's off.
	if _grip_grid.visible:
		_update_grip_grid()
	_update_damage(_delta)


# The shared tint for both bottom gauges — see _GAUGE_SAT / _GAUGE_VAL. Static so the
# health grade and the fixed boost blue can't drift apart into two hand-copied triples.
static func _gauge_color(hue: float) -> Color:
	return Color.from_hsv(hue, _GAUGE_SAT, _GAUGE_VAL)


# Drive the player-facing boost gauge: the bar IS the boost reading (0..1), with
# the boost icon under it. Hidden entirely on a naturally-aspirated car rather than
# sitting at zero. Turbo and blower share one gauge because they share one upgrade slot,
# so at most one is ever live (features/forced-induction.md).
#
# Both writes are CHANGE-GATED by the caller (the same `boost_pct` / `turbo` caches that
# gate the debug label): raw boost is a continuous float, so writing `value` every frame
# would queue a redraw for sub-pixel changes nobody can see.
func _update_boost_gauge(fitted: bool, live_boost: float) -> void:
	_boost_gauge.visible = fitted
	if fitted:
		_boost_gauge.value = live_boost


# Drive the player-facing nitrous gauge, the boost gauge.s twin: the bar IS the tank
# fraction left this stage, with the NOS bottle icon under it, hidden entirely
# when no nitrous is fitted rather than sitting at zero. Both answers come from the
# MODEL — GameConfig.has_nitrous() for "is it fitted", EngineSim.nitrous_fraction() for
# "how much is left" — and the caller change-gates both writes on the rounded percent.
func _update_nitrous_gauge(fitted: bool, frac: float) -> void:
	_nitrous_gauge.visible = fitted
	if fitted:
		_nitrous_gauge.value = frac


# Drive the HP gauge + impact flash off the car's damage model. Hidden when
# hud_hp_enabled is off.
func _update_damage(delta: float) -> void:
	var dmg: DamageModel = car.damage
	var show_gauge := dmg != null and Config.data.hud_hp_enabled
	_hp_gauge.visible = show_gauge
	if show_gauge:
		var frac := clampf(dmg.hp / dmg.max_hp, 0.0, 1.0) if dmg.max_hp > 0.0 else 0.0
		_hp_gauge.value = frac
		# Green (full) → amber → red (empty) via hue; flash by fading the fill's alpha
		# when below the low-HP warning fraction so the danger is unmissable. The tint
		# rides on the FILL only, so the icon stays plain ink instead of pulsing with it.
		var col := _gauge_color(frac * _HP_HUE_FULL)
		if frac < Config.data.hud_low_hp_warn_frac:
			_hp_pulse_t += delta * _HP_PULSE_SPEED
			col.a = lerpf(0.35, 1.0, 0.5 + 0.5 * sin(_hp_pulse_t))
		else:
			_hp_pulse_t = 0.0
		_hp_gauge.fill_color = col
		# Bump the impact flash on any HP drop since last frame, sized to the loss.
		if _last_hp >= 0.0 and dmg.hp < _last_hp:
			var bump := (_last_hp - dmg.hp) / dmg.max_hp * _IMPACT_FLASH_GAIN
			_impact_flash.color.a = minf(_impact_flash.color.a + bump, _IMPACT_FLASH_MAX)
		_last_hp = dmg.hp
	else:
		_last_hp = -1.0
	# Fade the flash back out regardless of gauge visibility.
	if _impact_flash.color.a > 0.0:
		_impact_flash.color.a = maxf(0.0, _impact_flash.color.a - delta * _IMPACT_FLASH_DECAY)
	_update_temp(dmg, delta)
	_layout_gauges()


# The gauges in left-to-right order. Visible ones sit edge to edge in a centred row along
# the bottom, so a part that isn't fitted closes up instead of leaving a hole.
func _gauge_row() -> Array[HudGauge]:
	var row: Array[HudGauge] = [_hp_gauge, _boost_gauge, _nitrous_gauge]
	if _temp_gauge != null:
		row.append(_temp_gauge)
	return row


func _layout_gauges() -> void:
	var row := _gauge_row()
	var mask := 0
	var width := 0.0
	for i in row.size():
		if row[i].visible:
			mask |= 1 << i
			width += row[i].size.x
	if mask == _gauge_layout_mask:
		return
	_gauge_layout_mask = mask
	var x := -width * 0.5
	for gauge in row:
		if not gauge.visible:
			continue
		var w := gauge.size.x
		var h := gauge.size.y
		gauge.offset_left = x
		gauge.offset_right = x + w
		gauge.offset_bottom = -_GAUGE_BOTTOM_MARGIN
		gauge.offset_top = -_GAUGE_BOTTOM_MARGIN - h
		x += w


func _update_temp(dmg: DamageModel, delta: float) -> void:
	if _temp_gauge == null:
		return
	var thermal := dmg != null and dmg.thermal
	_temp_gauge.visible = thermal
	_cooling_label.visible = thermal and dmg.cooling_broken
	if not thermal:
		return
	var cfg: GameConfig = Config.data
	var frac := dmg.temp_fraction(cfg)
	_temp_gauge.value = frac
	var col := Color.from_hsv(lerpf(0.58, 0.0, frac), _GAUGE_SAT, _GAUGE_VAL)
	if dmg.is_overheating(cfg):
		_temp_pulse_t += delta * _HP_PULSE_SPEED * 1.5
		col.a = lerpf(0.35, 1.0, 0.5 + 0.5 * sin(_temp_pulse_t))
	else:
		_temp_pulse_t = 0.0
	_temp_gauge.fill_color = col
	if dmg.cooling_broken:
		_cooling_label.text = "OVERHEATING — REACH A CHECKPOINT" if dmg.is_overheating(cfg) else "RADIATOR DAMAGED"


# Readouts for tests.
func temp_gauge_visible() -> bool:
	return _temp_gauge != null and _temp_gauge.visible


func cooling_warning() -> String:
	return _cooling_label.text if _cooling_label != null and _cooling_label.visible else ""


func _gear_text(gear: int) -> String:
	if gear < 0:
		return "R"
	if gear == 0:
		return "N"
	return str(gear)
