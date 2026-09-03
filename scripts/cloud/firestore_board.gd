class_name FirestoreBoard
extends Node
# Docs: features/rally-challenge.md — update in the same change as this file.
# Tests: tests/headless/test_challenge_leaderboard.gd — extend in the same change.
# Shared Firestore plumbing for a world leaderboard: ChallengeLeaderboard —
# challenge_runs/{period_key}/entries/{uid} — is the only board built on this
# base today. It was extracted while a second board (Leaderboard, the global
# per-stage board at stage_times/{stage_key}/times/{uid}) shared near-identical
# copies of: building the documents root/entry path, deciding signed-in-ness,
# classifying a failed response, pulling a uid out of a Firestore document
# path, running a top-N `runQuery`, and unwrapping a `runAggregationQuery`
# COUNT response. `Leaderboard` was deleted in the roguelike pivot (decision
# 30, todo/roguelike-pivot.md) along with the global per-stage boards it
# served; this base class stayed rather than being folded back into
# ChallengeLeaderboard, since it is still the right shape for any future board.
#
# What is deliberately NOT here, because it genuinely differs between boards:
# `_read_own` (return shape), `_row_from_document` (row shape), `_unavailable`
# (payload shape), all POST_* semantics, and every write path. A wrong
# unification of any of those would silently corrupt another player's data,
# so each board keeps its own.
#
# Injected by Cloud (scripts/cloud/cloud_manager.gd), same as before this
# extraction — `rest`/`auth` are assigned directly after `.new()`, not via
# `_init`, because CloudManager wires up a graph of nodes it also add_child's.

var rest = null
var auth: AuthService = null


# --- Shared identity / classification -----------------------------------------

func _signed_in() -> bool:
	return auth != null and rest != null and auth.is_signed_in()


func _uid() -> String:
	return auth.uid if auth != null else ""


# Every failure class lands in the same place. The distinction between
# offline, 5xx, 429 and a parse failure matters to CloudSync (which retries);
# neither board retries, so it does not matter here.
func _classify(response: Dictionary) -> String:
	if response.get("network", false):
		return "offline"
	return "http_%d" % int(response.get("status", 0))


# A document's REST "name" is its full resource path; the uid is the last
# segment.
static func _uid_from_path(path: String) -> String:
	if path == "":
		return ""
	var parts := path.split("/")
	return parts[parts.size() - 1]


static func _documents_root() -> String:
	return "%s/projects/%s/databases/(default)/documents" % [
		FirebaseConfig.FIRESTORE_URL, FirebaseConfig.PROJECT_ID]


# The per-{stage,period} parent document does not need to exist for its
# subcollection to be queryable — Firestore parents are implicit. `parent_doc`
# is the board's own `_stage_doc(...)` / `_period_doc(...)` result.
static func _board_entry_doc(parent_doc: String, collection_id: String, uid: String) -> String:
	return "%s/%s/%s" % [parent_doc, collection_id, uid.uri_encode()]


# --- Shared Firestore calls ----------------------------------------------------

# The top `limit` entries (offset `offset`) ordered by `order_field`, in
# `collection_id` under `parent_doc`. `direction` defaults to ascending; either
# direction needs only the automatic single-field index on the ordered field, so
# there is no composite index to deploy either way. `row_builder` is the board's
# own `_row_from_document` (row shape differs per board, so it stays there, not
# here).
func _board_run_query(parent_doc: String, collection_id: String, order_field: String,
		token: String, limit: int, offset: int, row_builder: Callable,
		direction := "ASCENDING") -> Dictionary:
	var query := {
		"from": [{"collectionId": collection_id}],
		"orderBy": [{
			"field": {"fieldPath": order_field},
			"direction": direction,
		}],
		"limit": limit,
	}
	if offset > 0:
		query["offset"] = offset
	var body := {"structuredQuery": query}
	var response = await rest.request_json(HTTPClient.METHOD_POST,
		parent_doc + ":runQuery",
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
			# runQuery answers an empty collection with a single element
			# carrying only a readTime. That is a legitimately empty board,
			# not a failure.
			continue
		rows.append(row_builder.call(doc as Dictionary))
	return {"ok": true, "error": "", "rows": rows}


# A COUNT aggregation over `structured_query`, in `collection_id`'s parent
# `parent_doc`. Each board builds its own `structured_query` (the filter, if
# any, is board-specific) and hands it here for the request/response
# plumbing, which is identical.
func _board_count(parent_doc: String, structured_query: Dictionary, token: String) -> Dictionary:
	var body := {
		"structuredAggregationQuery": {
			"structuredQuery": structured_query,
			"aggregations": [{"alias": "count", "count": {}}],
		}
	}
	var response = await rest.request_json(HTTPClient.METHOD_POST,
		parent_doc + ":runAggregationQuery",
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
