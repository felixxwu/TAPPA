class_name ConflictPrompt
extends RefCounted
# The ONE place the "your progress differs" sync conflict is put to the player.
#
# WHY THIS EXISTS. The prompt used to live only in account_menu.gd, which meant
# Cloud.conflict_detected had exactly one subscriber — a node that only exists
# while the account page is open. A conflict raised anywhere else (at sign-in on
# boot, or on a background sync) emitted into nothing, and cloud_sync then refused
# every subsequent push with "Resolve the sync conflict first." So cloud saving
# silently stopped, with the only thing that could clear it hidden behind a page
# the player had no reason to visit. See todo/challenge-career-reuse-drift.md
# item 10.
#
# A conflict is not a page's business — it is the game's. Any screen that can host
# a ConfirmPopup can raise it through here, and they all get the same copy, the
# same three choices and the same resolution calls. Adding a second host must
# never mean re-deriving what "resolve" does.

# True when the cloud layer is holding a conflict that the player has not settled.
# The single predicate every caller should ask — reaching into
# Cloud.sync.blocked_by_conflict directly is how a second, drifting copy of this
# question starts.
static func is_blocked() -> bool:
	return Cloud != null and Cloud.sync != null and Cloud.sync.blocked_by_conflict


# The summary dict for the live conflict, or {} when there isn't one.
static func summary() -> Dictionary:
	if not is_blocked():
		return {}
	return Cloud.sync.conflict_summary()


# Put the conflict to the player on `host`. `on_finished` (optional) is called with
# no arguments once the popup closes, however it closed — hosts use it to clear
# their own "a prompt is already up" latch and to re-check is_blocked().
#
# Returns the popup, or null when there is nothing to ask about OR when a modal is
# already on screen. Callers must not assume a popup came back.
#
# EXCLUSIVITY IS NOT THIS FILE'S JOB ANY MORE. Three hosts raise this prompt (the
# account page, the HQ, and the boot gate) and each used to keep a private "is mine
# up?" bool; they could not see each other, so one conflict_detected broadcast opened
# TWO identical popups and dismissing the top one just revealed the second with focus
# reset — which read as "Use cloud did nothing and moved my focus". This file briefly
# owned a `conflict_prompt` group to fix that, but the same hazard applies to every
# modal in the game, so the rule now lives in ConfirmPopup.MODAL_GROUP and this just
# inherits it: ConfirmPopup.open returns null rather than stacking.
static func open(host: Node, on_finished := Callable()) -> Node:
	var info := summary()
	if info.is_empty():
		return null
	var body := "This device: %s\nCloud (from %s): %s\n\nWhich one should be kept?" % [
		info.get("local", ""), info.get("cloud_device", "another device"),
		info.get("cloud", ""),
	]
	var popup := ConfirmPopup.open(host, "Your progress differs", body, [
		# Keep-this-device UPLOADS the whole profile — a real network round-trip, so it
		# gets the cover. Use-cloud does NOT: the document was already downloaded when
		# the conflict was raised, so applying it is local (parse, migrate, write) and
		# a cover would only flash. Decide-later must go through Cloud.resolve_later()
		# rather than doing nothing — sync stays paused and the account page keeps
		# warning, deliberately not a silent pick of either side.
		{"label": "Decide later", "callback": func() -> void: Cloud.resolve_later()},
		{"label": "Use cloud", "callback": func() -> void: Cloud.resolve_use_cloud()},
		{"label": "Keep this device",
			"callback": func() -> void: await _resolve(host, "Uploading this device's progress…", _keep_local)},
	], 2, 0)  # focus stays on Keep-this-device; Back/Esc = Decide later (index 0)
	if on_finished.is_valid() and popup != null:
		popup.finished.connect(func() -> void: on_finished.call())
	return popup


# Run one resolution behind the SHARED busy cover (scripts/cloud/cloud_busy.gd) so
# the network wait is visible rather than a silent freeze, and so it looks and
# behaves the same as every other cloud wait in the game. CloudBusy owns the
# headless rule (skip the visual, never the await or the decision), the minimum
# visible duration, and the one answer for a failure.
static func _resolve(host: Node, busy_text: String, action: Callable) -> Dictionary:
	var result: Dictionary = await CloudBusy.run_covered(
		host, "Syncing your progress…", busy_text, action)
	# This prompt has no message line of its own, and a resolution that failed
	# silently is exactly how a conflict stays stuck forever — so it gets said.
	CloudBusy.report_failure(host, result)
	return result


static func _keep_local() -> Dictionary:
	return await Cloud.resolve_keep_local()

