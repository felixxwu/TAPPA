class_name FakeRestClient
extends Node
# Stand-in for RestClient in the cloud tests.
#
# RestClient is the ONE place that touches HTTPRequest, precisely so that
# everything above it — the auth state machine, the conflict logic, the Firestore
# encoding — can be exercised headlessly with no network. Assign it in place of
# the real client, queue the responses you want, and assert on what was sent.
#
# It is a real coroutine (it awaits a frame) so the code under test takes the
# same await path it takes against a live network, rather than a fast path that
# only exists in tests.

# Responses returned in order; the last one repeats once the queue is empty.
var queued: Array[Dictionary] = []
# Every call, recorded as {method, url, headers, body}.
var requests: Array[Dictionary] = []

var _fallback: Dictionary = {"ok": true, "status": 200, "json": {}, "error": "", "network": false}


func request_json(method: int, url: String, headers: PackedStringArray,
		body: String = "") -> Dictionary:
	requests.append({"method": method, "url": url, "headers": headers, "body": body})
	await (Engine.get_main_loop() as SceneTree).process_frame
	if queued.is_empty():
		return _fallback.duplicate(true)
	return queued.pop_front()


# --- Response builders --------------------------------------------------------

func queue_ok(json: Variant = {}, status := 200) -> FakeRestClient:
	queued.append({"ok": true, "status": status, "json": json, "error": "", "network": false})
	return self


func queue_error(status: int, code := "") -> FakeRestClient:
	var body: Dictionary = {}
	if code != "":
		body = {"error": {"message": code}}
	queued.append({"ok": false, "status": status, "json": body,
		"error": "http_%d" % status, "network": false})
	return self


func queue_offline() -> FakeRestClient:
	queued.append({"ok": false, "status": 0, "json": {}, "error": "transport_1", "network": true})
	return self


# --- Assertions helpers -------------------------------------------------------

func last() -> Dictionary:
	return requests[-1] if not requests.is_empty() else {}


func last_body() -> Dictionary:
	var raw := String(last().get("body", ""))
	var json := JSON.new()
	if json.parse(raw) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {}
	return json.data
