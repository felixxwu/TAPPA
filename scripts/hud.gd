extends CanvasLayer
# Docs: features/hud.md, features/stage.md — update in the same change as this file.
# Tests: tests/headless/test_hud.gd, tests/headless/test_hud_gauge.gd, tests/headless/test_start_line.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'hud' tests/headless/` and read the assertions that pin what you are about to change (6 test files touch this script).
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
var _difficulty_label: Label
var _last_difficulty := ""   # last rendered difficulty text, so the label repaints only on change
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
# Stage flow widgets, driven by StageManager (todo/stage-start-and-end.md):
# the big centered 3·2·1·GO, the small top-right run timer, and the placeholder
# stage-complete panel. Hidden until the stage flow calls the methods below.
@onready var _countdown_label: Label = $CountdownLabel
@onready var _elapsed_label: Label = $ElapsedLabel
# Last centisecond shown on the run timer, so show_elapsed only re-formats and
# re-assigns the label when the DISPLAYED value moves (-1 = nothing shown yet).
var _last_elapsed_cs := -1
@onready var _stage_complete_panel: Control = $StageCompletePanel
@onready var _stage_complete_label: Label = $StageCompletePanel/Box/StageCompleteLabel
# Finish-panel NEXT button (built in code, added to the panel's Box). Pressing it
# emits finish_next_pressed, which world.gd routes to StageManager.proceed_to_results
# to start the post-stage flow (features/stage.md). Made keyboard/gamepad navigable
# via MenuNav.attach (features/menus.md).
signal finish_next_pressed
var _next_button: Button
# Permanent in-run standings readout (features/hud.md): the player's LIVE position in
# the rival field ("P3/12") with the gap to the position that matters below it — the
# time to find on the rival directly ahead, or the cushion over P2 while leading. Built
# in code (not the scene), driven every frame by the StageManager off LiveStandings, and
# shown for the whole run rather than pulsed. It replaced the old "X.XX ahead of P1"
# popup, which only spoke every fifth turn and only ever compared against the leader.
var _pos_label: Label
var _gap_label: Label
# Last displayed values, so the per-frame drive only re-formats a string when the shown
# value actually moves (-1 / -999999 = nothing shown yet).
var _last_position := -1
var _last_field := -1
var _last_gap_cs := -999999
# Position-change animation (features/hud.md): a gained place slides the position label
# UP into place and flashes GREEN; a lost place slides DOWN and flashes RED. `_pos_anim_left`
# counts the remaining seconds, `_pos_anim_gain` says which way. Deliberately small and
# short — a nudge in peripheral vision, not something that pulls the eye off the road.
var _pos_anim_left := 0.0
var _pos_anim_gain := true
# Live corner-cut billing flash (features/track.md): a small top-right tag the
# StageManager pulses each time TrackProgress bills a cut incident, showing the
# running event total so consecutive incidents read as one growing tag.
var _cut_flash_label: Label
var _cut_flash_left := 0.0
# Off-track warning + reset countdown (features/progress.md): a centre-screen tag the
# StageManager shows while TrackProgress's off-road clock is running past its warning
# grace, counting down the seconds left before the car is snapped back onto the road.
# Unlike the popups above it doesn't self-fade — it mirrors a live state, so it stays
# up until the car is back on the road (or the reset fires).
var _off_road_label: Label
# Last countdown TENTH shown, so show_off_road only re-formats when the displayed
# value moves (-1 = nothing shown yet), matching the run timer's discipline.
var _last_off_road_tenths := -1
# Rally pacenote strip (features/hud.md): a row of turn boards along the top — the
# current turn (arrow + grade, full opacity) with the upcoming turns queued, dimmer,
# to its right. Reads left-to-right and slides left as corners are passed. Built in
# code from the note list world.gd hands us (set_pacenotes); the StageManager pulses
# the current index (show_pacenotes) as TrackProgress advances. Each note reuses the
# roadside-sign arrow art (Pacenotes.arrow_key → GameConfig.sign_textures).
var _pace_rects: Array[TextureRect] = []
var _pace_tex_cache: Dictionary = {}
var _pace_current := 0      # target index (# corners passed), set by show_pacenotes
var _pace_scroll := 0.0     # animated scroll position, eased toward _pace_current
# The three bottom-centre gauges (features/hud.md). Each is a HudGauge: a radial fill
# clipped to a square, with its icon in the middle instead of a text caption. HEALTH sits
# in the CENTRE with boost and NOS flanking it, so hiding a flanker on a car that lacks
# the part leaves health where the eye already expects it.
#
# In-run damage readout (features/damage.md): the health gauge grades green→red with
# remaining HP and pulses when low, plus a red screen flash on each HP-losing impact.
# The pulse rides on the FILL's alpha, not `modulate` — the icon is drawn separately in
# ink, so it stays legible instead of pulsing red along with the fill.
@onready var _hp_gauge: HudGauge = $HPGauge
# Boost, to the left of health. Shown only on a car with forced induction fitted — turbo
# OR supercharger — and its fill tracks the live boost fraction. See
# features/forced-induction.md.
@onready var _boost_gauge: HudGauge = $BoostGauge
# Nitrous, to the right of health. Shown only when nitrous is fitted
# (GameConfig.has_nitrous()); its fill is the tank fraction left this stage
# (EngineSim.nitrous_fraction()). A turbocharged car with nitrous shows BOTH flankers at
# once, hence the distinct violet hue. See features/nitrous.md.
@onready var _nitrous_gauge: HudGauge = $NitrousGauge
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

# Pacenote strip geometry / feel. The current turn sits centred at the top (x = 0,
# directly above the pace/cut popup); each upcoming turn is one _PACE_SLOT_W to the
# right and _PACE_DIM_STEP dimmer (down to _PACE_DIM_FLOOR). Passed turns slide left
# and fade out. _PACE_UPCOMING caps how many upcoming boards show; _PACE_SCROLL_SPEED
# is the ease rate of the left-slide when a corner is passed.
const _PACE_ICON := 54
const _PACE_SLOT_W := 66
const _PACE_TOP := 4.0
const _PACE_UPCOMING := 3
const _PACE_SCROLL_SPEED := 8.0
const _PACE_DIM_STEP := 0.42
const _PACE_DIM_FLOOR := 0.28

# The top-centre pace/cut popups sit directly below the pacenote strip, so their top
# edge is derived from the strip's bottom (_PACE_TOP + _PACE_ICON) plus a small gap —
# this way they follow the pacenote size instead of overlapping when the icons grow.
const _POPUP_GAP := 8.0
const _POPUP_TOP := _PACE_TOP + _PACE_ICON + _POPUP_GAP
const _POPUP_HEIGHT := 24.0

# The standings readout sits top-left directly under the run timer (ElapsedLabel ends at
# y=32 in main.tscn), with the gap line under the position line. _POS_SLIDE is how far the
# position label travels during a gain/lose animation, _POS_ANIM_SECONDS how long that takes.
const _POS_TOP := 36.0
const _POS_HEIGHT := 26.0
const _GAP_HEIGHT := 18.0
const _POS_SLIDE := 9.0
const _POS_ANIM_SECONDS := 0.65

# The off-track warning hangs this far BELOW the viewport centre (it anchors at 0.5,
# unlike the top-anchored popups above), clearing the centred 3·2·1·GO countdown.
const _OFF_ROAD_TOP := 70.0

# Last displayed values, so _process only re-formats + re-assigns a label when
# its value actually changes (avoids per-frame string allocation / GC churn).
var _last_speed := -1
var _last_gear := -999
var _last_rpm := -1
# Working HP last frame, to detect HP-losing impacts (fire the flash); -1 = no
# reading yet / gauge hidden. _hp_pulse_t advances the low-HP warning oscillation.
var _last_hp := -1.0
var _hp_pulse_t := 0.0
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
# EDITING THIS LIST IS A THREE-PART CHANGE — the list, the named test, AND the docs:
#   features/hud.md          -> Elements table + the "Membership is data" section
#   features/debug-tools.md  -> the "speed / gear / rpm readout" description
# The docs are the part that gets missed, because this file's header breadcrumb is
# ~180 lines above here and nobody editing a constant scrolls back to it. Both docs
# NAME their members in prose, so prose is what rots when the data changes.
const DEBUG_READOUT_NODES: Array[StringName] = [
	&"SpeedLabel", &"GearLabel", &"RPMLabel", &"BoostLabel", &"SeedLabel",
	&"DifficultyLabel", &"GripGrid",
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
	_build_boost_label()
	_build_seed_label()
	_build_difficulty_label()
	_build_grip_grid()
	# Every member of the debug readout starts hidden until H reveals it. Driven by
	# DEBUG_READOUT_NODES so this pass and the H toggle can never disagree.
	for element in debug_readout_elements():
		element.visible = false
	# Boost gauge starts hidden — _update_boost_gauge reveals it once a car with forced
	# induction is fielded (an NA car never shows an always-empty dial). Tinted a FIXED
	# blue: unlike health there's no "danger" end to grade toward, and a distinct hue
	# keeps it from reading as a second health gauge.
	_boost_gauge.visible = false
	_boost_gauge.fill_color = _gauge_color(_BOOST_HUE)
	# Same deal for nitrous: hidden until _update_nitrous_gauge sees a fitted tank, and a
	# fixed violet from the same family so it can sit alongside boost unconfused.
	_nitrous_gauge.visible = false
	_nitrous_gauge.fill_color = _gauge_color(_NITROUS_HUE)
	# Stage widgets start hidden; StageManager reveals them at the right moments.
	_countdown_label.visible = false
	_elapsed_label.visible = false
	_stage_complete_panel.visible = false
	# Design-system accents: the run timer reads white (neutral primary text), the
	# stage-complete banner green (success) — matching the house palette. See features/ui-design-system.md.
	_elapsed_label.add_theme_color_override("font_color", UITheme.INK)
	_stage_complete_label.add_theme_color_override("font_color", UITheme.GREEN)
	_build_position_readout()
	_build_cut_flash_label()
	_build_off_road_label()
	# Build the finish-panel NEXT button and make it keyboard/gamepad navigable. Attaching
	# MenuNav to the (hidden) panel flips the button to FOCUS_ALL now and re-grabs focus
	# onto it whenever the panel is shown (features/menus.md → "Menu navigation").
	_next_button = UITheme.button("Next")
	_next_button.name = "NextButton"
	_next_button.pressed.connect(func() -> void: finish_next_pressed.emit())
	$StageCompletePanel/Box.add_child(_next_button)
	MenuNav.attach(_stage_complete_panel, {"first": _next_button})


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
	lbl.add_theme_font_size_override("font_size", UITheme.px(14))
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


# Build the adaptive-difficulty readout, just below the seed label.
func _build_difficulty_label() -> void:
	_difficulty_label = _make_debug_label("DifficultyLabel", 88.0, 208.0)


# Debug adaptive-difficulty readout (features/adaptive-difficulty.md): how far the rival
# field is currently pitched from "matched to the player", and what that does to the rating
# the field is drawn against.
#
# Answers the question the offset is invisible for otherwise — "are these opponents harder
# than they should be, or am I just slow today?" — because the mechanism is silent by
# design: it moves the MACHINERY the rivals turn up in, so a harder field looks exactly like
# an ordinary field of quicker cars.
#
# Pure/static so it is unit-testable without the HUD scene, like seed_text and boost_text.
static func difficulty_text(steps: int, step_fraction: float, enabled: bool) -> String:
	if not enabled:
		return "AI off"
	if steps == 0:
		return "AI matched"
	# The multiplier is what actually reaches the matcher (AiDifficulty.target_rating), so
	# it is the number to show — the step count alone means nothing without the fraction.
	return "AI %+d (x%.2f)" % [steps, 1.0 + float(steps) * step_fraction]


# Build the per-tire grip readout: four labels in a 2x2 GridContainer under the difficulty
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
		lbl.add_theme_font_size_override("font_size", UITheme.px(14))
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


# A transient popup label built in code (no scene node): hidden until a show_*
# call pulses it, then faded out by _tick_fade. `offsets` is (left, right, top,
# bottom). Callers layer on colour / anchoring specifics after.
func _make_popup_label(node_name: String, anchor: float, grow_dir: int,
		offsets: Vector4, align: int) -> Label:
	var lbl := Label.new()
	lbl.name = node_name
	lbl.anchor_left = anchor
	lbl.anchor_right = anchor
	lbl.grow_horizontal = grow_dir as Control.GrowDirection
	lbl.offset_left = offsets.x
	lbl.offset_right = offsets.y
	lbl.offset_top = offsets.z
	lbl.offset_bottom = offsets.w
	lbl.horizontal_alignment = align as HorizontalAlignment
	lbl.add_theme_font_size_override("font_size", UITheme.px(20))
	lbl.visible = false
	add_child(lbl)
	return lbl


# Build the two standings labels in code (they have no scene nodes): top-LEFT, stacked
# directly under the run timer, because position and elapsed time are one thought and the
# eye should find them in one place. Not `_make_popup_label` — these are a live state
# readout with no fade timer, the same way the off-road warning mirrors a live clock.
#
# They start hidden: a plain dev boot of main.tscn has no rival field, so nothing ever
# calls show_position() and the corner stays empty.
func _build_position_readout() -> void:
	_pos_label = Label.new()
	_pos_label.name = "PositionLabel"
	_pos_label.offset_left = 8.0
	_pos_label.offset_right = 128.0
	_pos_label.add_theme_font_size_override("font_size", UITheme.px(22))
	_pos_label.add_theme_color_override("font_color", UITheme.INK)
	_pos_label.visible = false
	add_child(_pos_label)
	_seat_position_label(0.0)
	_gap_label = Label.new()
	_gap_label.name = "PositionGapLabel"
	_gap_label.offset_left = 8.0
	_gap_label.offset_right = 148.0
	_gap_label.offset_top = _POS_TOP + _POS_HEIGHT
	_gap_label.offset_bottom = _POS_TOP + _POS_HEIGHT + _GAP_HEIGHT
	_gap_label.add_theme_font_size_override("font_size", UITheme.px(14))
	_gap_label.add_theme_color_override("font_color", UITheme.INK_DIM)
	_gap_label.visible = false
	add_child(_gap_label)


# Place the position label `dy` pixels off its resting row — the whole of the
# gain/lose animation's movement. The gap line below never moves: sliding both would
# read as the panel jumping rather than the position turning over.
func _seat_position_label(dy: float) -> void:
	_pos_label.offset_top = _POS_TOP + dy
	_pos_label.offset_bottom = _POS_TOP + _POS_HEIGHT + dy


# Off-track warning + reset countdown (features/progress.md). Centre screen, just
# BELOW the middle so it clears the big 3·2·1·GO countdown (which is centred on the
# whole viewport) — the two can't be on screen together in practice, but the offset
# keeps the warning out of the eye-line of the road ahead either way. Not a fading
# popup: it is a live state readout, shown for exactly as long as the clock runs, so
# it has no _tick_fade timer and StageManager drives both show and hide.
func _build_off_road_label() -> void:
	_off_road_label = _make_popup_label("OffRoadLabel", 0.5,
		Control.GROW_DIRECTION_BOTH,
		Vector4(-160.0, 160.0, _OFF_ROAD_TOP, _OFF_ROAD_TOP + _POPUP_HEIGHT),
		HORIZONTAL_ALIGNMENT_CENTER)
	_off_road_label.anchor_top = 0.5
	_off_road_label.anchor_bottom = 0.5
	_off_road_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_off_road_label.add_theme_font_size_override("font_size", UITheme.px(28))
	_off_road_label.add_theme_color_override("font_color", UITheme.RED)


# Off-track warning text. Pure so it's unit-testable without the HUD scene. The
# countdown is shown to a tenth — coarse enough to read at speed, fine enough that
# it's visibly running rather than a static warning.
static func off_road_text(seconds_left: float) -> String:
	return "OFF TRACK  %.1f" % maxf(seconds_left, 0.0)


# Show the off-track warning with `seconds_left` on the clock. Change-gated on the
# displayed TENTH so a per-frame call doesn't re-format a string every frame.
func show_off_road(seconds_left: float) -> void:
	var tenths := maxi(0, roundi(seconds_left * 10.0))
	if tenths != _last_off_road_tenths:
		_last_off_road_tenths = tenths
		_off_road_label.text = off_road_text(tenths / 10.0)
	_off_road_label.visible = true


func hide_off_road() -> void:
	_off_road_label.visible = false
	_last_off_road_tenths = -1


# Corner-cut flash: a small top-centre tag, on its own row under the pacenote strip
# (nothing shares the spot now that the "vs P1" pace popup is gone).
func _build_cut_flash_label() -> void:
	_cut_flash_label = _make_popup_label("CutFlashLabel", 0.5,
		Control.GROW_DIRECTION_BOTH,
		Vector4(-80.0, 80.0, _POPUP_TOP, _POPUP_TOP + _POPUP_HEIGHT),
		HORIZONTAL_ALIGNMENT_CENTER)
	_cut_flash_label.add_theme_color_override("font_color", UITheme.RED)


# Count a popup's remaining on-screen time down by delta; hide it when it lapses.
# Returns the new remaining time (caller stores it back).
func _tick_fade(left: float, delta: float, label: Label) -> float:
	if left <= 0.0:
		return left
	left -= delta
	if left <= 0.0:
		label.visible = false
	return left


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"hud", Time.get_ticks_usec() - __t)


func _timed_process(_delta: float) -> void:
	# Toggle the debug readout (DEBUG_READOUT_NODES) with H, gated to debug builds like the
	# force arrows. Text below still refreshes while hidden, so it's correct the
	# instant it's shown.
	if OS.is_debug_build() and Input.is_action_just_pressed("toggle_debug_arrows"):
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
	# Repainted only when the text changes, like the seed above. The offset only moves at a
	# stage BOUNDARY (Save.record_stage_result), so this is a compare-and-skip every frame
	# rather than a string build.
	var difficulty := difficulty_text(AiDifficulty.steps_of(Save.profile),
		Config.data.ai_adapt_step_fraction, Config.data.ai_adapt_enabled)
	if difficulty != _last_difficulty:
		_last_difficulty = difficulty
		_difficulty_label.text = difficulty
	# Unlike the readouts above, this one does NOT refresh while hidden: its source is the
	# drivetrain's per-wheel readouts, which the car only publishes while the debug overlay
	# is up (Drivetrain.publish_readouts), so there is nothing to read when it's off.
	if _grip_grid.visible:
		_update_grip_grid()
	_update_damage(_delta)
	# Hide each transient popup once its on-screen time elapses.
	_tick_position_anim(_delta)
	_cut_flash_left = _tick_fade(_cut_flash_left, _delta, _cut_flash_label)
	_tick_pacenotes(_delta)


# The shared tint for both bottom gauges — see _GAUGE_SAT / _GAUGE_VAL. Static so the
# health grade and the fixed boost blue can't drift apart into two hand-copied triples.
static func _gauge_color(hue: float) -> Color:
	return Color.from_hsv(hue, _GAUGE_SAT, _GAUGE_VAL)


# Drive the player-facing boost gauge: the dial's fill IS the boost reading (0..1), with
# the boost icon in the middle. Hidden entirely on a naturally-aspirated car rather than
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


# Drive the player-facing nitrous gauge, the boost dial's twin: the fill IS the tank
# fraction left this stage, with the NOS bottle icon in the middle, hidden entirely
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
		# The cross icon sits in the middle of the dial — the fill itself IS the reading,
		# so the absolute HP number was redundant noise.
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


func _gear_text(gear: int) -> String:
	if gear < 0:
		return "R"
	if gear == 0:
		return "N"
	return str(gear)


# --- Stage flow (driven by StageManager, todo/stage-start-and-end.md) ---------

# Big centered countdown. ceili maps (2,3]→3, (1,2]→2, (0,1]→1; 0 (or below)
# shows "GO".
func show_countdown(seconds_left: float) -> void:
	_countdown_label.visible = true
	_countdown_label.text = str(ceili(seconds_left)) if seconds_left > 0.0 else "GO"


func hide_countdown() -> void:
	_countdown_label.visible = false


# Small top-right run timer. Gated by hud_elapsed_enabled (mirrors hud_enabled);
# one formatted string per frame is acceptable since the value changes every tick.
func show_elapsed(seconds: float) -> void:
	if not Config.data.hud_elapsed_enabled:
		return
	_elapsed_label.visible = true
	# The readout only shows centiseconds, so quantise to one and skip the re-format
	# + re-assign when it hasn't moved: writing Label.text re-runs TextServer shaping
	# even for identical text. Formatting FROM the quantised value keeps the string a
	# pure function of what we compare, so nothing can drift between the two.
	var cs := roundi(seconds * 100.0)
	if cs == _last_elapsed_cs:
		return
	_last_elapsed_cs = cs
	_elapsed_label.text = UITheme.format_time(cs * 10)


# Placeholder stage-complete panel — at minimum the final time. The menu's
# buttons/actions are a separate todo (rally-event-flow.md / menus.md); this is
# the stub the future flow attaches to.
func show_stage_complete(seconds: float, penalty_s := 0.0) -> void:
	# Showing the panel fires its visibility_changed, which MenuNav uses to grab focus
	# onto the NEXT button (ui_accept then triggers it; the theme paints the cursor).
	_stage_complete_panel.visible = true
	if penalty_s > 0.0:
		# Clean run + cut penalty = final. Only shown when a cut was billed.
		var total := UITheme.format_time(roundi((seconds + penalty_s) * 1000.0))
		_stage_complete_label.text = "FINISH\n%s\n+%.1fs cut\n= %s" % [
			UITheme.format_time(roundi(seconds * 1000.0)), penalty_s, total]
	else:
		_stage_complete_label.text = "FINISH\n%s" % UITheme.format_time(roundi(seconds * 1000.0))


# --- Live standings readout (features/hud.md) ---------------------------------

# The position line. Pure so the format is testable without the HUD scene.
static func position_text(position: int, field: int) -> String:
	return "P%d/%d" % [maxi(1, position), maxi(1, field)]


# The gap line: the time to find on the position above, or — while leading — the cushion
# held over P2. Worded rather than signed ("to" / "over"): a bare ± in the corner of the
# screen at speed reads as ambiguous, and this line has to answer "which way" instantly.
# Pure, for the same reason as position_text.
static func gap_text(gap_ms: int, leading: bool, position: int) -> String:
	var secs := absf(gap_ms / 1000.0)
	if leading:
		return "%.2f over P2" % secs
	return "%.2f to P%d" % [secs, maxi(1, position - 1)]


# Drive the permanent standings readout, called every frame while the stage runs
# (StageManager off LiveStandings.standing). Gated by hud_position_enabled.
#
# Both label writes are change-gated on the DISPLAYED value — position, field, and the
# gap rounded to the shown centisecond — because this runs per frame and the underlying
# projection moves continuously; formatting unconditionally would build two Strings a
# frame to discover they are identical.
#
# A position that MOVED starts the gain/lose animation, but only once a position has
# actually been shown: the first frame of a stage is the readout appearing, not the
# player overtaking someone.
func show_position(position: int, field: int, gap_ms: int, leading: bool) -> void:
	if not Config.data.hud_position_enabled:
		return
	var moved := position != _last_position
	if moved or field != _last_field:
		if moved and _last_position > 0:
			_pos_anim_left = _POS_ANIM_SECONDS
			_pos_anim_gain = position < _last_position
		_last_position = position
		_last_field = field
		_pos_label.text = position_text(position, field)
	_pos_label.visible = true
	# One classified car means the player is alone out there — a gap to nobody.
	if field <= 1:
		_gap_label.visible = false
		return
	var gap_cs := roundi(absf(gap_ms / 10.0))
	# `moved` is in the gate as well as the gap itself: the gap line NAMES the position
	# above ("to P4"), so it has to be rebuilt when the position turns over even if the
	# number of seconds happens to round the same.
	if gap_cs != _last_gap_cs or moved:
		_last_gap_cs = gap_cs
		_gap_label.text = gap_text(gap_cs * 10, leading, position)
		_gap_label.add_theme_color_override("font_color",
			UITheme.GREEN if leading else UITheme.INK_DIM)
	_gap_label.visible = true


# Take the readout down (the stage ended, or a car swap re-armed the flow) and forget the
# shown values, so the next stage's first position is an appearance and not an overtake.
func hide_position() -> void:
	_pos_label.visible = false
	_gap_label.visible = false
	_last_position = -1
	_last_field = -1
	_last_gap_cs = -999999
	_pos_anim_left = 0.0
	_seat_position_label(0.0)


# The gain/lose animation, one frame at a time: the position label slides into its resting
# row — up from below on a gained place, down from above on a lost one — while its colour
# fades from GREEN / RED back to INK. Eased so most of the movement and nearly all of the
# colour happen in the first instants, which is what makes it read as a flick rather than
# a drift. Costs nothing once the timer lapses.
func _tick_position_anim(delta: float) -> void:
	if _pos_anim_left <= 0.0:
		return
	_pos_anim_left = maxf(0.0, _pos_anim_left - delta)
	# 1 at the start of the animation, 0 at its end, ease-out (fast then settling).
	var u := _pos_anim_left / _POS_ANIM_SECONDS
	var eased := u * u
	_seat_position_label((_POS_SLIDE if _pos_anim_gain else -_POS_SLIDE) * eased)
	var accent: Color = UITheme.GREEN if _pos_anim_gain else UITheme.RED
	_pos_label.add_theme_color_override("font_color", UITheme.INK.lerp(accent, eased))


# Live corner-cut flash, pulsed by StageManager each time TrackProgress bills
# an incident. Shows the running event total (not the incident delta) so
# consecutive incidents read as one growing tag rather than flickering resets.
func show_cut_flash(_incident_s: float, total_s: float) -> void:
	if not Config.data.cut_penalty_enabled:
		return
	_cut_flash_label.text = "CUT +%.1fs" % total_s
	_cut_flash_label.visible = true
	_cut_flash_left = Config.data.hud_popup_show_seconds


# --- Pacenote strip (features/hud.md) ----------------------------------------

# Rebuild the pacenote strip from a fresh note list (world.gd on track generation /
# car swap). Each note is a TextureRect showing the corner's arrow board; layout +
# opacity are driven per frame by _tick_pacenotes off _pace_scroll. A no-op body when
# pacenotes are disabled (rects stay cleared, so the strip never appears).
func set_pacenotes(notes: Array) -> void:
	# Detach immediately (not just queue_free) so a rebuild in the same frame can't
	# collide on the "Pacenote<i>" names with boards still awaiting deferred free.
	for board in _pace_rects:
		remove_child(board)
		board.queue_free()
	_pace_rects.clear()
	_pace_current = 0
	_pace_scroll = 0.0
	if not Config.data.hud_pacenotes_enabled:
		return
	for n in notes:
		var board := TextureRect.new()
		board.name = "Pacenote%d" % _pace_rects.size()
		board.texture = _pace_texture(Pacenotes.arrow_key(String(n["corner"]), bool(n["flip"])))
		board.anchor_left = 0.5
		board.anchor_right = 0.5
		board.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		board.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		board.mouse_filter = Control.MOUSE_FILTER_IGNORE
		board.visible = false
		add_child(board)
		_pace_rects.append(board)
	_layout_pacenotes()


# Set the current-turn index (how many corners the car has passed). The strip eases
# toward it in _tick_pacenotes, so a jump of 1 reads as a smooth left-slide.
func show_pacenotes(current: int) -> void:
	if not Config.data.hud_pacenotes_enabled:
		return
	_pace_current = current


# Ease the scroll toward the current index (fps-independent exponential smoothing)
# and re-lay the strip. Cheap no-op when there are no notes.
func _tick_pacenotes(delta: float) -> void:
	if _pace_rects.is_empty():
		return
	var t := 1.0 - exp(-delta * _PACE_SCROLL_SPEED)
	_pace_scroll = lerpf(_pace_scroll, float(_pace_current), t)
	_layout_pacenotes()


# Position + fade every note board from its distance to the current slot. d = 0 is
# the current turn (centred, full opacity); d > 0 are upcoming turns queued to the
# right, one _PACE_SLOT_W apart and dimming by _PACE_DIM_STEP; d < 0 are passed turns
# sliding off to the left as they fade. Off-strip boards are hidden.
func _layout_pacenotes() -> void:
	for i in _pace_rects.size():
		var board := _pace_rects[i]
		var d := float(i) - _pace_scroll
		if d < -1.0 or d > float(_PACE_UPCOMING) + 0.5:
			board.visible = false
			continue
		var a := clampf(1.0 + d, 0.0, 1.0) if d < 0.0 \
			else maxf(_PACE_DIM_FLOOR, 1.0 - _PACE_DIM_STEP * d)
		if a <= 0.01:
			board.visible = false
			continue
		var xc := d * _PACE_SLOT_W
		board.offset_left = xc - _PACE_ICON * 0.5
		board.offset_right = xc + _PACE_ICON * 0.5
		board.offset_top = _PACE_TOP
		board.offset_bottom = _PACE_TOP + _PACE_ICON
		board.modulate.a = a
		board.visible = true


# Load + cache the arrow texture for an atlas key (GameConfig.sign_textures). Returns
# null for an unknown/missing key (the board then renders empty rather than erroring).
func _pace_texture(key: String) -> Texture2D:
	if _pace_tex_cache.has(key):
		return _pace_tex_cache[key]
	var tex: Texture2D = null
	var path := String(Config.data.sign_textures.get(key, ""))
	if path != "" and ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_pace_tex_cache[key] = tex
	return tex
