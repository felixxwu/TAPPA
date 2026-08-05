class_name HqChallenge
extends RefCounted
# The Rally Challenge screen, extracted from hq.gd to shrink it (todo/hq-split.md). Builds and
# refreshes the Daily/Weekly/Monthly overlay, fetches its leaderboard placing and cutoff, and
# runs the entry path into a challenge stage.
#
# Holds a back-reference to the HqController and reaches into it for state, node parenting,
# widget helpers and callbacks — the same shape as HqOverlays / HQEnvironment.
#
# NOTE the split is deliberately FUNCTIONS-ONLY: the `_challenge_*` state still lives on
# HqController, because ~88 references (64 in test_menu_flow.gd, ~24 in hq_overlays.gd) read
# that state directly, against ~64 that call these functions. Moving the state would have
# tripled the churn for ~3% more of the line count. See todo/hq-split.md.

var _hq: HqController

func _init(hq: HqController) -> void:
	_hq = hq


# --- Rally Challenge overlay (Daily/Weekly/Monthly, spec §7) -----------------
# A modal over the GARAGE: same shape the (now-removed) title-screen Account overlay had —
# _challenge_layer built once in _ready (build_challenge_overlay), shown/hidden here
# rather than folded into the View enum / _update_overlays switch.

func _open_challenge_overlay() -> void:
	var unix_time := int(Time.get_unix_time_from_system())
	# A stale run (period rolled over since it was stored) is discarded here, before the
	# entry screen is built, so a rolled-over period shows a fresh entry rather than a
	# dead Resume button (spec §3). ChallengeSession.has_stale_run/resumable_run/
	# eligible_cars are pure static helpers (no Save dependency, testable with a
	# synthetic profile per challenge_session.gd) called through the autoload the same
	# way every other ChallengeSession call in this file is — the analyzer's "static
	# called on instance" warning is expected here, same as it would be for
	# RallySession.apply_event_config called via the RallySession autoload.
	@warning_ignore("static_called_on_instance")
	if ChallengeSession.has_stale_run(Save.profile, unix_time):
		ChallengeSession.discard_stale_run(unix_time)
	_hq._garage_layer.visible = false
	_hq._challenge_layer.visible = true
	_refresh_challenge_overlay()
	UITheme.enforce(_hq._challenge_layer)
	# Land on the CURRENT kind's own tab, not just tree-order-first (which would always
	# be Daily) — re-opening after switching kind keeps the cursor on the kind you left.
	UITheme.focus_grab(_challenge_kind_button(_hq._challenge_kind))


func _close_challenge_overlay() -> void:
	if _hq._challenge_layer == null:
		return
	# Leaving for the garage is the cache's invalidation point: the board keeps moving,
	# so the next visit asks again rather than showing numbers from the last one.
	_hq._challenge_cutoff_cache.clear()
	_hq._challenge_placing_cache.clear()
	_hq._challenge_layer.visible = false
	_hq._garage_layer.visible = _hq._view == _hq.View.GARAGE


# Switching kind resets any prior car-picker context and instantly re-derives the whole
# screen for the new kind — Resume is only offered when the freshly-shown kind matches
# the stored run's kind (see _refresh_challenge_overlay). Called both by a tab's
# focus_entered (keyboard/gamepad arriving on it) and directly wherever the kind needs
# setting programmatically (e.g. focusing the right tab on open).
func _select_challenge_kind(kind_str: String) -> void:
	_hq._challenge_kind = kind_str
	_refresh_challenge_overlay()


# Ask the board where the player finished and append it to the COMPLETED row.
#
# ALWAYS LIVE, NEVER STORED. A completed record only ever refers to a period that is
# still open (the outcome map is pruned to live periods), so the field keeps growing
# and the player's position keeps moving underneath them. Caching the rank at finish
# time would show a placing that was true once and is quietly wrong now.
#
# Non-blocking on purpose: the row reads COMPLETED the instant the page opens and
# gains "- 3 of 42" when the answer arrives. This is decoration on an already-correct
# label, so it gets no CloudBusy cover — there is nothing to wait for and nothing the
# player is prevented from doing — and a failure is simply not rendered.
func _fetch_challenge_placing(period_key_str: String, stage_count: int, generation: int) -> void:
	if period_key_str == "" or stage_count <= 0:
		return
	# Already answered this visit (a tab switch, not a fresh open) — render it straight
	# away. No query, and no "Loading…" flash on a row the player has already seen.
	if _hq._challenge_placing_cache.has(period_key_str):
		_apply_challenge_placing(_hq._challenge_placing_cache[period_key_str])
		return
	if Cloud == null or Cloud.challenge_leaderboard == null:
		return
	# SIGNED OUT: don't ask. fetch_final_rank needs a token to find the player's own
	# row, so it can only ever answer "not ok" here — but fetch_standings_at issues
	# the board query BEFORE it discovers that, which would mean a real network round
	# trip on every visit to the page, for an answer that cannot exist.
	if not Cloud.is_signed_in():
		return
	# Say we're fetching rather than leaving the placing to pop in later. Only from
	# here — past every "we are not going to ask" guard above — so a row that will
	# never gain a placing doesn't advertise one.
	_set_challenge_completed_text("Loading…")
	var info := await Cloud.challenge_leaderboard.fetch_final_rank(period_key_str, stage_count)
	# Cached BEFORE the staleness check: the answer is valid for its period whatever is
	# on screen now, so a player who switched tabs mid-flight still gets it instantly on
	# switching back, rather than paying for the same query twice.
	if bool(info.get("ok", false)):
		_hq._challenge_placing_cache[period_key_str] = info
	# The player can switch tabs (or leave HQ entirely) while this is in flight, so
	# check the row hasn't been rebuilt under us before writing to it — otherwise the
	# Daily's placing lands on the Weekly's row. See _challenge_refresh_generation for
	# why this is a counter and not "does the label still read what I left it at".
	if not _hq.is_inside_tree() or generation != _hq._challenge_refresh_generation:
		return
	_apply_challenge_placing(info)


# Render a placing answer onto the COMPLETED row (shared by the live and cached paths).
func _apply_challenge_placing(info: Dictionary) -> void:
	if not is_instance_valid(_hq._challenge_progress_label):
		return
	if not bool(info.get("ok", false)):
		# Signed out, no username, or the board is unreachable — fall back to a bare
		# COMPLETED. The placeholder is not a resting state.
		_set_challenge_completed_text("")
		return
	_set_challenge_completed_text("%d of %d" % [
		int(info.get("rank", 0)), int(info.get("total_entries", 0))])


# Write the win-condition row as "<condition>" or "<condition> - <tail>". ALWAYS
# rebuilt from _CHALLENGE_WIN_CONDITION rather than appended to whatever is on screen,
# so the transient "Loading…" can't end up cemented in front of the answer — and
# uppercased here, because UITheme.enforce only runs on the open path and this row is
# also rewritten later, asynchronously, long after that pass.
func _set_challenge_win_text(tail: String) -> void:
	if not is_instance_valid(_hq._challenge_win_label):
		return
	var text := _CHALLENGE_WIN_CONDITION
	if tail != "":
		text += " - " + tail
	_hq._challenge_win_label.text = UITheme.caps(text)


# Display name for one owned car dict from a ChallengeSession.classify_cars bucket
# (whose entries always resolve to a real catalogue entry — classify skips the rest).
func _challenge_car_name(car: Dictionary) -> String:
	return EngineSwap.display_name(CarLibrary.by_id(String(car.get("model_id", ""))), car)


# Write the progress row's COMPLETED state as "COMPLETED" or "COMPLETED - <tail>".
# Same contract as _set_challenge_win_text: always rebuilt from the constant rather
# than appended to what's on screen, so the transient "Loading…" can't survive in
# front of the placing, and uppercased here because this row is rewritten
# asynchronously long after the one-shot UITheme.enforce pass.
func _set_challenge_completed_text(tail: String) -> void:
	if not is_instance_valid(_hq._challenge_progress_label):
		return
	var text := "COMPLETED"
	if tail != "":
		text += " - " + tail
	_hq._challenge_progress_label.text = UITheme.caps(text)


# Fill in the CURRENT time on the top-50% cut line, so the win condition reads
# "Top 50% - 1:52.24" rather than an abstract percentage the player can't aim at.
# Appended to the SAME row (no separate line) — the entry screen is a compact HUD
# readout, and a bare percentage gives nothing to chase.
#
# Never persisted, and re-asked on every fresh open of the screen, for the same reason
# the completed placing is (see _fetch_challenge_placing): the cut line MOVES as
# entrants arrive and times improve, so a number saved across sessions would be quietly
# wrong. Within ONE visit it is cached per period key (see _challenge_cutoff_cache) so
# flipping between the Daily/Weekly/Monthly tabs doesn't re-query what it just asked.
#
# Non-blocking and undecorated on failure: the row is already correct without the
# time, so there's no CloudBusy cover and an unreachable board just leaves
# "Top 50%" standing.
func _fetch_challenge_cutoff(period_key_str: String, stage_count: int, generation: int) -> void:
	if period_key_str == "" or stage_count <= 0:
		return
	# Already answered this visit (a tab switch, not a fresh open) — render it straight
	# away. No query, and no "Loading…" flash on a row the player has already seen.
	if _hq._challenge_cutoff_cache.has(period_key_str):
		_apply_challenge_cutoff(_hq._challenge_cutoff_cache[period_key_str])
		return
	if Cloud == null or Cloud.challenge_leaderboard == null:
		return
	# SIGNED OUT: don't ask. The board itself is world-readable (firestore.rules
	# `allow read: if true`), so this query WOULD answer — but a signed-out player
	# cannot post a checkpoint at all, so there is no cut for them to make, and asking
	# anyway means a real network round trip on every visit to this page.
	if not Cloud.is_signed_in():
		return
	# Say we're fetching rather than leaving a gap the time will pop into. Only from
	# here — past every "we are not going to ask" guard above — so a signed-out player
	# never sees a "Loading…" that resolves to nothing.
	_set_challenge_win_text("Loading…")
	var info := await Cloud.challenge_leaderboard.fetch_cutoff(period_key_str, stage_count)
	# Cached BEFORE the staleness check — see the same note in _fetch_challenge_placing.
	if bool(info.get("ok", false)):
		_hq._challenge_cutoff_cache[period_key_str] = info
	# The player can switch tabs (or leave HQ) while this is in flight — don't land the
	# Daily's cut line on the Weekly's row. Generation, not a text comparison: the row is
	# UPPERCASED by UITheme.enforce after it is built (see _challenge_refresh_generation),
	# so matching on the text silently dropped every answer.
	if not _hq.is_inside_tree() or generation != _hq._challenge_refresh_generation:
		return
	_apply_challenge_cutoff(info)


# Render a cut-line answer onto the win row (shared by the live and cached paths).
func _apply_challenge_cutoff(info: Dictionary) -> void:
	if not is_instance_valid(_hq._challenge_win_label):
		return
	if not bool(info.get("ok", false)) or not bool(info.get("exists", false)):
		# Unreachable, or nobody is on the line yet (any finish currently makes it).
		# Either way the placeholder must come back off — it is not a resting state.
		_set_challenge_win_text("")
		return
	_set_challenge_win_text(UITheme.format_time(int(info.get("cutoff_ms", 0))))


# The tab button for `kind_str` (Daily/Weekly/Monthly), matched by list position —
# _challenge_kind_buttons is built in the same [DAILY, WEEKLY, MONTHLY] order every time.
func _challenge_kind_button(kind_str: String) -> Button:
	var kinds := [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]
	var idx := kinds.find(kind_str)
	if idx < 0 or idx >= _hq._challenge_kind_buttons.size():
		return null
	return _hq._challenge_kind_buttons[idx]


# Player-facing summary of ChallengeSession._COMPLETION_REWARD — keep the two in
# step when the reward table is retuned.
# What placing pays, per kind. Must match ChallengeSession._COMPLETION_REWARD plus the
# stars-by-placement award — the challenge stopped granting CARS when cars became something
# you buy with stars (todo/star-economy.md), and advertising one here would promise a reward
# the game no longer hands out.
#
# Stars are quoted as a range because the payout is placement-based (1st/2nd/3rd -> 3/2/1)
# while PLACING is the top half of the board, so a mid-table finish legitimately banks none.
const _CHALLENGE_REWARD_TEXT := {
	"daily": "2 mystery boxes + up to 3 stars",
	"weekly": "3 mystery boxes + up to 3 stars",
	"monthly": "4 mystery boxes + up to 3 stars",
}
const _CHALLENGE_WIN_CONDITION := "Top 50%"


# Rebuild the whole entry screen from ChallengeSession/ChallengeLibrary's current state:
# header (kind + ceiling) and the four sections (win condition, win reward, eligible
# cars, current progress), then the Start/Resume button. Every row is a short phrase,
# not a sentence — this is a HUD readout, not prose.
func _refresh_challenge_overlay() -> void:
	if _hq._challenge_layer == null:
		return
	# Invalidate any board query still in flight for the PREVIOUS build of this screen.
	_hq._challenge_refresh_generation += 1
	var generation := _hq._challenge_refresh_generation
	_hq._challenge_title_label.text = "%s Challenge" % _hq._challenge_kind.capitalize()
	# Highlight the current kind's tab — a font-colour swap (GOLD vs. the house default)
	# rather than a toggled "pressed" look, since these buttons have no toggle_mode/press
	# state at all (no mouse interaction reaches them; see _challenge_kind_buttons).
	for btn in _hq._challenge_kind_buttons:
		var is_current := String(btn.get_meta("challenge_kind", "")) == _hq._challenge_kind
		btn.add_theme_color_override("font_color", UITheme.GOLD if is_current else UITheme.INK_DIM)

	var unix_time := int(Time.get_unix_time_from_system())
	# The period dict itself is needed below (cutoff/placing fetches, stage count), so this
	# site keeps it rather than going through ChallengeLibrary.current_ceiling.
	var period := ChallengeLibrary.current_period(_hq._challenge_kind, unix_time)
	# The DISPLAYED ceiling is also the one eligibility is judged against — see
	# ChallengeSession.displayed_ceiling.
	@warning_ignore("static_called_on_instance")
	var ceiling := ChallengeSession.displayed_ceiling(_hq._challenge_kind, unix_time)
	_hq._challenge_subtitle_label.text = "%d hp/t max" % ceiling

	_set_challenge_win_text("")
	_fetch_challenge_cutoff(String(period.get("key", "")),
		int(period.get("stage_count", 0)), generation)
	_hq._challenge_reward_label.text = str(_CHALLENGE_REWARD_TEXT.get(_hq._challenge_kind, ""))

	@warning_ignore("static_called_on_instance")
	var resumable := ChallengeSession.resumable_run(Save.profile, unix_time)
	# Resume is only offered for the SAME kind the resumable run belongs to — switching
	# the kind while a different kind's run is stored still shows that other kind's fresh
	# Start (its own eligible cars/ceiling), not a mismatched Resume button.
	var resuming := not resumable.is_empty() and String(resumable.get("kind", "")) == _hq._challenge_kind

	# Eligible cars — NAME them (capped + "+N more"), same as the rally pin detail
	# panel's own eligibility read-out (_eligibility_summary/_qualifying_cars_text),
	# not just a count. ChallengeSession.classify_cars owns the ready-now vs.
	# needs-a-tune split (the latter mirroring _eligibility_summary's "adjust" bucket);
	# this site only turns the two buckets into names.
	@warning_ignore("static_called_on_instance")
	var classified := ChallengeSession.classify_cars(_hq._challenge_kind, Save.profile, unix_time)
	var eligible: Array = classified["eligible"]
	var ready_names: Array[String] = []
	var tune_names: Array[String] = []
	for car in classified["ready"]:
		ready_names.append(_challenge_car_name(car))
	for car in classified["needs_tune"]:
		tune_names.append(_challenge_car_name(car))
	if resuming:
		# A run in progress has no choice left to make — the car was committed when it
		# started and is locked to it for the rest of the period. Listing the whole
		# eligible set here would imply you could still switch; name the ONE car you
		# actually picked instead, which also explains why it has disappeared from the
		# garage/career pickers.
		var locked := Save.get_car(int(resumable.get("car_instance_id", -1)))
		var locked_entry := CarLibrary.by_id(String(locked.get("model_id", "")))
		_hq._challenge_eligible_label.text = EngineSwap.display_name(locked_entry, locked) \
			if not locked_entry.is_empty() else "Your locked car"
		_hq._challenge_eligible_label.add_theme_color_override("font_color", UITheme.GOLD)
	elif eligible.is_empty():
		_hq._challenge_eligible_label.text = "No eligible car"
		_hq._challenge_eligible_label.add_theme_color_override("font_color", UITheme.RED)
	else:
		var text := _hq._qualifying_cars_text(ready_names) if not ready_names.is_empty() else "None ready"
		if not tune_names.is_empty():
			text += "\nNeeds tune: %s" % _hq._qualifying_cars_text(tune_names)
		_hq._challenge_eligible_label.text = text
		_hq._challenge_eligible_label.add_theme_color_override(
			"font_color", UITheme.GREEN if not ready_names.is_empty() else UITheme.GOLD)

	# Current progress — the stored run for THIS kind, if any, else this period's
	# terminal outcome. A finished period is one attempt spent: completed or DNF'd,
	# both terminal until the period rolls over, so Start stays disabled.
	@warning_ignore("static_called_on_instance")
	var outcome := ChallengeSession.period_outcome(Save.profile, String(period.get("key", "")))
	var finished := not outcome.is_empty()
	if resuming:
		var done := int(resumable.get("stage_index", 0))
		var total := int(period.get("stage_count", 0))
		# Say the run is LIVE, not just how far it got — a bare "0 / 2 stages" reads
		# identically to "not started" and gives no hint that this kind is holding a
		# car locked (which is why that car has vanished from the other pickers).
		_hq._challenge_progress_label.text = "IN PROGRESS - %d/%d stages" % [done, total]
		_hq._challenge_progress_label.add_theme_color_override("font_color", UITheme.GOLD)
	elif finished and bool(outcome.get("dnf", false)):
		_hq._challenge_progress_label.text = "DNF"
		_hq._challenge_progress_label.add_theme_color_override("font_color", UITheme.RED)
	elif finished:
		# Show COMPLETED immediately and fetch the placing LIVE — never a stored one.
		# Only live periods survive the outcome prune, so every completed record on
		# screen belongs to a board that is still open: more entrants keep arriving
		# and faster times keep pushing the player down, so a rank saved at finish
		# time is stale by construction.
		_set_challenge_completed_text("")
		_hq._challenge_progress_label.add_theme_color_override("font_color", UITheme.GREEN)
		_fetch_challenge_placing(String(period.get("key", "")),
			int(period.get("stage_count", 0)), generation)
	else:
		_hq._challenge_progress_label.text = "Not started"
		# Cleared explicitly: the label is reused across kind switches, so a colour
		# left over from a previous kind's IN PROGRESS/DNF would stick.
		_hq._challenge_progress_label.remove_theme_color_override("font_color")

	_hq._challenge_start_button.text = "Resume" if resuming else "Start"
	# A spent period can't be re-entered, however many eligible cars are sitting there.
	_hq._challenge_start_button.disabled = not resuming and (finished or eligible.is_empty())
	UITheme.enforce(_hq._challenge_layer)


# Start/Resume. Resume (spec §3: same kind as the stored run) calls ChallengeSession.resume
# directly — no car to pick, the locked car is already fixed. Otherwise this now OPENS the
# real 3D car park (spec §7 point 4) restricted to this kind's eligible cars, instead of
# committing straight from a focused button-list item; the car park's own Start
# (_begin_challenge_start) does the actual ChallengeSession.start + scene hand-off.
# Enter/gamepad-accept on a focused kind tab acts as Start, exactly as if the Start
# button itself had focus — the player shouldn't have to tab down to Start first once
# they've settled on a kind. Respects the SAME disabled gate Start does (no eligible
# car): a Button's `pressed` signal fires on activate regardless of a DIFFERENT
# button's disabled state, so that has to be checked here explicitly rather than
# relying on Godot to block it.
func _on_challenge_tab_activated() -> void:
	if not _hq._challenge_start_button.disabled:
		_on_challenge_start_pressed()


func _on_challenge_start_pressed() -> void:
	var unix_time := int(Time.get_unix_time_from_system())
	@warning_ignore("static_called_on_instance")
	var resumable := ChallengeSession.resumable_run(Save.profile, unix_time)
	if not resumable.is_empty() and String(resumable.get("kind", "")) == _hq._challenge_kind:
		# Resume runs the same pre-flight a fresh start does — the mobile control-scheme
		# gate applies whether or not there's a car left to pick (the car is already
		# committed, hence no select id here).
		_close_challenge_overlay()  # before the gate, so the picker isn't drawn over
		if not _hq._start_preflight(_on_challenge_start_pressed):
			return
		if not ChallengeSession.resume(unix_time):
			return
		await _hand_off_to_challenge_scene()
		return
	_close_challenge_overlay()
	_enter_challenge_car_screen(_hq._challenge_kind)


# Hand off to the driving scene the same way a normal rally does (_begin_rally_start): a
# loading screen, two frames for it to paint, then the scene load — gated on
# ChallengeSession.auto_load_scenes (mirrors RallySession.auto_load_scenes) so tests can
# drive start()/resume() with no scene load.
#
# world.gd already branches on ChallengeSession.is_active() when it boots (building the
# current stage's TrackGenParams from ChallengeSession.current_stage_params() and routing
# StageManager.stage_completed to ChallengeSession.report_event_result / take_pending_repair
# instead of RallySession's — spec §3's single-call-site mode branch), so this plain scene
# load is enough to hand off — no RallySession needs to be active for a challenge run.
func _hand_off_to_challenge_scene() -> void:
	# No config seating here: world.gd._ready pulls the first stage's track
	# parameters itself via DrivingContext.apply_stage_config, so this hand-off is
	# a plain scene load with no ordering dependency to forget.
	if ChallengeSession.auto_load_scenes:
		var loading := LoadingScreen.new()
		loading.set_step("Preparing challenge…")
		_hq.add_child(loading)
		await _hq.get_tree().process_frame
		await _hq.get_tree().process_frame
		_hq.get_tree().change_scene_to_file("res://main.tscn")


# Open the car park for the currently-shown challenge kind: park the eligible owned cars
# (plus any over-ceiling car a detune would fit under, tracked via _detune_needed — see
# _build_challenge_lineup) and frame the first. With none, show a hint + disable Start.
# Mirrors _enter_car_screen's shape for _hq.CarparkMode.RALLY.
func _enter_challenge_car_screen(kind_str: String) -> void:
	_hq._carpark_mode = _hq.CarparkMode.CHALLENGE
	_hq._challenge_kind = kind_str
	_hq._start_button.text = "Start Challenge"
	_build_challenge_lineup(kind_str)
	var unix_time := int(Time.get_unix_time_from_system())
	@warning_ignore("static_called_on_instance")
	var ceiling := ChallengeSession.displayed_ceiling(kind_str, unix_time)
	_hq._rally_banner.text = "%s Challenge — needs <= %d hp/tonne" % [kind_str.capitalize(), ceiling]
	_hq._view = _hq.View.CARPARK
	_hq._detail_open = false
	_hq._update_overlays()
	if _hq._eligible.is_empty():
		_hq._show_empty_carpark("No eligible car for this challenge — none of your cars meet the ceiling.")
		return
	_hq._no_eligible_label.visible = false
	_hq._focus = 0
	_hq._carpark_ui._focus_changed(true)


# Park the owned cars ChallengeSession.classify_cars(kind, ...) reports for `kind_str`
# (already challenge-lock-excluded per §2). The classification — including which of them
# are over the DISPLAYED ceiling but reachable by lowering detune, and at what absolute
# slider setting — is computed once there and simply forwarded here: those cars park
# looking eligible, and pressing Start pops the same over-limit prompt
# _build_eligible_lineup's rally cars use.
func _build_challenge_lineup(kind_str: String) -> void:
	var unix_time := int(Time.get_unix_time_from_system())
	@warning_ignore("static_called_on_instance")
	var classified := ChallengeSession.classify_cars(kind_str, Save.profile, unix_time)
	# clears _detune_needed / _drivetrain_needed, repopulated below
	_hq._carpark_ui._build_lineup(classified["eligible"])
	_hq._detune_needed = classified["detune"]
	_hq._drivetrain_needed = {}


# Commit the focused car park selection: ChallengeSession.start, then the same scene
# hand-off Resume uses. Mirrors _begin_rally_start's shape for _hq.CarparkMode.CHALLENGE.
func _begin_challenge_start() -> void:
	var owned := Save.get_car(_hq._selected_instance_id)
	if owned.is_empty():
		return
	# The same pre-flight the career start runs (mobile control-scheme gate + select the
	# fielded car) — a challenge used to skip both.
	if not _hq._start_preflight(_begin_challenge_start, _hq._selected_instance_id):
		return
	var unix_time := int(Time.get_unix_time_from_system())
	if not ChallengeSession.start(_hq._challenge_kind, owned, unix_time):
		return
	_hq._carpark_ui._clear_lineup()
	_hq._selected_instance_id = -1
	_hq._carpark_mode = _hq.CarparkMode.RALLY
	await _hand_off_to_challenge_scene()
