class_name GoogleSignIn
extends Node
# Obtains a Google ID token, which AuthService then exchanges for a Firebase
# session. Two implementations behind one `await sign_in()`:
#
#   NATIVE (Windows / macOS / Android) — loopback redirect + PKCE.
#     Bind a TCPServer on 127.0.0.1, open the system browser at Google's consent
#     screen with redirect_uri=http://127.0.0.1:<port>, and catch the single
#     inbound GET carrying the authorization code.
#
#     This covers ANDROID too, which is the reason to prefer it: the obvious
#     alternative (a custom URL scheme / deep link) needs an AndroidManifest
#     intent-filter, which needs a custom Godot Android build, which this project
#     does not have. A loopback listener needs none of that, so all three native
#     platforms share one code path and one OAuth client.
#
#   WEB — a top-level POPUP to Google's auth endpoint, redirecting to
#     docs/oauth-callback.html on GitHub Pages, which posts the ID token back.
#     Driven over JavaScriptBridge with the same create_callback +
#     member-held-handle pattern as save_manager.gd's web lifecycle hook.
#
#     Google Identity Services was tried first and does NOT work on itch: One Tap
#     renders in the calling document, which there is itch's iframe, and FedCM
#     refuses without an allow="identity-credentials-get" grant from the
#     embedding page. A popup sidesteps the iframe entirely. See the section
#     comment above _sign_in_web.
#
# PKCE (RFC 7636) is what makes each exchange safe: the authorization code is
# only redeemable by whoever knows the verifier, which never leaves the process.
# Google additionally requires the Desktop client's client_secret to be sent —
# see FirebaseConfig.GOOGLE_DESKTOP_CLIENT_SECRET for why that is not the
# contradiction it looks like.

# Give up rather than leaking a listening socket if the player wanders off.
const TIMEOUT_SEC := 180.0
const SCOPES := "openid email profile"

var _server: TCPServer = null
var _web_cb: JavaScriptObject = null
var _web_result := ""
var _web_done := false
var _cancelled := false

# Injected by Cloud (used only by the native code exchange).
var rest = null


# Returns {ok: bool, id_token: String, error: String}.
func sign_in() -> Dictionary:
	if not FirebaseConfig.google_configured():
		return _error("Google sign-in isn't set up in this build.")
	_cancelled = false
	if Platform.is_web():
		return await _sign_in_web()
	return await _sign_in_native()


# Abandon an in-flight attempt (the player pressed Cancel). Closes the listening
# socket so the port is not held for the rest of the session.
func cancel() -> void:
	_cancelled = true
	_close_server()


# --- Native: loopback + PKCE --------------------------------------------------

func _sign_in_native() -> Dictionary:
	var verifier := _random_urlsafe(64)
	var challenge := _s256(verifier)
	var state := _random_urlsafe(24)

	_close_server()
	_server = TCPServer.new()
	# Port 0 asks the OS for a free port. Bound to 127.0.0.1 explicitly — never
	# 0.0.0.0, which would expose the callback listener to the local network.
	if _server.listen(0, "127.0.0.1") != OK:
		_server = null
		return _error("Couldn't start the sign-in listener.")
	var port := _server.get_local_port()
	var redirect := "http://127.0.0.1:%d" % port

	var url := "%s?%s" % [FirebaseConfig.GOOGLE_AUTH_URL, RestClient.form_encode({
		"client_id": FirebaseConfig.GOOGLE_DESKTOP_CLIENT_ID,
		"redirect_uri": redirect,
		"response_type": "code",
		"scope": SCOPES,
		"code_challenge": challenge,
		"code_challenge_method": "S256",
		"state": state,
		"prompt": "select_account",
	})]
	OS.shell_open(url)

	var callback := await _await_callback(state)
	_close_server()
	if not callback.ok:
		return _error(callback.error)

	# Exchange the one-time code for tokens.
	#
	# client_secret is required here. PKCE (code_verifier) is what actually
	# authenticates THIS exchange, but Google exempts only Android, iOS and
	# Chrome clients from sending a secret — a Desktop client must send one, and
	# omitting it fails with `invalid_request: client_secret is missing`.
	# See the note on FirebaseConfig.GOOGLE_DESKTOP_CLIENT_SECRET.
	var response = await rest.request_json(
		HTTPClient.METHOD_POST, FirebaseConfig.GOOGLE_TOKEN_URL,
		RestClient.form_headers(),
		RestClient.form_encode({
			"client_id": FirebaseConfig.GOOGLE_DESKTOP_CLIENT_ID,
			"client_secret": FirebaseConfig.GOOGLE_DESKTOP_CLIENT_SECRET,
			"code": callback.code,
			"code_verifier": verifier,
			"grant_type": "authorization_code",
			"redirect_uri": redirect,
		}))
	if not response.ok:
		return _error(_token_error(response))
	var data: Dictionary = response.json if typeof(response.json) == TYPE_DICTIONARY else {}
	var token := String(data.get("id_token", ""))
	if token == "":
		return _error("Google didn't return a sign-in token.")
	return {"ok": true, "id_token": token, "error": ""}


# Poll the loopback listener for the browser's redirect. Returns
# {ok, code, error}.
func _await_callback(expected_state: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _cancelled:
			return {"ok": false, "code": "", "error": "Sign-in cancelled."}
		if _server == null:
			return {"ok": false, "code": "", "error": "Sign-in cancelled."}
		if _server.is_connection_available():
			var peer := _server.take_connection()
			var request_line := await _read_request_line(peer)
			var params := _query_params(request_line)
			var body := "Signed in. You can close this tab and go back to the game."
			var result := {"ok": false, "code": "", "error": "Sign-in failed."}
			if params.get("state", "") != expected_state:
				# Mismatched state means this response is not the one we started —
				# a CSRF attempt or a stale tab. Refuse it.
				body = "Sign-in could not be verified. Please try again from the game."
				result = {"ok": false, "code": "", "error": "Sign-in couldn't be verified."}
			elif params.has("error"):
				body = "Sign-in was cancelled. You can close this tab."
				result = {"ok": false, "code": "", "error": "Sign-in was cancelled."}
			elif params.has("code"):
				result = {"ok": true, "code": String(params["code"]), "error": ""}
			_respond(peer, body)
			return result
		await get_tree().process_frame
	return {"ok": false, "code": "", "error": "Sign-in timed out."}


# Read just the request line ("GET /?code=... HTTP/1.1"), which is all we need.
func _read_request_line(peer: StreamPeerTCP) -> String:
	var text := ""
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var available := peer.get_available_bytes()
		if available > 0:
			var chunk: Array = peer.get_partial_data(available)
			if chunk.size() > 1:
				text += (chunk[1] as PackedByteArray).get_string_from_utf8()
			if text.contains("\r\n") or text.contains("\n"):
				break
		await get_tree().process_frame
	return text.split("\n")[0].strip_edges()


func _respond(peer: StreamPeerTCP, message: String) -> void:
	var html := "<!doctype html><meta charset=utf-8><title>TAPPA</title>" \
		+ "<body style=\"font-family:system-ui;background:#111;color:#eee;" \
		+ "display:flex;align-items:center;justify-content:center;height:100vh\">" \
		+ "<p>" + message + "</p></body>"
	var payload := html.to_utf8_buffer()
	var head := "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" \
		+ "Content-Length: %d\r\nConnection: close\r\n\r\n" % payload.size()
	peer.put_data(head.to_utf8_buffer() + payload)
	peer.poll()
	peer.disconnect_from_host()


# Pull the query string out of a raw HTTP request line and decode it.
func _query_params(request_line: String) -> Dictionary:
	var params: Dictionary = {}
	var question := request_line.find("?")
	if question < 0:
		return params
	var tail := request_line.substr(question + 1)
	var space := tail.find(" ")
	if space >= 0:
		tail = tail.substr(0, space)
	for pair in tail.split("&", false):
		var eq: int = pair.find("=")
		if eq > 0:
			params[pair.substr(0, eq).uri_decode()] = pair.substr(eq + 1).uri_decode()
		else:
			params[pair.uri_decode()] = ""
	return params


func _close_server() -> void:
	if _server != null:
		_server.stop()
		_server = null


# --- Web: popup + GitHub Pages callback ---------------------------------------
#
# NOT Google Identity Services. GIS One Tap renders inside the calling document,
# and on itch.io that document is itch's IFRAME — where FedCM refuses to run
# because the embedding page does not grant allow="identity-credentials-get".
# That is itch's markup, not ours, so no amount of client-side work fixes it
# (measured: `NotAllowedError: The 'identity-credentials-get' feature is not
# enabled in this document`, with the origin correctly authorised).
#
# A popup opened with window.open is a TOP-LEVEL browsing context, so iframe
# permission policy does not apply to it. It only needs somewhere to land
# afterwards on an origin we control — docs/oauth-callback.html, published to
# GitHub Pages by the deploy-pages job — which posts the token back to the game
# window and closes.
#
# response_type=id_token (OpenID Connect implicit) rather than an authorization
# code: a code would have to be exchanged for tokens, and Google requires a
# client_secret for Web clients, which a browser cannot hold. The implicit
# response hands back a signed ID token directly, which is exactly what
# AuthService needs, and `nonce` is what protects it from replay.

func _sign_in_web() -> Dictionary:
	var window := JavaScriptBridge.get_interface("window")
	if window == null:
		return _error("Sign-in isn\'t available in this browser.")
	_web_result = ""
	_web_done = false
	if _web_cb == null:
		# Held for the lifetime of this node: a JavaScriptBridge callback is only
		# valid while its wrapper is referenced from GDScript, so dropping it
		# would silently detach the handler (same rule as Save's lifecycle hook).
		_web_cb = JavaScriptBridge.create_callback(_on_web_credential)
	window.rallyGoogleAuth = _web_cb

	var state := _random_urlsafe(24)
	var url := "%s?%s" % [FirebaseConfig.GOOGLE_AUTH_URL, RestClient.form_encode({
		"client_id": FirebaseConfig.GOOGLE_WEB_CLIENT_ID,
		"redirect_uri": FirebaseConfig.GOOGLE_WEB_REDIRECT_URI,
		"response_type": "id_token",
		"scope": SCOPES,
		"nonce": _random_urlsafe(24),
		"state": state,
		"prompt": "select_account",
	})]

	# Opened synchronously from the button's own input event — a popup opened
	# outside a user gesture is blocked, which is reported rather than hung.
	JavaScriptBridge.eval("""
		(function () {
			window.rallyGoogleError = '';
			var expected = '%s';
			function onMessage(e) {
				if (e.origin !== '%s') { return; }
				var d = e.data || {};
				if (d.source !== 'tappa-oauth') { return; }
				window.removeEventListener('message', onMessage);
				if (d.state !== expected) {
					window.rallyGoogleError = 'state';
					window.rallyGoogleAuth('');
					return;
				}
				if (d.error) { window.rallyGoogleError = d.error; }
				window.rallyGoogleAuth(d.id_token || '');
			}
			window.addEventListener('message', onMessage);
			var popup = window.open('%s', 'tappa_signin', 'width=480,height=680');
			if (!popup) {
				window.removeEventListener('message', onMessage);
				window.rallyGoogleError = 'blocked';
				window.rallyGoogleAuth('');
			}
		})();
	""" % [state, FirebaseConfig.GOOGLE_WEB_CALLBACK_ORIGIN, url], true)

	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	while not _web_done and Time.get_ticks_msec() < deadline:
		if _cancelled:
			return _error("Sign-in cancelled.")
		await get_tree().process_frame
	if not _web_done:
		return _error("Sign-in timed out.")
	if _web_result == "":
		var reason := String(JavaScriptBridge.eval("window.rallyGoogleError || ''", true))
		if reason == "blocked":
			return _error("Your browser blocked the sign-in window. Allow pop-ups and try again.")
		if reason == "state":
			return _error("Sign-in couldn\'t be verified. Please try again.")
		return _error("Google sign-in was cancelled.")
	return {"ok": true, "id_token": _web_result, "error": ""}


func _on_web_credential(args: Array) -> void:
	_web_result = String(args[0]) if args.size() > 0 and args[0] != null else ""
	_web_done = true


# --- PKCE helpers -------------------------------------------------------------

# base64url: standard base64 with the two URL-hostile characters swapped and the
# padding removed, as every OAuth endpoint expects.
static func _base64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")


static func _random_urlsafe(length: int) -> String:
	var crypto := Crypto.new()
	return _base64url(crypto.generate_random_bytes(length)).substr(0, length)


static func _s256(verifier: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(verifier.to_utf8_buffer())
	return _base64url(ctx.finish())


# Turn a failed token exchange into something diagnosable.
#
# The OAuth token endpoint ALWAYS explains itself in the response body
# (`error` plus a human-readable `error_description`), and reporting only the
# HTTP status throws that away — "failed (http_400)" is indistinguishable
# between a stale code, a redirect_uri mismatch and a bad PKCE verifier, which
# are three completely different fixes. Mirrors AuthService._message_for: map
# what we recognise, but never swallow what we don't.
func _token_error(response: Dictionary) -> String:
	var body: Variant = response.get("json", {})
	var code := ""
	var detail := ""
	if typeof(body) == TYPE_DICTIONARY:
		code = String((body as Dictionary).get("error", ""))
		detail = String((body as Dictionary).get("error_description", ""))
	# Also to the log: the on-screen message has to stay short, but the raw pair
	# is what actually identifies the fault when someone reports it.
	push_warning("GoogleSignIn: token exchange failed (status %d) %s %s"
		% [int(response.get("status", 0)), code, detail])
	match code:
		"invalid_grant":
			# The code was already used, expired (they are short-lived), or was
			# issued for a different client.
			return "Google sign-in expired — please try again."
		"redirect_uri_mismatch":
			return "Google rejected the sign-in redirect (redirect_uri_mismatch). %s" % detail
		"invalid_client":
			return "This build's Google client ID is wrong or is not a Desktop client."
		_:
			if code != "" and detail != "":
				return "Google sign-in failed: %s — %s" % [code, detail]
			if code != "":
				return "Google sign-in failed: %s" % code
			return "Google sign-in failed (status %d)." % int(response.get("status", 0))


func _error(message: String) -> Dictionary:
	return {"ok": false, "id_token": "", "error": message}
