class_name LobbyBoard
extends FirestoreBoard
# Docs: features/multiplayer-lobby.md
# Tests: tests/headless/test_lobby_board.gd
#
# The lobby's one Firestore collection: lobby_rounds/{round_key}/racers/{uid}.
# One document per player per round, seven fields, all int or string — chosen so
# FirestoreCodec (string/int/bool only) needs no new encoder.
#
# Mirrors Leaderboard: same POST_* enumeration of every no-write outcome, so
# "why am I not on the board" is always answerable rather than a silent nothing.

const COLLECTION_ID := "racers"

# How many racers to pull. The leader plus enough context for a standings readout;
# a tunable, not a contract.
const FIELD_LIMIT := 10

const POST_OK := "ok"
const POST_SIGNED_OUT := "signed_out"
const POST_INVALID_SAMPLE := "invalid_sample"
const POST_NETWORK := "network"
const POST_REJECTED := "rejected"


func _round_doc(round_key: String) -> String:
	return "%s/lobby_rounds/%s" % [_documents_root(), round_key]


func _entry_doc(round_key: String, uid: String) -> String:
	return _board_entry_doc(_round_doc(round_key), COLLECTION_ID, uid)


# Write this client's current position. At most one of these every few seconds.
func post(round_key: String, sample: Dictionary, identity: Dictionary) -> Dictionary:
	if not _signed_in():
		# Not an error: spectating without an account is a supported state. It must
		# cost zero requests rather than one failed one.
		return {"ok": false, "state": POST_SIGNED_OUT}

	var doc: Dictionary = _document_from(sample, identity)
	if doc.is_empty():
		return {"ok": false, "state": POST_INVALID_SAMPLE}

	var fresh: Dictionary = await auth.ensure_fresh_token()
	if not fresh["ok"]:
		return {"ok": false, "state": POST_SIGNED_OUT}

	var mask: String = FirestoreCodec.update_mask(["name", "car_id", "progress_m",
		"speed_mms", "at_ms", "state", "finish_ms"])
	var url: String = _entry_doc(round_key, _uid()) + mask
	var res: Dictionary = await rest.request_json(HTTPClient.METHOD_PATCH, url,
		RestClient.json_headers(auth.id_token), JSON.stringify(doc))
	if res["ok"]:
		return {"ok": true, "state": POST_OK}
	return {"ok": false, "state": POST_NETWORK if res["network"] else POST_REJECTED}


# The field, leader first.
#
# DESCENDING is load-bearing: ascending returns the SLOWEST racers, so on a busy
# lobby the leader — the one racer this mode renders — would be missing entirely.
func fetch(round_key: String) -> Dictionary:
	var token: String = auth.id_token if _signed_in() else ""
	var res: Dictionary = await _board_run_query(_round_doc(round_key), COLLECTION_ID,
		"progress_m", token, FIELD_LIMIT, 0, _row_from_document, "DESCENDING")
	if not res["ok"]:
		return {"ok": false, "error": res["error"], "rows": []}
	return {"ok": true, "error": "", "rows": res["rows"]}


# Clamp at the WRITE, so the security rules' non-negative guard stays the backstop it
# is meant to be. A car reversing after a crash has negative track speed; unclamped,
# the rules reject the write and that racer freezes on every other player's screen
# with no diagnosable cause.
func _document_from(sample: Dictionary, identity: Dictionary) -> Dictionary:
	var racer_name: String = String(identity.get("name", "")).substr(0, 16)
	if racer_name.is_empty():
		return {}
	var state: String = String(sample.get("state", LobbyStandings.STATE_RACING))
	if not [LobbyStandings.STATE_RACING, LobbyStandings.STATE_FINISHED,
			LobbyStandings.STATE_DNF].has(state):
		return {}
	# document() takes PLAIN values and wraps them itself — pre-wrapping here would
	# double-tag and blow up inside the codec. Insertion order is preserved and must
	# match the update_mask field order above.
	return FirestoreCodec.document({
		"name": racer_name,
		"car_id": String(identity.get("car_id", "")).substr(0, 40),
		"progress_m": maxi(0, int(sample.get("progress_m", 0))),
		"speed_mms": maxi(0, int(sample.get("speed_mms", 0))),
		"at_ms": maxi(1, int(sample.get("at_ms", 0))),
		"state": state,
		"finish_ms": maxi(0, int(sample.get("finish_ms", 0))),
	})


func _row_from_document(doc: Dictionary) -> Dictionary:
	var fields: Dictionary = FirestoreCodec.fields_of(doc)
	return {
		"uid": _uid_from_path(String(doc.get("name", ""))),
		"name": FirestoreCodec.string_field(fields, "name"),
		"car_id": FirestoreCodec.string_field(fields, "car_id"),
		"progress_m": FirestoreCodec.int_field(fields, "progress_m"),
		"speed_mms": FirestoreCodec.int_field(fields, "speed_mms"),
		"at_ms": FirestoreCodec.int_field(fields, "at_ms"),
		"state": FirestoreCodec.string_field(fields, "state"),
		"finish_ms": FirestoreCodec.int_field(fields, "finish_ms"),
	}


# --- the shared round-state document --------------------------------------------
# lobby_state/current: the ONE piece of shared mutable state — which round is
# running. Exists so a round can end early and a dead lobby can restart on entry.
# The write race between advancing clients is resolved by the security rules
# (round_index must strictly increase), not here.

const STATE_DOC := "lobby_state/current"


func _state_doc_url() -> String:
	return "%s/%s" % [_documents_root(), STATE_DOC]


# The current round per the shared document. `absent` distinguishes "the lobby has
# never been played" (bootstrap me) from a broken read (fall back to RoundClock).
func read_state() -> Dictionary:
	var token: String = auth.id_token if _signed_in() else ""
	var res: Dictionary = await rest.request_json(HTTPClient.METHOD_GET,
		_state_doc_url(), RestClient.json_headers(token))
	if not res["ok"]:
		return {"ok": false, "absent": int(res["status"]) == 404,
			"round_index": -1, "started_at_ms": 0}
	var fields: Dictionary = FirestoreCodec.fields_of(res["json"])
	return {"ok": true, "absent": false,
		"round_index": FirestoreCodec.int_field(fields, "round_index"),
		"started_at_ms": FirestoreCodec.int_field(fields, "started_at_ms")}


# Claim the next round. The rules only accept a strictly increasing round_index, so
# losing the race to another client comes back as POST_REJECTED — the caller adopts
# the winner's value on its next read rather than retrying.
#
# A signed-out player cannot advance (writes need auth). A lobby containing only
# signed-out spectators therefore sits on a finished round until someone who can
# write walks in — an accepted consequence of having no anonymous accounts.
func advance_state(round_index: int, started_at_ms: int) -> Dictionary:
	if not _signed_in():
		return {"ok": false, "state": POST_SIGNED_OUT}
	var fresh: Dictionary = await auth.ensure_fresh_token()
	if not fresh["ok"]:
		return {"ok": false, "state": POST_SIGNED_OUT}
	var doc: Dictionary = FirestoreCodec.document({
		"round_index": round_index,
		"started_at_ms": started_at_ms,
	})
	var url: String = _state_doc_url() + FirestoreCodec.update_mask(
		["round_index", "started_at_ms"])
	var res: Dictionary = await rest.request_json(HTTPClient.METHOD_PATCH, url,
		RestClient.json_headers(auth.id_token), JSON.stringify(doc))
	if res["ok"]:
		return {"ok": true, "state": POST_OK}
	return {"ok": false, "state": POST_NETWORK if res["network"] else POST_REJECTED}
