class_name RestClient
extends Node
# The ONLY place in the project that touches HTTPRequest.
#
# Everything in scripts/cloud/ talks to the network through this one awaitable
# method, which is what makes the auth + sync logic headless-testable: a test
# assigns Cloud.rest = FakeRestClient.new() and scripts the responses, with no
# socket in sight. Keep this class dumb — no Firebase knowledge, no retry policy,
# no state machine. Those live in the callers, where they can be tested.
#
# Godot's HTTPRequest handles ONE request at a time, so concurrent callers are
# serialised through a small await-loop rather than being dropped.

# Emitted internally whenever a request finishes and the single HTTPRequest slot
# becomes available. Queued callers wake on this and re-check.
signal _slot_free

# Generous: a phone on a bad connection is normal, and every caller already
# degrades gracefully to "not synced" rather than blocking the player.
const TIMEOUT_SEC := 20.0

var _http: HTTPRequest
var _busy := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT_SEC
	# Redirects: Google's endpoints do not use them, but following a couple is
	# harmless and avoids a mysterious failure if that ever changes.
	_http.max_redirects = 3
	add_child(_http)


# Perform an HTTP request and return a plain result Dictionary:
#   ok       : bool   — 2xx AND the transport succeeded
#   status   : int    — HTTP status (0 when the request never reached a server)
#   json     : Variant— parsed body ({} when absent/unparseable)
#   error    : String — short machine-readable tag, "" on success
#   network  : bool   — true when the failure was transport-level (offline,
#                       DNS, timeout) rather than an answer from the server.
#                       Callers use this to decide "retry" vs "sign out".
func request_json(method: int, url: String, headers: PackedStringArray,
		body: String = "") -> Dictionary:
	# Serialise: one in-flight request per client. The `while` (not `if`) matters —
	# every queued caller is woken by the same signal, so each must re-check.
	while _busy:
		await _slot_free
	_busy = true
	var result := await _perform(method, url, headers, body)
	_busy = false
	_slot_free.emit()
	return result


func _perform(method: int, url: String, headers: PackedStringArray,
		body: String) -> Dictionary:
	if _http == null:
		return _failure(0, "client_unavailable", true)
	var err := _http.request(url, headers, method, body)
	if err != OK:
		# Could not even start (bad URL, no network stack). Transport-class.
		return _failure(0, "request_failed_%d" % err, true)
	var completed: Array = await _http.request_completed
	var transport: int = completed[0]
	var status: int = completed[1]
	var raw: PackedByteArray = completed[3]

	if transport != HTTPRequest.RESULT_SUCCESS:
		return _failure(status, "transport_%d" % transport, true)

	var parsed: Variant = {}
	var text := raw.get_string_from_utf8()
	if text != "":
		# Instance API, matching save_manager.gd: malformed input returns an error
		# code instead of raising an engine-level error macro.
		var json := JSON.new()
		if json.parse(text) == OK:
			parsed = json.data
	var ok := status >= 200 and status < 300
	return {
		"ok": ok,
		"status": status,
		"json": parsed,
		"error": "" if ok else "http_%d" % status,
		"network": false,
	}


func _failure(status: int, error: String, network: bool) -> Dictionary:
	return {"ok": false, "status": status, "json": {}, "error": error, "network": network}


# --- Helpers shared by the callers -------------------------------------------

static func json_headers(id_token: String = "") -> PackedStringArray:
	var h := PackedStringArray(["Content-Type: application/json"])
	if id_token != "":
		h.append("Authorization: Bearer " + id_token)
	return h


static func form_headers() -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/x-www-form-urlencoded"])


# Encode a flat dictionary as an x-www-form-urlencoded body (the OAuth token
# endpoint and the securetoken refresh endpoint both want form encoding, not JSON).
static func form_encode(fields: Dictionary) -> String:
	var parts: PackedStringArray = []
	for key in fields:
		parts.append("%s=%s" % [String(key).uri_encode(), String(fields[key]).uri_encode()])
	return "&".join(parts)
