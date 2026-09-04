class_name CloudBusy
extends RefCounted
# Docs: features/cloud-save.md — update in the same change as this file.
# Tests: tests/headless/test_cloud_sync.gd — extend in the same change.
# The ONE way the game says "a cloud call is in flight".
#
# WHY THIS EXISTS. Every screen that awaited Cloud invented its own waiting UI,
# or none: account_menu.gd had a private _begin/_finish, hq.gd and
# conflict_prompt.gd each rolled their own covering LoadingScreen, global_standings
# had an in-panel LOADING state, and challenge_session had NOTHING — which is the
# silent pause a player reported at the end of a run, and the one that made them
# say "I clicked it and nothing happened for a while". "Show that we are waiting on
# the network" is a rule, and it was re-derived per call site until the derivations
# disagreed. See todo/challenge-career-reuse-drift.md item 11.
#
# It is a static helper over a Callable (plus a begin/end pair for call sites that
# must keep their `await` direct), NOT an autoload: a busy state belongs to the
# node that is waiting, and there is never a global one.
#
# TWO SHAPES, deliberately — forcing every site into one was the wrong answer:
#
#   cover()   A full-screen LoadingScreen. For calls that rewrite the whole
#             profile or gate progression: conflict resolution, sign-in, the boot
#             restore. Blocking is the honest signal there — the player must not
#             act on a career that is about to be replaced.
#   ambient() An in-panel line, or just the marker when the host already renders
#             its own. For reads behind UI that is already on screen (leaderboard
#             fetches). A modal over a leaderboard would be worse than nothing.
#
# HEADLESS: skip the VISUAL, never the await and never the decision — the rule
# ConflictPrompt._resolve already follows
# (features/testing.md). The marker node is created in EVERY environment, so
# `CloudBusy.showing(host)` answers the same headless as on screen and tests can
# prove the relationship (busy during the call, gone after) rather than guessing.

# How long a COVER stays up once shown, at minimum. A round trip that lands in
# 50 ms must not flash a full-screen cover for one frame — that reads as a glitch,
# not as feedback. Covers only: an ambient line appearing and vanishing quickly is
# not the problem this floor exists to solve, and holding a rally's leaderboard
# fetch open for the floor would slow the game down for nothing.
#
# Not applied headless (there is nothing to see, and it would tax every test run),
# which is safe precisely because it is a look, not a decision.
const MIN_COVER_VISIBLE_SEC := 0.45

# Every busy visual joins this group, so a host that rebuilds its children
# wholesale can preserve the in-flight state instead of freeing it mid-call
# (see account_menu.rebuild / global_standings._build_ui).
const GROUP := "cloud_busy"

# The ONE thing the player is told when a cloud call fails without saying why.
# Every site used to answer this differently, and some swallowed it entirely.
const GENERIC_FAILURE := "Couldn't reach the cloud. Check your connection and try again."

var _host: Node
var _marker: Node          # in GROUP; exists headless too — the testable state
var _cover: LoadingScreen  # cover mode only, and never headless
var _shown_msec := 0
var _cover_mode := false
var _ended := false


# --- Starting -----------------------------------------------------------------

# A blocking cover over `host`. `title` is the headline, `step` the detail line.
static func cover(host: Node, title: String, step: String) -> CloudBusy:
	var busy := CloudBusy.new()
	busy._host = host
	busy._cover_mode = true
	busy._shown_msec = Time.get_ticks_msec()
	if not is_instance_valid(host) or not host.is_inside_tree():
		return busy
	busy._marker = Node.new()
	busy._marker.name = "CloudBusyMarker"
	busy._marker.add_to_group(GROUP)
	host.add_child(busy._marker)
	if not Platform.is_headless():
		busy._cover = LoadingScreen.new()
		busy._cover.set_title(title)
		busy._cover.set_step(step)
		host.add_child(busy._cover)
	return busy


# An ambient busy state on `host`. When `container` is given, `text` is rendered
# into it as a dim in-panel line (that line IS the marker, so a host rebuild that
# preserves GROUP keeps it). When it is null the host already draws its own
# waiting line — global_standings' LOADING status row — and only the invisible
# marker is added, so the relationship stays observable without a second line
# saying the same thing twice.
static func ambient(host: Node, text: String, container: Node = null) -> CloudBusy:
	var busy := CloudBusy.new()
	busy._host = host
	busy._shown_msec = Time.get_ticks_msec()
	if not is_instance_valid(host) or not host.is_inside_tree():
		return busy
	var parent: Node = container if is_instance_valid(container) else host
	if is_instance_valid(container):
		busy._marker = UITheme.label(text, "dim")
	else:
		busy._marker = Node.new()
	busy._marker.name = "CloudBusyMarker"
	busy._marker.add_to_group(GROUP)
	parent.add_child(busy._marker)
	return busy


# --- Ending -------------------------------------------------------------------

# Take the busy state down. A coroutine: in cover mode it holds the floor above
# first. Safe to call twice, and safe after the host has gone away.
func end() -> void:
	if _ended:
		return
	_ended = true
	if _cover_mode and not Platform.is_headless():
		var elapsed := float(Time.get_ticks_msec() - _shown_msec) / 1000.0
		var remaining := MIN_COVER_VISIBLE_SEC - elapsed
		var tree := _host.get_tree() if is_instance_valid(_host) else null
		if remaining > 0.0 and tree != null:
			await tree.create_timer(remaining).timeout
	if is_instance_valid(_cover):
		_cover.finish()
	if is_instance_valid(_marker):
		_marker.get_parent().remove_child(_marker)
		_marker.queue_free()


# --- Wrapping a call ----------------------------------------------------------
#
# `action` is awaited, so a coroutine stays a coroutine. Call sites that must keep
# their await literally direct (global_standings documents why — a Callable hop is
# resolved at runtime, and routing the LIVE path through the test seam is the one
# thing its tests could never catch) should use cover()/ambient() + end() instead.

# Run `action` behind a cover and return its normalised result.
static func run_covered(host: Node, title: String, step: String,
		action: Callable) -> Dictionary:
	var busy := CloudBusy.cover(host, title, step)
	var raw: Variant = await action.call()
	await busy.end()
	return result_of(raw)


# Run `action` behind an ambient state and return its normalised result.
static func run_ambient(host: Node, text: String, action: Callable,
		container: Node = null) -> Dictionary:
	var busy := CloudBusy.ambient(host, text, container)
	var raw: Variant = await action.call()
	await busy.end()
	return result_of(raw)


# --- Results ------------------------------------------------------------------

# Cloud.* answers with {"ok": bool, "error": String}. Anything else — a bare bool
# from await_initial_sync, a null, a malformed reply — is coerced here rather than
# at five call sites. A non-dict is NOT treated as a failure: those calls simply do
# not report one, and inventing an error the player then sees would be worse than
# the silence this replaces.
static func result_of(raw: Variant) -> Dictionary:
	if raw is Dictionary:
		return {"ok": bool((raw as Dictionary).get("ok", false)),
			"error": String((raw as Dictionary).get("error", ""))}
	if raw is bool:
		return {"ok": raw, "error": ""}
	return {"ok": true, "error": ""}


# The ONE answer to "what does the player see when a cloud call fails" — the
# server's own words when it gave any, and one plain sentence when it did not.
# Returns "" for a result that did not fail, so a caller can use it as the whole
# test of whether there is anything to say.
static func failure_text(raw: Variant) -> String:
	var result := result_of(raw)
	if bool(result.get("ok", false)):
		return ""
	var reported := String(result.get("error", "")).strip_edges()
	return reported if reported != "" else GENERIC_FAILURE


# Put a failure to the player as a dismissible popup, for hosts that have no
# message line of their own (ConflictPrompt). Hosts that DO have one — the account
# page's red row — should render failure_text() there instead of stacking a modal
# on top of it. No-op on success, and headless (no popup to show; the caller's
# state is already correct either way).
static func report_failure(host: Node, raw: Variant) -> void:
	var text := failure_text(raw)
	if text == "" or Platform.is_headless() or not is_instance_valid(host) \
			or not host.is_inside_tree():
		return
	# allow_stack: a failure notice is the one modal that must be seen even over
	# another one. Everything else is refused when a modal is already up, but a
	# silently dropped "couldn't sync" is exactly how a failed resolution becomes
	# invisible and the conflict stays stuck forever.
	ConfirmPopup.open(host, "Couldn't sync", text, [{"label": "OK"}], 0, 0, true)


# --- Introspection (hosts + tests) --------------------------------------------

# True while a cloud call started on `host` (or anywhere under it) is in flight.
# The one predicate a test should ask — reaching for a particular LoadingScreen or
# label is how a second, drifting copy of this question starts.
static func showing(host: Node) -> bool:
	if not is_instance_valid(host):
		return false
	for node in host.get_children():
		if node.is_in_group(GROUP):
			return true
		if node.get_child_count() > 0 and showing(node):
			return true
	return false
