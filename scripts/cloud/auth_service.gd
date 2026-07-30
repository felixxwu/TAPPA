class_name AuthService
extends RefCounted
# Firebase Authentication over the Identity Toolkit REST API.
#
# Owns the signed-in identity (uid / tokens / email) and nothing else — it knows
# how to obtain and refresh credentials, not what they are used for. CloudSync
# asks it for a fresh token before every Firestore call.
#
# CREDENTIAL STORAGE. Tokens live in user://auth.json, NOT in Save's profile
# dictionary. This is not a style preference: profile["settings"] is inside the
# blob that gets uploaded to Firestore, so parking a long-lived refresh token
# there would publish a credential into the database and replicate it to every
# other device on the account. The id_token (short-lived) is never written at
# all — it stays in memory.

signal signed_in(uid: String)
signal signed_out()
# Raised when an existing session could not be restored/refreshed for an
# AUTH reason (revoked, disabled, password changed). A network failure does NOT
# raise this — being offline must not sign anyone out.
signal auth_lost(reason: String)

const AUTH_PATH := "user://auth.json"

# Refresh this far ahead of the stated expiry so a request never races the clock.
const REFRESH_MARGIN_SEC := 300.0

var uid := ""
var email := ""
var id_token := ""
var refresh_token := ""
var expires_at := 0.0

# Injected by Cloud; a test substitutes a fake exposing request_json().
var rest = null
# Overridable so tests can redirect the credential file (mirrors Save.profile_path).
var auth_path := AUTH_PATH


func is_signed_in() -> bool:
	return uid != "" and refresh_token != ""


# --- Sign-in paths -----------------------------------------------------------
# Each returns {ok: bool, error: String} where `error` is already player-facing.

func sign_in_email(address: String, password: String) -> Dictionary:
	var invalid := _validate_credentials(address, password)
	if invalid != "":
		return {"ok": false, "error": invalid}
	return await _identity_call("signInWithPassword", {
		"email": address, "password": password, "returnSecureToken": true,
	})


func register_email(address: String, password: String) -> Dictionary:
	var invalid := _validate_credentials(address, password)
	if invalid != "":
		return {"ok": false, "error": invalid}
	return await _identity_call("signUp", {
		"email": address, "password": password, "returnSecureToken": true,
	})


# Exchange a Google ID token (obtained by GoogleSignIn) for a Firebase session.
func sign_in_with_google(google_id_token: String) -> Dictionary:
	if google_id_token == "":
		return {"ok": false, "error": "Google sign-in was cancelled."}
	return await _identity_call("signInWithIdp", {
		"postBody": "id_token=%s&providerId=google.com" % google_id_token,
		"requestUri": "http://localhost",
		"returnSecureToken": true,
	})


func send_password_reset(address: String) -> Dictionary:
	if not _looks_like_email(address):
		return {"ok": false, "error": "That doesn't look like an email address."}
	var response = await rest.request_json(
		HTTPClient.METHOD_POST, FirebaseConfig.identity("sendOobCode"),
		RestClient.json_headers(),
		JSON.stringify({"requestType": "PASSWORD_RESET", "email": address}))
	if not response.ok:
		return {"ok": false, "error": _message_for(response)}
	return {"ok": true, "error": ""}


# --- Token lifecycle ---------------------------------------------------------

# Ensure `id_token` is valid for at least REFRESH_MARGIN_SEC. Every Firestore
# call awaits this first.
func ensure_fresh_token() -> Dictionary:
	if not is_signed_in():
		return {"ok": false, "error": "Not signed in."}
	if id_token != "" and Time.get_unix_time_from_system() < expires_at - REFRESH_MARGIN_SEC:
		return {"ok": true, "error": ""}
	return await refresh()


func refresh() -> Dictionary:
	if refresh_token == "":
		return {"ok": false, "error": "Not signed in."}
	var response = await rest.request_json(
		HTTPClient.METHOD_POST, FirebaseConfig.token_url(),
		RestClient.form_headers(),
		RestClient.form_encode({
			"grant_type": "refresh_token", "refresh_token": refresh_token,
		}))
	if response.ok:
		var data: Dictionary = response.json if typeof(response.json) == TYPE_DICTIONARY else {}
		id_token = String(data.get("id_token", ""))
		refresh_token = String(data.get("refresh_token", refresh_token))
		uid = String(data.get("user_id", uid))
		expires_at = Time.get_unix_time_from_system() + float(String(data.get("expires_in", "3600")).to_int())
		_write_credentials()
		return {"ok": true, "error": ""}
	if response.network:
		# Offline. Keep the session; the caller retries. Signing out here would
		# lose the player's account because their train went into a tunnel.
		return {"ok": false, "error": "No connection.", "network": true}
	# A real rejection: the refresh token is dead and cannot be revived.
	var reason := _message_for(response)
	sign_out()
	auth_lost.emit(reason)
	return {"ok": false, "error": reason}


# Restore a session from disk at boot. Returns true when a session was restored
# (the token itself is refreshed lazily on first use, so this stays offline-safe
# and does not block startup on the network).
func restore() -> bool:
	var stored := _read_credentials()
	if stored.is_empty():
		return false
	uid = String(stored.get("uid", ""))
	refresh_token = String(stored.get("refresh_token", ""))
	email = String(stored.get("email", ""))
	id_token = ""
	expires_at = 0.0
	if not is_signed_in():
		_clear_state()
		return false
	signed_in.emit(uid)
	return true


func sign_out() -> void:
	var was_signed_in := is_signed_in()
	_clear_state()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(auth_path))
	if FileAccess.file_exists(auth_path):
		# globalize_path does not resolve user:// on every platform (notably web),
		# so fall back to the engine-relative removal.
		DirAccess.remove_absolute(auth_path)
	if was_signed_in:
		signed_out.emit()


func _clear_state() -> void:
	uid = ""
	email = ""
	id_token = ""
	refresh_token = ""
	expires_at = 0.0


# --- Internals ---------------------------------------------------------------

# Every Identity Toolkit call has the same shape: POST JSON, receive a session.
func _identity_call(method: String, body: Dictionary) -> Dictionary:
	if rest == null:
		return {"ok": false, "error": "Cloud is unavailable."}
	var response = await rest.request_json(
		HTTPClient.METHOD_POST, FirebaseConfig.identity(method),
		RestClient.json_headers(), JSON.stringify(body))
	if not response.ok:
		var result := {"ok": false, "error": _message_for(response)}
		if response.network:
			result["network"] = true
		return result
	_adopt_session(response.json)
	signed_in.emit(uid)
	return {"ok": true, "error": ""}


# Copy an Identity Toolkit response into our state and persist the durable part.
func _adopt_session(data: Variant) -> void:
	var d: Dictionary = data if typeof(data) == TYPE_DICTIONARY else {}
	uid = String(d.get("localId", uid))
	id_token = String(d.get("idToken", id_token))
	refresh_token = String(d.get("refreshToken", refresh_token))
	email = String(d.get("email", ""))
	var lifetime := String(d.get("expiresIn", "3600")).to_int()
	expires_at = Time.get_unix_time_from_system() + float(lifetime)
	_write_credentials()


func _write_credentials() -> void:
	if not is_signed_in():
		return
	# Same atomic .tmp -> rename dance as save_manager.save_now(), so a crash
	# mid-write cannot leave a truncated credential file that fails to parse and
	# silently signs the player out.
	var tmp := auth_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("AuthService: cannot write %s — the session will not survive a restart" % tmp)
		return
	f.store_string(JSON.stringify({
		"uid": uid,
		"refresh_token": refresh_token,
		"email": email,
	}, "\t"))
	f.close()
	var dir := DirAccess.open(auth_path.get_base_dir())
	if dir != null:
		dir.rename(tmp, auth_path)


func _read_credentials() -> Dictionary:
	if not FileAccess.file_exists(auth_path):
		return {}
	var f := FileAccess.open(auth_path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {}
	return json.data


# --- Validation + error messages ---------------------------------------------

func _validate_credentials(address: String, password: String) -> String:
	if not _looks_like_email(address):
		return "That doesn't look like an email address."
	# Firebase's own floor is 6; checking locally avoids a pointless round trip.
	if password.length() < 6:
		return "Password must be at least 6 characters."
	return ""


func _looks_like_email(address: String) -> bool:
	# Deliberately loose. Email validation by regex is a well-known losing game;
	# the server is the real authority. This only catches obvious typos before
	# spending a request on them.
	var at := address.find("@")
	return at > 0 and address.find(".", at) > at + 1 and not address.ends_with(".")


# Map the Firebase error code onto something a player can act on. An UNMAPPED
# code still yields a message AND preserves the raw code, so an unexpected
# failure is diagnosable from a screenshot instead of vanishing into "error".
func _message_for(response: Dictionary) -> String:
	if response.get("network", false):
		return "No connection — check your network and try again."
	var code := ""
	var body: Variant = response.get("json", {})
	if typeof(body) == TYPE_DICTIONARY:
		var err: Variant = body.get("error", {})
		if typeof(err) == TYPE_DICTIONARY:
			code = String(err.get("message", ""))
	# Firebase suffixes some codes with detail (e.g. "WEAK_PASSWORD : ...").
	var head := code.split(" ")[0] if code != "" else ""
	match head:
		"EMAIL_EXISTS":
			return "That email already has an account. Try signing in."
		"EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS":
			return "Wrong email or password."
		"USER_DISABLED":
			return "This account has been disabled."
		"WEAK_PASSWORD":
			return "Password must be at least 6 characters."
		"TOO_MANY_ATTEMPTS_TRY_LATER":
			return "Too many attempts. Wait a few minutes and try again."
		"OPERATION_NOT_ALLOWED":
			return "That sign-in method is switched off for this game."
		"TOKEN_EXPIRED", "USER_NOT_FOUND", "INVALID_REFRESH_TOKEN":
			return "Your session expired. Please sign in again."
		"INVALID_EMAIL":
			return "That doesn't look like an email address."
		_:
			if code != "":
				return "Sign-in failed (%s)." % code
			return "Sign-in failed (status %d)." % int(response.get("status", 0))
