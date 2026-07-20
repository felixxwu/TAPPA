extends CanvasLayer
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
var _last_boost_text := ""
# Track-seed readout, part of the H debug overlay. Built in code and stacked
# under the boost label; shows the current world seed (Config.data.track_seed)
# so a run can be identified/reproduced.
var _seed_label: Label
var _last_seed_text := ""
# Stage flow widgets, driven by StageManager (todo/stage-start-and-end.md):
# the big centered 3·2·1·GO, the small top-right run timer, and the placeholder
# stage-complete panel. Hidden until the stage flow calls the methods below.
@onready var _countdown_label: Label = $CountdownLabel
@onready var _elapsed_label: Label = $ElapsedLabel
@onready var _stage_complete_panel: Control = $StageCompletePanel
@onready var _stage_complete_label: Label = $StageCompletePanel/Box/StageCompleteLabel
# Finish-panel NEXT button (built in code, added to the panel's Box). Pressing it
# emits finish_next_pressed, which world.gd routes to StageManager.proceed_to_results
# to start the post-stage flow (features/stage.md). Made keyboard/gamepad navigable
# via MenuNav.attach (features/menus.md).
signal finish_next_pressed
var _next_button: Button
# In-run "vs P1" pace popup: a small top-centre readout the StageManager pulses every
# few turns, showing the player's time delta to the leading rival (− green = ahead,
# + red = behind). Built in code (not the scene) and auto-hides after a moment.
var _stage_delta_label: Label
var _stage_delta_left := 0.0
# Live corner-cut billing flash (features/track.md): a small top-right tag the
# StageManager pulses each time TrackProgress bills a cut incident, showing the
# running event total so consecutive incidents read as one growing tag.
var _cut_flash_label: Label
var _cut_flash_left := 0.0
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
# In-run damage readout (features/damage.md): a colour-graded HP bar that
# flashes a warning when low, plus a red screen flash on each HP-losing impact.
@onready var _hp_label: Label = $HPLabel
@onready var _hp_bar: ProgressBar = $HPBar
@onready var _impact_flash: ColorRect = $ImpactFlash

# Low-HP warning pulse speed (rad/s) and the impact-flash response curve: each
# HP-losing hit bumps the red overlay's alpha by (loss fraction) * GAIN, capped at
# MAX, and the overlay fades back out at DECAY alpha/sec.
const _HP_PULSE_SPEED := 9.0
const _IMPACT_FLASH_GAIN := 6.0
const _IMPACT_FLASH_MAX := 0.6
const _IMPACT_FLASH_DECAY := 2.0

# Pacenote strip geometry / feel. The current turn sits centred at the top (x = 0,
# directly above the pace/cut popup); each upcoming turn is one _PACE_SLOT_W to the
# right and _PACE_DIM_STEP dimmer (down to _PACE_DIM_FLOOR). Passed turns slide left
# and fade out. _PACE_UPCOMING caps how many upcoming boards show; _PACE_SCROLL_SPEED
# is the ease rate of the left-slide when a corner is passed.
const _PACE_ICON := 36.0
const _PACE_SLOT_W := 44.0
const _PACE_TOP := 4.0
const _PACE_UPCOMING := 3
const _PACE_SCROLL_SPEED := 8.0
const _PACE_DIM_STEP := 0.42
const _PACE_DIM_FLOOR := 0.28

# Last displayed values, so _process only re-formats + re-assigns a label when
# its value actually changes (avoids per-frame string allocation / GC churn).
var _last_speed := -1
var _last_gear := -999
var _last_rpm := -1
# Working HP last frame, to detect HP-losing impacts (fire the flash); -1 = no
# reading yet / gauge hidden. _hp_pulse_t advances the low-HP warning oscillation.
var _last_hp := -1.0
var _hp_pulse_t := 0.0
# Last displayed health percentage, so the label only re-formats on a change.
var _last_hp_pct := -1
# The speed / gear / rpm readout is a dev diagnostic, hidden by default and
# toggled with H (`toggle_debug_arrows`) — the same gate as the debug force
# arrows, and like them only in a debug build (release/web ignore the key).
var _debug_readout := false


func _ready() -> void:
	visible = Config.data.hud_enabled
	# Speed / gear / rpm are a dev readout — hidden until H reveals them.
	_speed_label.visible = false
	_gear_label.visible = false
	_rpm_label.visible = false
	_build_boost_label()
	_build_seed_label()
	# Stage widgets start hidden; StageManager reveals them at the right moments.
	_countdown_label.visible = false
	_elapsed_label.visible = false
	_stage_complete_panel.visible = false
	# Design-system accents: the run timer reads white (neutral primary text), the
	# stage-complete banner green (success) — matching the house palette. See features/ui-design-system.md.
	_elapsed_label.add_theme_color_override("font_color", UITheme.INK)
	_stage_complete_label.add_theme_color_override("font_color", UITheme.GREEN)
	_build_stage_delta_label()
	_build_cut_flash_label()
	# Build the finish-panel NEXT button and make it keyboard/gamepad navigable. Attaching
	# MenuNav to the (hidden) panel flips the button to FOCUS_ALL now and re-grabs focus
	# onto it whenever the panel is shown (features/menus.md → "Menu navigation").
	_next_button = UITheme.button("Next")
	_next_button.name = "NextButton"
	_next_button.pressed.connect(func() -> void: finish_next_pressed.emit())
	$StageCompletePanel/Box.add_child(_next_button)
	MenuNav.attach(_stage_complete_panel, {"first": _next_button})


# Build the top-centre pace-popup label in code (it has no scene node). Anchored to
# the top centre, sitting just below the run timer, and
# hidden until the StageManager pulses it via show_stage_delta().
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
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.visible = false
	add_child(lbl)
	return lbl


# Build the debug boost readout, just below the rpm/gear labels.
func _build_boost_label() -> void:
	_boost_label = _make_debug_label("BoostLabel", 48.0, 128.0)


# Debug boost readout text: the live boost as a percentage of full boost, or
# "N/A" on a naturally-aspirated engine (no turbo fitted). Pure so it's unit-
# testable without the HUD scene.
static func boost_text(turbo_enabled: bool, boost: float) -> String:
	if not turbo_enabled:
		return "Boost N/A"
	return "Boost %d%%" % roundi(clampf(boost, 0.0, 1.0) * 100.0)


# Build the debug seed readout, just below the boost label.
func _build_seed_label() -> void:
	_seed_label = _make_debug_label("SeedLabel", 68.0, 168.0)


# Debug seed readout text. Pure so it's unit-testable without the HUD scene.
static func seed_text(track_seed: int) -> String:
	return "Seed %d" % track_seed


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
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.visible = false
	add_child(lbl)
	return lbl


func _build_stage_delta_label() -> void:
	_stage_delta_label = _make_popup_label("StageDeltaLabel", 0.5,
		Control.GROW_DIRECTION_BOTH, Vector4(-80.0, 80.0, 40.0, 64.0),
		HORIZONTAL_ALIGNMENT_CENTER)


# Corner-cut flash, sharing the top-centre pace-popup spot with StageDeltaLabel
# (it takes precedence while showing — see show_cut_flash / show_stage_delta).
func _build_cut_flash_label() -> void:
	_cut_flash_label = _make_popup_label("CutFlashLabel", 0.5,
		Control.GROW_DIRECTION_BOTH, Vector4(-80.0, 80.0, 40.0, 64.0),
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
	# Toggle the speed / gear / rpm readout with H, gated to debug builds like the
	# force arrows. Text below still refreshes while hidden, so it's correct the
	# instant it's shown.
	if OS.is_debug_build() and Input.is_action_just_pressed("toggle_debug_arrows"):
		_debug_readout = not _debug_readout
		_speed_label.visible = _debug_readout
		_gear_label.visible = _debug_readout
		_rpm_label.visible = _debug_readout
		_boost_label.visible = _debug_readout
		_seed_label.visible = _debug_readout
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
	var boost_str := boost_text(Config.data.turbo_enabled, engine.boost)
	if boost_str != _last_boost_text:
		_last_boost_text = boost_str
		_boost_label.text = boost_str
	var seed_str := seed_text(Config.data.track_seed)
	if seed_str != _last_seed_text:
		_last_seed_text = seed_str
		_seed_label.text = seed_str
	_update_damage(_delta)
	# Hide each transient popup once its on-screen time elapses.
	_stage_delta_left = _tick_fade(_stage_delta_left, _delta, _stage_delta_label)
	_cut_flash_left = _tick_fade(_cut_flash_left, _delta, _cut_flash_label)
	_tick_pacenotes(_delta)


# Drive the HP gauge + impact flash off the car's damage model. Hidden when
# hud_hp_enabled is off.
func _update_damage(delta: float) -> void:
	var dmg: DamageModel = car.damage
	var show_gauge := dmg != null and Config.data.hud_hp_enabled
	_hp_bar.visible = show_gauge
	_hp_label.visible = show_gauge
	if show_gauge:
		var frac := clampf(dmg.hp / dmg.max_hp, 0.0, 1.0) if dmg.max_hp > 0.0 else 0.0
		_hp_bar.value = frac
		# Label the gauge "Health" + a live percentage (a raw HP number is misleading —
		# it reads as horsepower). Only re-format when the rounded percent changes.
		# Any positive HP rounds UP to at least 1% so "0%" is reserved for a genuine
		# wreck (hp == 0) — otherwise the gauge reads 0% while the car is still alive
		# and the player wonders why nothing happens when they keep driving.
		var pct := 0 if dmg.hp <= 0.0 else maxi(1, roundi(frac * 100.0))
		if pct != _last_hp_pct:
			_last_hp_pct = pct
			_hp_label.text = "HEALTH %d%%" % pct
		# Green (full) → amber → red (empty) via hue; flash by modulating alpha when
		# below the low-HP warning fraction so the danger is unmissable.
		var col := Color.from_hsv(frac * 0.33, 0.8, 0.95)
		if frac < Config.data.hud_low_hp_warn_frac:
			_hp_pulse_t += delta * _HP_PULSE_SPEED
			col.a = lerpf(0.35, 1.0, 0.5 + 0.5 * sin(_hp_pulse_t))
		else:
			_hp_pulse_t = 0.0
		_hp_bar.modulate = col
		# Bump the impact flash on any HP drop since last frame, sized to the loss.
		if _last_hp >= 0.0 and dmg.hp < _last_hp:
			var bump := (_last_hp - dmg.hp) / dmg.max_hp * _IMPACT_FLASH_GAIN
			_impact_flash.color.a = minf(_impact_flash.color.a + bump, _IMPACT_FLASH_MAX)
		_last_hp = dmg.hp
	else:
		_last_hp = -1.0
		_last_hp_pct = -1
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
	_elapsed_label.text = UITheme.format_time(roundi(seconds * 1000.0))


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


# Top-centre pace popup, pulsed by the StageManager every few turns: the player's
# time delta (ms) to the leading (P1) rival at this point. Negative = ahead (green,
# shown as "X.XX ahead of P1"), positive = behind (red, "X.XX behind P1"). Gated by
# hud_stage_delta_enabled; auto-hides after stage_delta_show_seconds.
func show_stage_delta(delta_ms: int) -> void:
	if not Config.data.hud_stage_delta_enabled:
		return
	# The CUT flash shares this spot and takes precedence: suppress the pace
	# readout while a cut flash is still on screen.
	if _cut_flash_left > 0.0:
		return
	var ahead := delta_ms < 0
	var secs := absf(delta_ms / 1000.0)
	_stage_delta_label.text = "%.2f %s P1" % [secs, "ahead of" if ahead else "behind"]
	_stage_delta_label.add_theme_color_override("font_color", UITheme.GREEN if ahead else UITheme.RED)
	_stage_delta_label.visible = true
	_stage_delta_left = Config.data.stage_delta_show_seconds


# Live corner-cut flash, pulsed by StageManager each time TrackProgress bills
# an incident. Shows the running event total (not the incident delta) so
# consecutive incidents read as one growing tag rather than flickering resets.
func show_cut_flash(_incident_s: float, total_s: float) -> void:
	if not Config.data.cut_penalty_enabled:
		return
	_cut_flash_label.text = "CUT +%.1fs" % total_s
	_cut_flash_label.visible = true
	_cut_flash_left = Config.data.stage_delta_show_seconds
	# The CUT flash takes precedence over the pace popup they share a spot with.
	_stage_delta_label.visible = false
	_stage_delta_left = 0.0


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
