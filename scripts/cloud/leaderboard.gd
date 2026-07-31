class_name Leaderboard
extends Node
# Global per-stage leaderboards: one Firestore document per player per stage, at
#   stage_times/{stage_key}/times/{uid}
#
# Owned by Cloud alongside `sync`. This class knows NOTHING about rallies, cars
# or events — it is handed a stage key, a time in milliseconds and a row identity
# (name / car name / car id) and answers with a plain result dictionary. The
# caller (GlobalStandings) owns every decision about what those strings mean.
#
# NOTHING HERE MAY COST A PLAYER THEIR RALLY. Every failure — offline, timeout,
# 5xx, 429, a rules denial, an unparseable body — collapses into the single
# result `{"ok": false}`, which the page renders as one dim "unavailable" line.
# There is no retry loop, no popup and no blocking.
#
# The board is world-readable by design (see firestore.rules), so a signed-out
# player still gets the top rows and the total; they simply have no row of their
# own to rank. A signed-out fetch sends NO Authorization header at all.

# How many top entries the board shows. Not a balance value — it is the page's
# layout, and the trimming logic below is what is actually under test.
const PODIUM_ROWS := 3

# Why this call did or did not write a document. Reported on every result as
# `post_state`, and logged once per call. These are diagnostic, not UI states —
# the page still only distinguishes loading / signed out / no username / posted /
# unavailable.
const POST_POSTED := "posted"              # a document was written
const POST_NOT_FASTER := "not_faster"      # existing entry is already as good
const POST_SIGNED_OUT := "signed_out"      # no account, so nowhere to write
const POST_NO_USERNAME := "no_username"    # signed in but never chose a name
const POST_NO_TIME := "no_time"            # DNF, or no player row in the standings
const POST_NO_KEY := "no_stage_key"        # the caller had no stage identity
const POST_DENIED := "denied"              # the rules refused the write (401/403)
const POST_FAILED := "failed"              # offline / 5xx / 429 / unreadable
const POST_TOO_FAST := "too_fast"          # below MIN_POST_MS — not a real run

# A stage time under ten seconds is not a driven lap. It is a dev shortcut
# (`RallySession.dev_complete_rally` credits every event 0 ms), a restart, or a
# finish line clipped by a spawn/teleport — and a board is worthless the moment
# one of those sits at P1 where nobody can ever beat it.
#
# NOT a balance value, so it is not in game_config.tres: it is a floor on what
# counts as a real attempt at all, and no reasonable authored stage approaches it
# (the shortest events are tens of turns long). Raising it into the range of a
# genuine time would be a bug, not a retune.
#
# This is a CLIENT-side guard on our own honest paths, not an anti-cheat measure.
# firestore.rules only bounds time_ms > 0 and < 24h; someone determined to post a
# fake time still can, which is the accepted trade recorded in
# features/global-leaderboards.md.
const MIN_POST_MS := 10000

# Injected by Cloud.
var rest = null
var auth: AuthService = null


# --- Public API ---------------------------------------------------------------

# Post `time_ms` to `stage_key` if it beats this player's stored entry, then read
# the board back. This is the one call the UI makes.
#
#   identity — {"name": String, "car_name": String, "car_id": String}
#
# Submitting is skipped entirely (and only the read happens) when the player is
# signed out, has not chosen a username yet, or has an existing entry that is
# already as fast. See `fetch` for the returned shape.
#
# EVERY path through this function ends in exactly one `post_state` (see the
# constants below) and exactly one log line. There are eight distinct reasons a
# finished stage can produce no document, and without that they are all
# indistinguishable from the outside — which is precisely how "I drove a stage
# and there is no collection" became unanswerable once.
func submit_and_fetch(stage_key: String, time_ms: int, identity: Dictionary) -> Dictionary:
	if stage_key == "":
		return _log(_unavailable("No stage key."), POST_NO_KEY, stage_key, "")
	if not _signed_in():
		return _log(await fetch(stage_key), POST_SIGNED_OUT, stage_key, "")

	var display_name := String(identity.get("name", "")).strip_edges()
	if display_name == "":
		return _log(await fetch(stage_key), POST_NO_USERNAME, stage_key, "")
	if time_ms <= 0:
		return _log(await fetch(stage_key), POST_NO_TIME, stage_key,
			"time_ms=%d (a DNF has nothing to post)" % time_ms)
	# Read the board, but write nothing: the player still sees where they stand,
	# they just do not put an impossible time on it. Deliberately silent on the
	# page — there is no honest way for a player to arrive here, so a message
	# would only ever be read by a developer, and the log line says it.
	if time_ms < MIN_POST_MS:
		return _log(await fetch(stage_key), POST_TOO_FAST, stage_key,
			"time_ms=%d is below the %d ms floor (not a driven stage)"
				% [time_ms, MIN_POST_MS])

	var fresh := await auth.ensure_fresh_token()
	if not fresh.ok:
		return _log(_unavailable(String(fresh.get("error", ""))), POST_FAILED, stage_key,
			String(fresh.get("error", "")))

	# Read own entry -> decide -> write if faster -> read the board. The player's
	# own current time is what the improvement check needs, and only their own
	# document can supply it: the top-3 query usually will not contain them.
	var mine := await _read_own(stage_key)
	if not mine.ok:
		return _log(_unavailable(mine.error), POST_FAILED, stage_key,
			"could not read own entry: " + String(mine.error))

	var state := POST_NOT_FASTER
	var detail := ""
	if mine.time_ms <= 0 or time_ms < mine.time_ms:
		var write := await _write_entry(stage_key, time_ms, identity)
		state = String(write.state)
		detail = String(write.error)
		if not write.ok:
			return _log(_unavailable(write.error), state, stage_key, detail)
	else:
		detail = "%d ms is not faster than the stored %d ms" % [time_ms, int(mine.time_ms)]

	var board := await fetch(stage_key)
	board["posted"] = state == POST_POSTED
	board["post_state"] = state
	board["post_error"] = detail if state == POST_DENIED else ""
	return _log(board, state, stage_key, detail)


# Read the board without writing anything. Used for a signed-out player, for a
# signed-in player who has not chosen a username, and as the second half of
# submit_and_fetch.
#
# Returns, on success:
#   ok            bool   — false means "unavailable"; ignore every other field
#   error         String — "" on success
#   rows          Array  — up to PODIUM_ROWS entries, fastest first, each already
#                          in the UITheme.standings_row shape:
#                          {placed, name, car_name, combined_ms, dnf, is_player}
#                          plus {uid, car_id}
#   total         int    — how many times are posted on this board
#   signed_in     bool
#   player_rank   int    — 1-based; 0 when the player has no entry
#   player_row    Dict   — the player's own row in the same shape, or {}
#   posted        bool   — always false here; set by submit_and_fetch
#   post_state    String — one of the POST_* constants; "" for a bare fetch
#   post_error    String — a developer-facing explanation when post_state is
#                          POST_DENIED, otherwise "". The page is NOT required to
#                          show it; it exists so a refused write is not silent.
func fetch(stage_key: String) -> Dictionary:
	if stage_key == "":
		return _unavailable("No stage key.")

	var token := ""
	if _signed_in():
		var fresh := await auth.ensure_fresh_token()
		# A refresh failure is not fatal: the board is world-readable, so fall
		# back to an anonymous read rather than showing "unavailable".
		if fresh.ok:
			token = auth.id_token

	var top := await _run_query(stage_key, token)
	if not top.ok:
		return _unavailable(top.error)

	var mine := {"ok": true, "error": "", "time_ms": 0, "row": {}}
	if token != "":
		mine = await _read_own(stage_key, token)
		if not mine.ok:
			return _unavailable(mine.error)

	var rank := 0
	if int(mine.get("time_ms", 0)) > 0:
		var faster := await _count(stage_key, token, int(mine.time_ms))
		if not faster.ok:
			return _unavailable(faster.error)
		rank = faster.count + 1

	# The total is shown in EVERY successful state, signed out included: it is the
	# one number that says whether an empty-looking board is empty or just above
	# you.
	var posted_count := await _count(stage_key, token, 0)
	if not posted_count.ok:
		return _unavailable(posted_count.error)

	var rows: Array = top.rows
	var player_row: Dictionary = mine.get("row", {})
	if not player_row.is_empty():
		player_row["placed"] = rank
		player_row["is_player"] = true
	for i in rows.size():
		var row: Dictionary = rows[i]
		row["placed"] = i + 1
		row["is_player"] = row.get("uid", "") == _uid()

	return {
		"ok": true,
		"error": "",
		"rows": rows,
		"total": posted_count.count,
		"signed_in": _signed_in(),
		"player_rank": rank,
		"player_row": player_row,
		"posted": false,
		"post_state": "",
		"post_error": "",
	}


# The display list for the page: the fetched top rows, a {"gap": true} marker
# when the player sits below them with a break in between, then the player's own
# row. Pure, so the trimming is testable without a network.
#
# Deliberately NOT Standings.visible_rows: that needs the COMPLETE ranked field
# to locate the player inside it, and a top-N-plus-aggregate fetch never has one.
# Same marker convention and same row widget, different assembly.
static func display_rows(rows: Array, player_row: Dictionary) -> Array:
	var out: Array = rows.duplicate()
	if player_row.is_empty():
		return out
	var rank := int(player_row.get("placed", 0))
	# Already on the podium — it is the same row, do not print it twice.
	if rank > 0 and rank <= out.size():
		return out
	if rank > PODIUM_ROWS + 1:
		out.append({"gap": true})
	out.append(player_row)
	return out


# --- Firestore calls ----------------------------------------------------------

# The top PODIUM_ROWS entries, fastest first. Only the automatic single-field
# index on time_ms is needed, so there is no composite index to deploy.
func _run_query(stage_key: String, token: String) -> Dictionary:
	var body := {
		"structuredQuery": {
			"from": [{"collectionId": "times"}],
			"orderBy": [{
				"field": {"fieldPath": "time_ms"},
				"direction": "ASCENDING",
			}],
			"limit": PODIUM_ROWS,
		}
	}
	var response = await rest.request_json(HTTPClient.METHOD_POST,
		_stage_doc(stage_key) + ":runQuery",
		RestClient.json_headers(token), JSON.stringify(body))
	if not response.ok:
		return {"ok": false, "error": _classify(response), "rows": []}
	if typeof(response.json) != TYPE_ARRAY:
		return {"ok": false, "error": "unreadable", "rows": []}

	var rows: Array = []
	for element in response.json as Array:
		if typeof(element) != TYPE_DICTIONARY:
			continue
		var doc: Variant = (element as Dictionary).get("document", null)
		if typeof(doc) != TYPE_DICTIONARY:
			# runQuery answers an empty collection with a single element carrying
			# only a readTime. That is a legitimately empty board, not a failure.
			continue
		rows.append(_row_from_document(doc as Dictionary))
	return {"ok": true, "error": "", "rows": rows}


# A COUNT aggregation. `slower_than` > 0 counts entries strictly faster than it
# (rank = that + 1); 0 counts the whole board.
func _count(stage_key: String, token: String, slower_than: int) -> Dictionary:
	var query := {"from": [{"collectionId": "times"}]}
	if slower_than > 0:
		query["where"] = {
			"fieldFilter": {
				"field": {"fieldPath": "time_ms"},
				"op": "LESS_THAN",
				"value": FirestoreCodec.int_value(slower_than),
			}
		}
	var body := {
		"structuredAggregationQuery": {
			"structuredQuery": query,
			"aggregations": [{"alias": "count", "count": {}}],
		}
	}
	var response = await rest.request_json(HTTPClient.METHOD_POST,
		_stage_doc(stage_key) + ":runAggregationQuery",
		RestClient.json_headers(token), JSON.stringify(body))
	if not response.ok:
		return {"ok": false, "error": _classify(response), "count": 0}
	if typeof(response.json) != TYPE_ARRAY or (response.json as Array).is_empty():
		return {"ok": false, "error": "unreadable", "count": 0}

	var first: Variant = (response.json as Array)[0]
	if typeof(first) != TYPE_DICTIONARY:
		return {"ok": false, "error": "unreadable", "count": 0}
	var result: Variant = (first as Dictionary).get("result", {})
	if typeof(result) != TYPE_DICTIONARY:
		return {"ok": false, "error": "unreadable", "count": 0}
	var aggregate: Variant = (result as Dictionary).get("aggregateFields", {})
	if typeof(aggregate) != TYPE_DICTIONARY:
		return {"ok": false, "error": "unreadable", "count": 0}
	# COUNT comes back as an integerValue, i.e. a JSON string.
	return {"ok": true, "error": "",
		"count": FirestoreCodec.int_field(aggregate as Dictionary, "count")}


# The player's own entry. A 404 is the expected "never posted here" answer.
func _read_own(stage_key: String, token := "") -> Dictionary:
	var use_token := token if token != "" else auth.id_token
	var response = await rest.request_json(HTTPClient.METHOD_GET,
		_entry_doc(stage_key, _uid()), RestClient.json_headers(use_token))
	if response.status == 404:
		return {"ok": true, "error": "", "time_ms": 0, "row": {}}
	if not response.ok:
		return {"ok": false, "error": _classify(response), "time_ms": 0, "row": {}}
	if typeof(response.json) != TYPE_DICTIONARY:
		return {"ok": false, "error": "unreadable", "time_ms": 0, "row": {}}
	var row := _row_from_document(response.json as Dictionary)
	return {"ok": true, "error": "", "time_ms": int(row.get("combined_ms", 0)), "row": row}


# PATCH with an explicit updateMask — without it Firestore treats the write as a
# full replace. The five field paths are exactly the five the rules allow.
func _write_entry(stage_key: String, time_ms: int, identity: Dictionary) -> Dictionary:
	var values := {
		"name": String(identity.get("name", "")).strip_edges(),
		"car_name": String(identity.get("car_name", "")),
		"car_id": String(identity.get("car_id", "")),
		"time_ms": time_ms,
		"updated_utc": Time.get_datetime_string_from_system(true),
	}
	var url := _entry_doc(stage_key, _uid()) + FirestoreCodec.update_mask(values.keys())
	var response = await rest.request_json(HTTPClient.METHOD_PATCH, url,
		RestClient.json_headers(auth.id_token),
		JSON.stringify(FirestoreCodec.document(values)))
	if response.ok:
		return {"ok": true, "error": "", "state": POST_POSTED}

	# A 401/403 is NOT silently benign. Treating it as such is what let a
	# never-deployed firestore.rules look exactly like a successful post.
	#
	# Two causes are indistinguishable from the response alone: the rules'
	# improvement-only backstop firing on a race with another device (harmless —
	# the board already holds something better), or the rules genuinely refusing
	# this uid, which in practice almost always means firestore.rules has never
	# been deployed and the database is denying everything.
	#
	# So: keep the BOARD available — a refused write must never cost the player
	# their rally, and the world-readable read half works regardless — but report
	# it as POST_DENIED on the result and log it loudly with the stage key.
	# Silence here was the bug.
	var status_code := int(response.get("status", 0))
	if status_code == 401 or status_code == 403:
		return {"ok": true, "state": POST_DENIED, "error":
			("Firestore refused the leaderboard write (%d). Either another device "
			+ "already posted a faster time, or firestore.rules is not deployed / "
			+ "does not permit stage_times for this uid.") % status_code}
	return {"ok": false, "error": _classify(response), "state": POST_FAILED}


# --- Internals ----------------------------------------------------------------

# Map a Firestore document straight into the shape UITheme.standings_row reads,
# so a global row renders identically to a local one. `combined_ms` rather than
# `time_ms` is that renderer's key; there is one stage in it, not a sum.
static func _row_from_document(doc: Dictionary) -> Dictionary:
	var f := FirestoreCodec.fields_of(doc)
	return {
		"placed": 0,
		"name": FirestoreCodec.string_field(f, "name"),
		"car_name": FirestoreCodec.string_field(f, "car_name"),
		"car_id": FirestoreCodec.string_field(f, "car_id"),
		"combined_ms": FirestoreCodec.int_field(f, "time_ms"),
		"dnf": false,
		"is_player": false,
		"uid": _uid_from_path(String(doc.get("name", ""))),
	}


# A document's REST "name" is its full resource path; the uid is the last segment.
static func _uid_from_path(path: String) -> String:
	if path == "":
		return ""
	var parts := path.split("/")
	return parts[parts.size() - 1]


# Every failure class lands in the same place. The distinction between offline,
# 5xx, 429 and a parse failure matters to CloudSync (which retries); here it does
# not, because there is nothing to retry — the player is about to leave the page.
func _classify(response: Dictionary) -> String:
	if response.get("network", false):
		return "offline"
	return "http_%d" % int(response.get("status", 0))


func _unavailable(reason: String) -> Dictionary:
	return {
		"ok": false,
		"error": reason,
		"rows": [],
		"total": 0,
		"signed_in": _signed_in(),
		"player_rank": 0,
		"player_row": {},
		"posted": false,
		"post_state": POST_FAILED,
		"post_error": "",
	}


# ONE line per submit_and_fetch, naming the outcome and the stage key. This is
# the permanent diagnostic for "I drove a stage and nothing appeared": the log
# says which of the eight no-write reasons applied, and the key says which board
# to go and look at. Deliberately not a UI: the player must never be interrupted
# by a leaderboard, so the developer gets the console and the player gets the
# page rendering exactly as before.
func _log(result: Dictionary, state: String, stage_key: String, detail: String) -> Dictionary:
	result["post_state"] = state
	if not result.has("post_error"):
		result["post_error"] = ""
	if state == POST_DENIED:
		result["post_error"] = detail
	var line := "Leaderboard: %s  stage=%s  uid=%s" % [
		state, stage_key if stage_key != "" else "(none)",
		_uid() if _uid() != "" else "(signed out)"]
	if detail != "":
		line += "  — " + detail
	# A denied or failed write is a real problem someone has to see; everything
	# else is ordinary bookkeeping and stays at print level.
	if state == POST_DENIED or state == POST_FAILED:
		push_warning(line)
	else:
		print(line)
	return result


func _signed_in() -> bool:
	return auth != null and rest != null and auth.is_signed_in()


func _uid() -> String:
	return auth.uid if auth != null else ""


static func _documents_root() -> String:
	return "%s/projects/%s/databases/(default)/documents" % [
		FirebaseConfig.FIRESTORE_URL, FirebaseConfig.PROJECT_ID]


# The per-stage parent document. It need not exist for its `times` subcollection
# to be queryable — Firestore parents are implicit.
static func _stage_doc(stage_key: String) -> String:
	return "%s/stage_times/%s" % [_documents_root(), stage_key.uri_encode()]


static func _entry_doc(stage_key: String, uid: String) -> String:
	return "%s/times/%s" % [_stage_doc(stage_key), uid.uri_encode()]
