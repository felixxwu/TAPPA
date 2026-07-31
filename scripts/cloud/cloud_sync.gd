class_name CloudSync
extends Node
# Synchronises the local profile with a single Firestore document per user.
#
# The local file stays the SOURCE OF TRUTH for the running session — this class
# copies it up and, when the player agrees, copies a newer copy down. A sync
# failure of any kind degrades to "not synced" and never blocks, stalls or
# damages local play.
#
# WHY REVISION COUNTERS, NOT TIMESTAMPS. "Newest wins" needs an ordering, and
# wall-clock time is not one: a phone and a desktop routinely disagree, and a
# device with a wrong clock would silently eat the other device's career. The
# document carries a `revision` that only ever increments on a successful push;
# the local profile remembers the revision it last agreed with (`cloud_revision`).
# Divergence is then an exact statement — "the cloud moved on AND so did we" —
# rather than a guess about whose clock to believe. updated_utc is stored purely
# so the conflict prompt can say "2 hours ago"; nothing branches on it.

signal state_changed()
# Emitted when a pull finds that both sides moved on independently. The UI turns
# this into a player choice; sync stays paused until one is made.
signal conflict_detected(summary: Dictionary)

enum Status { IDLE, WORKING, SYNCED, OFFLINE, ERROR, CONFLICT }

# Longer than Save's ~1s local debounce on purpose: a disk write is free, a
# network round trip is not. Bursty progress (a rally payout granting a car, an
# upgrade and a rally record) collapses into one upload.
const PUSH_DEBOUNCE_SEC := 8.0

const BACKOFF_START_SEC := 2.0
const BACKOFF_MAX_SEC := 60.0

# Injected by Cloud.
var rest = null
var auth: AuthService = null

var status: int = Status.IDLE
var status_message := ""
var last_sync_utc := ""
# True when local changes exist that the cloud has not accepted yet.
var pending := false
# Set while a conflict is unresolved; blocks pushes so neither side is clobbered
# before the player decides.
var blocked_by_conflict := false

var _debounce: Timer
var _retry: Timer
var _backoff := BACKOFF_START_SEC
var _busy := false
var _conflict: Dictionary = {}


func _ready() -> void:
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = PUSH_DEBOUNCE_SEC
	_debounce.timeout.connect(_on_debounce)
	add_child(_debounce)

	_retry = Timer.new()
	_retry.one_shot = true
	_retry.timeout.connect(_on_retry)
	add_child(_retry)


# --- Public API --------------------------------------------------------------

# Note that the profile changed. Cheap and safe to call on every local save.
func request_push() -> void:
	if not _can_sync():
		return
	pending = true
	_debounce.start()


# Push right now, skipping the debounce (app close, sign-in, "Sync now").
func flush() -> void:
	if not _can_sync() or not pending:
		return
	_debounce.stop()
	push()


# Read the cloud document and reconcile it with the local profile. Returns
# {ok, state, error} where `state` is one of:
#   "no_cloud"     — nothing stored yet; local was pushed up
#   "up_to_date"   — both sides agree
#   "pushed"       — local had unsynced work at the agreed revision; uploaded
#   "applied"      — cloud was ahead and local was clean; downloaded
#   "conflict"     — both moved on; conflict_detected was emitted
#   "newer_schema" — the cloud was written by a newer build; refused
func pull() -> Dictionary:
	if not _can_sync():
		return {"ok": false, "state": "offline", "error": "Not signed in."}
	_set_status(Status.WORKING, "Checking…")
	var fresh := await auth.ensure_fresh_token()
	if not fresh.ok:
		return _fail_from_auth(fresh)

	var response = await rest.request_json(
		HTTPClient.METHOD_GET, FirebaseConfig.user_doc(auth.uid),
		RestClient.json_headers(auth.id_token))

	# 404 is the expected "this player has never synced" answer, not an error.
	if response.status == 404:
		var pushed := await push(true)
		return {"ok": pushed.ok, "state": "no_cloud", "error": pushed.get("error", "")}
	if not response.ok:
		return _fail_from_response(response)

	var remote := from_document(response.json)
	if remote.is_empty():
		# Present but unreadable. Do NOT overwrite it — a player with a corrupt
		# cloud doc still has their local career, and silently replacing the
		# remote copy would destroy whatever could have been recovered from it.
		_set_status(Status.ERROR, "Cloud save is unreadable.")
		return {"ok": false, "state": "unreadable", "error": "Cloud save is unreadable."}

	if int(remote.get("schema_version", 0)) > Save.SCHEMA_VERSION:
		_set_status(Status.ERROR, "Cloud save needs a newer version of the game.")
		return {"ok": false, "state": "newer_schema",
			"error": "Cloud save needs a newer version of the game."}

	var remote_revision := int(remote.get("revision", 0))
	var agreed_revision := _agreed_revision()
	var local_moved := Save.has_unsynced()

	if remote_revision <= agreed_revision:
		# We are level with, or ahead of, what the cloud has.
		if local_moved or pending:
			var pushed := await push(true)
			return {"ok": pushed.ok, "state": "pushed", "error": pushed.get("error", "")}
		_set_status(Status.SYNCED, "Up to date")
		return {"ok": true, "state": "up_to_date", "error": ""}

	if not local_moved:
		# Cloud is ahead and we have nothing to lose — take it.
		var applied := apply_remote(remote)
		if not applied.ok:
			_set_status(Status.ERROR, applied.error)
			return {"ok": false, "state": "apply_failed", "error": applied.error}
		_set_status(Status.SYNCED, "Up to date")
		return {"ok": true, "state": "applied", "error": ""}

	# Both sides moved on. Ask; do not guess.
	_conflict = remote
	blocked_by_conflict = true
	_set_status(Status.CONFLICT, "Your progress differs from the cloud.")
	conflict_detected.emit(conflict_summary())
	return {"ok": false, "state": "conflict", "error": ""}


# Upload the local profile. `force` bypasses the "nothing pending" shortcut.
func push(force := false) -> Dictionary:
	if not _can_sync():
		return {"ok": false, "error": "Not signed in."}
	if blocked_by_conflict and not force:
		return {"ok": false, "error": "Resolve the sync conflict first."}
	if _busy:
		# A push is already in flight; it will upload the current profile anyway
		# (the payload is always the whole thing), so this one is redundant.
		return {"ok": true, "error": ""}
	if not pending and not force:
		return {"ok": true, "error": ""}

	_busy = true
	var result := await _push_inner()
	_busy = false
	return result


func _push_inner() -> Dictionary:
	_set_status(Status.WORKING, "Saving to cloud…")
	var fresh := await auth.ensure_fresh_token()
	if not fresh.ok:
		return _fail_from_auth(fresh)

	var revision := _agreed_revision() + 1
	var stamp := Time.get_datetime_string_from_system(true)
	# Upload a copy with the sync bookkeeping normalised: those two fields
	# describe THIS device's relationship with the cloud, and shipping them as-is
	# would tell the next device that a freshly-downloaded profile already has
	# unsynced work.
	var blob: Dictionary = Save.profile.duplicate(true)
	blob["unsynced"] = false
	blob["cloud_revision"] = revision
	blob["cloud_uid"] = auth.uid
	# Settings are device-local and deliberately NOT published: the frame cap and
	# touch scheme that suit a phone are wrong for a desktop, and vice versa.
	blob.erase("settings")
	var payload := to_document(JSON.stringify(blob), Save.SCHEMA_VERSION,
		revision, stamp, FirebaseConfig.device_tag())

	var response = await rest.request_json(
		HTTPClient.METHOD_PATCH, _patch_url(),
		RestClient.json_headers(auth.id_token), JSON.stringify(payload))
	if not response.ok:
		return _fail_from_response(response)

	# Only now is the local profile allowed to claim it agrees with this revision.
	Save.profile["cloud_revision"] = revision
	Save.profile["cloud_uid"] = auth.uid
	Save.mark_synced()
	pending = false
	last_sync_utc = stamp
	_backoff = BACKOFF_START_SEC
	_set_status(Status.SYNCED, "Up to date")
	return {"ok": true, "error": ""}


# --- Conflict resolution -----------------------------------------------------

# A player-legible description of both sides, for the prompt.
func conflict_summary() -> Dictionary:
	if _conflict.is_empty():
		return {}
	var remote_profile: Variant = _parse_profile(String(_conflict.get("profile", "")))
	return {
		"local": describe_profile(Save.profile),
		"cloud": describe_profile(remote_profile if typeof(remote_profile) == TYPE_DICTIONARY else {}),
		"cloud_device": String(_conflict.get("device", "another device")),
		"cloud_updated_utc": String(_conflict.get("updated_utc", "")),
	}


# Keep this device's career: push over the cloud at a revision above the remote
# one, so the other device sees a clean "cloud is ahead" next time.
func resolve_keep_local() -> Dictionary:
	if _conflict.is_empty():
		return {"ok": false, "error": "No conflict to resolve."}
	Save.profile["cloud_revision"] = int(_conflict.get("revision", 0))
	_conflict = {}
	blocked_by_conflict = false
	pending = true
	return await push(true)


# Take the cloud copy, keeping a one-shot backup of what was replaced. A
# mis-tapped choice here would otherwise be unrecoverable.
func resolve_use_cloud() -> Dictionary:
	if _conflict.is_empty():
		return {"ok": false, "error": "No conflict to resolve."}
	var remote := _conflict
	_conflict = {}
	blocked_by_conflict = false
	var applied := apply_remote(remote, true)
	if not applied.ok:
		_set_status(Status.ERROR, applied.error)
		return applied
	_set_status(Status.SYNCED, "Up to date")
	return {"ok": true, "error": ""}


# Leave the conflict unresolved. Sync stays paused and the Account page keeps
# warning — deliberately NOT a silent pick of either side.
func resolve_later() -> void:
	blocked_by_conflict = true
	_set_status(Status.CONFLICT, "Sync paused — your progress differs from the cloud.")


# --- Applying a downloaded profile -------------------------------------------

# Replace the local profile with a downloaded one. The blob goes through the
# SAME load path as a local file (parse -> migrate -> sanitise), so cloud data
# gets identical validation, migration and catalogue pruning; there is no second
# implementation to keep in step with the schema.
func apply_remote(remote: Dictionary, backup := false) -> Dictionary:
	var parsed: Variant = _parse_profile(String(remote.get("profile", "")))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "Cloud save is unreadable."}
	if backup:
		Save.write_conflict_backup()
	var accepted := Save.adopt_profile(parsed)
	if not accepted:
		return {"ok": false, "error": "Cloud save needs a newer version of the game."}
	Save.profile["cloud_revision"] = int(remote.get("revision", 0))
	Save.profile["cloud_uid"] = auth.uid
	pending = false
	last_sync_utc = String(remote.get("updated_utc", ""))
	Save.mark_synced()
	return {"ok": true, "error": ""}


# --- Firestore document encoding ---------------------------------------------
# Pure functions, no state, no network — the easiest thing in this file to test
# and the easiest to get subtly wrong. Firestore's REST API wraps every value in
# a type tag; we only ever store strings and integers, so that is all we handle.

static func to_document(profile_json: String, schema_version: int, revision: int,
		updated_utc: String, device: String) -> Dictionary:
	return {
		"fields": {
			"profile": {"stringValue": profile_json},
			"schema_version": {"integerValue": str(schema_version)},
			"revision": {"integerValue": str(revision)},
			"updated_utc": {"stringValue": updated_utc},
			"device": {"stringValue": device},
		}
	}


# Inverse of to_document. Returns {} when the document is missing the fields we
# require, which the caller treats as "unreadable" rather than "empty".
static func from_document(doc: Variant) -> Dictionary:
	if typeof(doc) != TYPE_DICTIONARY:
		return {}
	var fields: Variant = (doc as Dictionary).get("fields", {})
	if typeof(fields) != TYPE_DICTIONARY:
		return {}
	var f := fields as Dictionary
	if not f.has("profile"):
		return {}
	return {
		"profile": _string_field(f, "profile"),
		"schema_version": _int_field(f, "schema_version"),
		"revision": _int_field(f, "revision"),
		"updated_utc": _string_field(f, "updated_utc"),
		"device": _string_field(f, "device"),
	}


static func _string_field(fields: Dictionary, key: String) -> String:
	var wrapped: Variant = fields.get(key, {})
	if typeof(wrapped) != TYPE_DICTIONARY:
		return ""
	return String((wrapped as Dictionary).get("stringValue", ""))


# Firestore encodes integers as STRINGS in JSON (to survive 64-bit values that
# JSON numbers cannot represent), so this must go through str -> int.
static func _int_field(fields: Dictionary, key: String) -> int:
	var wrapped: Variant = fields.get(key, {})
	if typeof(wrapped) != TYPE_DICTIONARY:
		return 0
	return String((wrapped as Dictionary).get("integerValue", "0")).to_int()


# A short human summary of a profile, for the conflict prompt. Counting is done
# here rather than in the UI so the prompt cannot drift from what is compared.
static func describe_profile(p: Dictionary) -> String:
	var cars: int = (p.get("cars", []) as Array).size()
	var done := 0
	var rallies: Variant = p.get("rallies", {})
	if typeof(rallies) == TYPE_DICTIONARY:
		for key in rallies as Dictionary:
			var entry: Variant = (rallies as Dictionary)[key]
			if typeof(entry) == TYPE_DICTIONARY and bool((entry as Dictionary).get("completed", false)):
				done += 1
	var car_word := "car" if cars == 1 else "cars"
	var rally_word := "rally" if done == 1 else "rallies"
	return "%d %s, %d %s completed" % [cars, car_word, done, rally_word]


# --- Internals ---------------------------------------------------------------

# An explicit updateMask keeps the PATCH from deleting fields we did not send —
# without it, Firestore treats the request as a full replace, which would drop
# any field added by a newer build of the game.
func _patch_url() -> String:
	var mask := ""
	for field in ["profile", "schema_version", "revision", "updated_utc", "device"]:
		mask += ("&" if mask != "" else "?") + "updateMask.fieldPaths=" + field
	return FirebaseConfig.user_doc(auth.uid) + mask


# The revision this device can legitimately claim to have agreed with.
#
# ZERO when the stored profile belongs to a DIFFERENT account. Without this,
# signing out of account A (revision 7) and into account B (revision 3) reads as
# "we are ahead of the cloud" and pushes A's career straight over B's document.
# Resetting to 0 makes any existing remote document look newer, which routes the
# situation into the normal matrix: adopt it if this device has nothing
# unsynced, otherwise raise the divergence prompt and let the player choose.
func _agreed_revision() -> int:
	if String(Save.profile.get("cloud_uid", "")) != auth.uid:
		return 0
	return int(Save.profile.get("cloud_revision", 0))


func _parse_profile(blob: String) -> Variant:
	if blob == "":
		return null
	var json := JSON.new()
	if json.parse(blob) != OK:
		return null
	return json.data


func _can_sync() -> bool:
	return auth != null and rest != null and auth.is_signed_in()


func _on_debounce() -> void:
	push()


func _on_retry() -> void:
	if pending:
		push()


func _fail_from_auth(result: Dictionary) -> Dictionary:
	if result.get("network", false):
		_go_offline(String(result.get("error", "")))
		return {"ok": false, "state": "offline", "error": String(result.get("error", ""))}
	_set_status(Status.ERROR, String(result.get("error", "")))
	return {"ok": false, "state": "auth", "error": String(result.get("error", ""))}


func _fail_from_response(response: Dictionary) -> Dictionary:
	var status_code := int(response.get("status", 0))
	# Transport failures and the server's own "try later" answers are the same
	# situation from here: come back shortly, keep the local profile untouched.
	if response.get("network", false) or status_code == 429 or status_code >= 500:
		_go_offline("No connection — will retry.")
		return {"ok": false, "state": "offline", "error": "No connection — will retry."}
	if status_code == 401 or status_code == 403:
		# 403 is almost always a security-rules misconfiguration rather than
		# anything the player did, so say so plainly with the code attached.
		var message := "Cloud sync was refused (%d). Check the Firestore rules." % status_code
		_set_status(Status.ERROR, message)
		return {"ok": false, "state": "denied", "error": message}
	var generic := "Cloud sync failed (%s)." % String(response.get("error", "unknown"))
	_set_status(Status.ERROR, generic)
	return {"ok": false, "state": "error", "error": generic}


func _go_offline(message: String) -> void:
	_set_status(Status.OFFLINE, message)
	if pending:
		_retry.wait_time = _backoff * randf_range(0.8, 1.2)
		_retry.start()
		_backoff = minf(_backoff * 2.0, BACKOFF_MAX_SEC)


func _set_status(new_status: int, message: String) -> void:
	status = new_status
	status_message = message
	state_changed.emit()
