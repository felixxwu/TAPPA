class_name ConflictPrompt
extends RefCounted
# Docs: features/cloud-save.md — update in the same change as this file.
# Tests: tests/headless/test_cloud_sync.gd — extend in the same change.
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


# Put the conflict to the player on `host`. `on_finished` (optional) is called with no
# arguments once the chosen action has finished, including any upload behind it — hosts
# use it to hand play back and to re-check is_blocked().
#
# Returns the popup, or null when there is nothing to ask about OR when a modal is
# already on screen. Callers must not assume a popup came back.
#
# Two hosts raise this prompt (the account page, and free roam for a conflict found in the
# background). ConfirmPopup.MODAL_GROUP keeps them from stacking: open returns null instead.
static func open(host: Node, on_finished := Callable()) -> Node:
	var info := summary()
	if info.is_empty():
		return null
	var body := "This device: %s\nCloud (from %s): %s\n\nWhich one should be kept?" % [
		info.get("local", ""), info.get("cloud_device", "another device"),
		info.get("cloud", ""),
	]
	var done := func() -> void:
		if on_finished.is_valid():
			on_finished.call()
	return ConfirmPopup.open(host, "Your progress differs", body, [
		# Keep-this-device UPLOADS the whole profile — a real network round-trip, so it
		# gets the cover. Use-cloud does NOT: the document was already downloaded when
		# the conflict was raised, so applying it is local (parse, migrate, write) and
		# a cover would only flash. Decide-later must go through Cloud.resolve_later()
		# rather than doing nothing — sync stays paused and the account page keeps
		# warning, deliberately not a silent pick of either side.
		{"label": "Decide later", "callback": func() -> void:
			Cloud.resolve_later()
			done.call()},
		{"label": "Use cloud", "callback": func() -> void:
			Cloud.resolve_use_cloud()
			done.call()},
		{"label": "Keep this device", "callback": func() -> void:
			await _resolve(host, "Uploading this device's progress…", _keep_local)
			done.call()},
	], 0, 0)  # the cursor and Back/Esc both start on Decide later, the one choice that overwrites nothing


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
	var notice := CloudBusy.report_failure(host, result)
	if notice != null:
		await notice.finished
	return result


static func _keep_local() -> Dictionary:
	return await Cloud.resolve_keep_local()

