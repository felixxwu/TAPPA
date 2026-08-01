class_name ChallengeLeaderboard
extends Node
# The Daily/Weekly/Monthly Rally Challenge world leaderboard: one Firestore
# document per player per period, at
#   challenge_runs/{period_key}/entries/{uid}
#
# Mirrors Leaderboard (scripts/cloud/leaderboard.gd) one level deeper: instead
# of a single time_ms, each document accumulates write-once cum_ms_1..cum_ms_N
# checkpoints (one per stage), plus a one-way dnf flip. See
# docs/superpowers/specs/2026-07-31-rally-challenge-design.md §5 and
# firestore.rules' challenge_runs match block for the exact write contract this
# client must respect (isValidCreate / isStageAdvance / isDnfFlip).
#
# Same posture as Leaderboard: NOTHING HERE MAY COST A PLAYER THEIR RUN. Every
# failure collapses into `{"ok": false}` / a no-op; there is no retry loop.
# Owned by Cloud alongside `leaderboard`/`sync`.

const PODIUM_ROWS := 3

const POST_POSTED := "posted"
const POST_SIGNED_OUT := "signed_out"
const POST_NO_USERNAME := "no_username"
const POST_ALREADY_POSTED := "already_posted"   # this checkpoint (or later) already landed
const POST_OUT_OF_ORDER := "out_of_order"        # a prior checkpoint never landed — see spec §5
const POST_DENIED := "denied"
const POST_FAILED := "failed"

# Injected by Cloud, same as Leaderboard.
var rest = null
var auth: AuthService = null


# --- Posting -------------------------------------------------------------------

# Post checkpoint `k` (1-based stage number) with this run's cumulative time so
# far. Creates the document at k==1; advances it at k>1. `identity` is
# {"name", "car_name", "car_id"}. Per spec §5, a failed/skipped checkpoint
# permanently strands the run's board entry at its last successful post — this
# function does NOT retry or attempt to catch up out of order; the caller
# (ChallengeSession) is expected to simply stop calling it again for the rest
# of the run once a post fails.
func post_checkpoint(period_key: String, k: int, cum_ms: int, identity: Dictionary) -> Dictionary:
	if not _signed_in():
		return {"ok": false, "state": POST_SIGNED_OUT}
	var display_name := String(identity.get("name", "")).strip_edges()
	if display_name == "":
		return {"ok": false, "state": POST_NO_USERNAME}
	var fresh := await auth.ensure_fresh_token()
	if not fresh.ok:
		return {"ok": false, "state": POST_FAILED, "error": String(fresh.get("error", ""))}

	var mine := await _read_own(period_key)
	if not mine.ok:
		return {"ok": false, "state": POST_FAILED, "error": mine.error}

	if k == 1:
		if mine.exists:
			return {"ok": false, "state": POST_ALREADY_POSTED}
		return await _create_entry(period_key, cum_ms, identity)

	if not mine.exists:
		return {"ok": false, "state": POST_OUT_OF_ORDER}
	if bool(mine.dnf):
		return {"ok": false, "state": POST_ALREADY_POSTED}  # a DNF'd run is over
	if int(mine.stages_completed) != k - 1:
		return {"ok": false, "state": POST_OUT_OF_ORDER}
	return await _advance_entry(period_key, k, cum_ms)


# Flip dnf true. A silent no-op if no document exists yet (per spec: a DNF
# before the first successful checkpoint leaves no trace on the board at all —
# isDnfFlip is an update rule, it requires a document to already exist) or if
# the run already ended (dnf already true).
func post_dnf(period_key: String) -> Dictionary:
	if not _signed_in():
		return {"ok": false, "state": POST_SIGNED_OUT}
	var fresh := await auth.ensure_fresh_token()
	if not fresh.ok:
		return {"ok": false, "state": POST_FAILED, "error": String(fresh.get("error", ""))}
	var mine := await _read_own(period_key)
	if not mine.ok:
		return {"ok": false, "state": POST_FAILED, "error": mine.error}
	if not mine.exists or bool(mine.dnf):
		return {"ok": true, "state": POST_ALREADY_POSTED}  # nothing to flip; not an error
	var url := _entry_doc(period_key, _uid()) + FirestoreCodec.update_mask(["dnf"])
	var response = await rest.request_json(HTTPClient.METHOD_PATCH, url,
		RestClient.json_headers(auth.id_token),
		JSON.stringify(FirestoreCodec.document({"dnf": true})))
	if response.ok:
		return {"ok": true, "state": POST_POSTED}
	return _write_failure(response)


# --- Fetching --------------------------------------------------------------

# "Where do I stand after finishing stage k": top PODIUM_ROWS by cum_ms_k
# ascending (Firestore's orderBy naturally excludes any document missing that
# field — exactly "hasn't reached stage k yet" — no extra filter needed), the
# player's own rank (skipped if they haven't posted checkpoint k), total
# entries in the period (every doc that has ever posted cum_ms_1, regardless of
# stage/dnf), and how many of those haven't reached stage k yet (a single count
# line, not per-row placeholders).
func fetch_standings_at(period_key: String, k: int) -> Dictionary:
	var token := ""
	if _signed_in():
		var fresh := await auth.ensure_fresh_token()
		if fresh.ok:
			token = auth.id_token

	var checkpoint_field := "cum_ms_%d" % k
	var top := await _run_query(period_key, checkpoint_field, token)
	if not top.ok:
		return _unavailable(top.error)

	var mine := {"ok": true, "exists": false, "fields": {}, "row": {}}
	if token != "":
		mine = await _read_own(period_key, token)
		if not mine.ok:
			return _unavailable(mine.error)

	var rank := 0
	var my_cum_ms := 0
	if bool(mine.get("exists", false)):
		my_cum_ms = FirestoreCodec.int_field(mine.get("fields", {}), checkpoint_field)
	if my_cum_ms > 0:
		var faster := await _count_field_less_than(period_key, checkpoint_field, token, my_cum_ms)
		if not faster.ok:
			return _unavailable(faster.error)
		rank = faster.count + 1

	var total := await _count_all(period_key, token)
	if not total.ok:
		return _unavailable(total.error)
	var reached := await _count_field_greater_than(period_key, checkpoint_field, token, 0)
	if not reached.ok:
		return _unavailable(reached.error)

	# Each top row carries this checkpoint's OWN cum_ms (via `checkpoint_field`,
	# not the generic _row_from_document shape), mirroring UITheme.standings_row's
	# combined_ms so the challenge standings page can show real times, not bare ranks.
	var rows: Array = top.rows
	var uid := _uid()
	for i in rows.size():
		var row: Dictionary = rows[i]
		row["placed"] = i + 1
		row["combined_ms"] = FirestoreCodec.int_field(row.get("raw_fields", {}), checkpoint_field)
		row["is_player"] = String(row.get("uid", "")) == uid
		row.erase("raw_fields")

	# The player's own row (own rank + own time), same shape as the top rows —
	# mirrors Leaderboard.fetch's player_row, so the standings page doesn't have to
	# special-case "am I already in the top rows or do I need my own line".
	var player_row: Dictionary = {}
	if my_cum_ms > 0:
		player_row = mine.get("row", {}).duplicate()
		player_row.erase("raw_fields")
		player_row["placed"] = rank
		player_row["combined_ms"] = my_cum_ms
		player_row["is_player"] = true

	return {
		"ok": true,
		"rows": rows,
		"player_row": player_row,
		"total_entries": total.count,
		"not_yet_complete": maxi(0, total.count - reached.count),
		"player_rank": rank,
		"signed_in": _signed_in(),
	}


# Rank + total_entries at the FINAL checkpoint, for the completion-reward
# placement gate (spec §6: `rank <= ceil(total_entries / 2)`). Thin wrapper
# over fetch_standings_at so ChallengeSession doesn't duplicate the query.
func fetch_final_rank(period_key: String, stage_count: int) -> Dictionary:
	var result := await fetch_standings_at(period_key, stage_count)
	if not result.ok or int(result.get("player_rank", 0)) <= 0:
		return {"ok": false}
	return {"ok": true, "rank": int(result["player_rank"]), "total_entries": int(result["total_entries"])}


# The time that currently has to be BEATEN to satisfy the completion gate — i.e. the
# finishing time sitting on the top-50% cut line right now, so the challenge entry
# screen can show "Top 50% - 1:52.24" instead of an abstract percentage.
#
# The gate is `rank <= ceil(total_entries / 2)` at the final checkpoint (see
# fetch_final_rank / spec §6), evaluated once the player is IN the field — so the
# denominator to predict against is the field they'll be part of, i.e. the current
# entry count PLUS ONE when they haven't posted yet (`_read_own` decides; if they
# already have an entry they're counted already). Beating the current rank-r time is
# what puts you at rank r, so the time to beat is the entry at `ceil(field / 2)`,
# read at offset `ceil(field / 2) - 1`.
#
# Worked through: 1 rival -> field 2 -> need rank <= 1 -> beat the current P1.
# 2 rivals -> field 3 -> need rank <= 2 -> beat the current P2. 3 rivals -> field 4
# -> need rank <= 2 -> beat the current P2. Counting only the existing entries
# (field = 1 and 2 in the first two cases) put the line a whole place too high and
# quoted P1's time when P2's was what mattered.
#
# While fewer players have FINISHED than that rank the query is empty — reported as
# `{"ok": true, "exists": false}`, meaning any finish currently makes the cut.
#
# Same posture as the rest of this class: a failure is `{"ok": false}`, never a
# raised error and never a retry. Purely informational — nothing gates on it.
func fetch_cutoff(period_key: String, stage_count: int) -> Dictionary:
	if period_key == "" or stage_count <= 0:
		return {"ok": false}
	var token := ""
	if _signed_in():
		var fresh := await auth.ensure_fresh_token()
		if fresh.ok:
			token = auth.id_token

	var total := await _count_all(period_key, token)
	if not total.ok:
		return {"ok": false}

	# Is the player already counted in `total`, or would posting add them to it?
	var already_entered := false
	if token != "":
		var mine := await _read_own(period_key, token)
		if not mine.ok:
			return {"ok": false}
		already_entered = bool(mine.get("exists", false))
	var field_size: int = total.count if already_entered else total.count + 1

	var cut_rank := int(ceil(field_size / 2.0))
	var field := "cum_ms_%d" % stage_count
	var at_line := await _run_query(period_key, field, token, 1, cut_rank - 1)
	if not at_line.ok:
		return {"ok": false}
	var rows: Array = at_line.rows
	if rows.is_empty():
		# Fewer finishers than the cut rank — nobody is on the line yet.
		return {"ok": true, "exists": false, "cutoff_ms": 0, "total_entries": total.count}
	var row: Dictionary = rows[0]
	var cutoff_ms := FirestoreCodec.int_field(row.get("raw_fields", {}), field)
	if cutoff_ms <= 0:
		return {"ok": true, "exists": false, "cutoff_ms": 0, "total_entries": total.count}
	return {"ok": true, "exists": true, "cutoff_ms": cutoff_ms, "total_entries": total.count}


# --- Firestore calls -----------------------------------------------------------

func _create_entry(period_key: String, cum_ms_1: int, identity: Dictionary) -> Dictionary:
	var values := {
		"name": String(identity.get("name", "")).strip_edges(),
		"car_name": String(identity.get("car_name", "")),
		"car_id": String(identity.get("car_id", "")),
		"stages_completed": 1,
		"dnf": false,
		"cum_ms_1": cum_ms_1,
	}
	var response = await rest.request_json(HTTPClient.METHOD_PATCH,
		_entry_doc(period_key, _uid()),
		RestClient.json_headers(auth.id_token), JSON.stringify(FirestoreCodec.document(values)))
	if response.ok:
		return {"ok": true, "state": POST_POSTED}
	return _write_failure(response)


func _advance_entry(period_key: String, k: int, cum_ms: int) -> Dictionary:
	var field := "cum_ms_%d" % k
	var values := {"stages_completed": k, field: cum_ms}
	var url := _entry_doc(period_key, _uid()) + FirestoreCodec.update_mask(values.keys())
	var response = await rest.request_json(HTTPClient.METHOD_PATCH, url,
		RestClient.json_headers(auth.id_token), JSON.stringify(FirestoreCodec.document(values)))
	if response.ok:
		return {"ok": true, "state": POST_POSTED}
	return _write_failure(response)


func _write_failure(response: Dictionary) -> Dictionary:
	var status_code := int(response.get("status", 0))
	if status_code == 401 or status_code == 403:
		return {"ok": false, "state": POST_DENIED}
	return {"ok": false, "state": POST_FAILED, "error": _classify(response)}


func _run_query(period_key: String, order_field: String, token: String,
		limit := PODIUM_ROWS, offset := 0) -> Dictionary:
	var query := {
		"from": [{"collectionId": "entries"}],
		"orderBy": [{"field": {"fieldPath": order_field}, "direction": "ASCENDING"}],
		"limit": limit,
	}
	if offset > 0:
		query["offset"] = offset
	var body := {"structuredQuery": query}
	var response = await rest.request_json(HTTPClient.METHOD_POST,
		_period_doc(period_key) + ":runQuery",
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
			continue  # an empty collection's single readTime-only element
		rows.append(_row_from_document(doc as Dictionary))
	return {"ok": true, "error": "", "rows": rows}


func _count_all(period_key: String, token: String) -> Dictionary:
	return await _count(period_key, {"from": [{"collectionId": "entries"}]}, token)


func _count_field_less_than(period_key: String, field: String, token: String, value: int) -> Dictionary:
	var query := {
		"from": [{"collectionId": "entries"}],
		"where": {"fieldFilter": {"field": {"fieldPath": field}, "op": "LESS_THAN",
			"value": FirestoreCodec.int_value(value)}},
	}
	return await _count(period_key, query, token)


func _count_field_greater_than(period_key: String, field: String, token: String, value: int) -> Dictionary:
	var query := {
		"from": [{"collectionId": "entries"}],
		"where": {"fieldFilter": {"field": {"fieldPath": field}, "op": "GREATER_THAN",
			"value": FirestoreCodec.int_value(value)}},
	}
	return await _count(period_key, query, token)


func _count(period_key: String, structured_query: Dictionary, token: String) -> Dictionary:
	var body := {
		"structuredAggregationQuery": {
			"structuredQuery": structured_query,
			"aggregations": [{"alias": "count", "count": {}}],
		}
	}
	var response = await rest.request_json(HTTPClient.METHOD_POST,
		_period_doc(period_key) + ":runAggregationQuery",
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
	return {"ok": true, "error": "", "count": FirestoreCodec.int_field(aggregate as Dictionary, "count")}


# The player's own entry. A 404 is the expected "never posted here" answer.
func _read_own(period_key: String, token := "") -> Dictionary:
	var use_token := token if token != "" else auth.id_token
	var response = await rest.request_json(HTTPClient.METHOD_GET,
		_entry_doc(period_key, _uid()), RestClient.json_headers(use_token))
	if response.status == 404:
		return {"ok": true, "exists": false, "stages_completed": 0, "dnf": false, "fields": {}, "row": {}}
	if not response.ok:
		return {"ok": false, "error": _classify(response)}
	if typeof(response.json) != TYPE_DICTIONARY:
		return {"ok": false, "error": "unreadable"}
	var f := FirestoreCodec.fields_of(response.json as Dictionary)
	return {
		"ok": true, "exists": true,
		"stages_completed": FirestoreCodec.int_field(f, "stages_completed"),
		"dnf": FirestoreCodec.bool_field(f, "dnf"),
		"fields": f, "row": _row_from_document(response.json as Dictionary),
	}


static func _row_from_document(doc: Dictionary) -> Dictionary:
	var f := FirestoreCodec.fields_of(doc)
	return {
		"placed": 0,
		"name": FirestoreCodec.string_field(f, "name"),
		"car_name": FirestoreCodec.string_field(f, "car_name"),
		"car_id": FirestoreCodec.string_field(f, "car_id"),
		"stages_completed": FirestoreCodec.int_field(f, "stages_completed"),
		"uid": _uid_from_path(String(doc.get("name", ""))),
		# Kept so fetch_standings_at can pull this ROW'S checkpoint value (the
		# query's orderBy field varies by k, so it can't be baked in here) —
		# stripped back out before the row is handed to a caller.
		"raw_fields": f,
	}


static func _uid_from_path(path: String) -> String:
	if path == "":
		return ""
	var parts := path.split("/")
	return parts[parts.size() - 1]


func _classify(response: Dictionary) -> String:
	if response.get("network", false):
		return "offline"
	return "http_%d" % int(response.get("status", 0))


func _unavailable(reason: String) -> Dictionary:
	return {"ok": false, "error": reason, "rows": [], "total_entries": 0,
		"not_yet_complete": 0, "player_rank": 0, "signed_in": _signed_in()}


func _signed_in() -> bool:
	return auth != null and rest != null and auth.is_signed_in()


func _uid() -> String:
	return auth.uid if auth != null else ""


static func _documents_root() -> String:
	return "%s/projects/%s/databases/(default)/documents" % [
		FirebaseConfig.FIRESTORE_URL, FirebaseConfig.PROJECT_ID]


static func _period_doc(period_key: String) -> String:
	return "%s/challenge_runs/%s" % [_documents_root(), period_key.uri_encode()]


static func _entry_doc(period_key: String, uid: String) -> String:
	return "%s/entries/%s" % [_period_doc(period_key), uid.uri_encode()]
