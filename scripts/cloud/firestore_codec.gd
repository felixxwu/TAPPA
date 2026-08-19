class_name FirestoreCodec
extends RefCounted
# Docs: features/cloud-save.md — update in the same change as this file.
# Tests: tests/headless/test_cloud_leaderboard.gd, tests/headless/test_challenge_leaderboard.gd — extend in the same change.
# Firestore REST value encoding, shared by every caller that touches the
# Firestore API (CloudSync's user document, Leaderboard's stage_times entries).
#
# Pure statics, no state, no network. This exists as its own file because the two
# traps below are easy to get subtly wrong and were previously encoded twice —
# once inline in CloudSync.to_document, once in its private _int_field:
#
#   1. Firestore wraps EVERY value in a type tag ({"stringValue": …} /
#      {"integerValue": …}). An untagged value is rejected outright.
#   2. integerValue is carried as a JSON **string**, so 64-bit values survive
#      JSON's double-only number type. Decoding it as a number silently yields 0,
#      which would break every revision comparison and every stage time.
#
# A third trap lives in update_mask: a PATCH without an explicit
# updateMask.fieldPaths is treated by Firestore as a FULL REPLACE, dropping any
# field the request did not carry.
#
# Only strings and integers are handled, because that is all this project ever
# stores. Add a type here rather than hand-rolling a tag at a call site.


# --- Encoding ----------------------------------------------------------------

static func string_value(text: String) -> Dictionary:
	return {"stringValue": text}


static func int_value(number: int) -> Dictionary:
	# str(), not the raw int: see trap 2 above.
	return {"integerValue": str(number)}


static func bool_value(flag: bool) -> Dictionary:
	return {"booleanValue": flag}


# Wrap a plain {key: String|int|bool} dictionary as a Firestore document body.
# Insertion order is preserved, so the field order of the request matches the
# order the caller wrote — which is also the order update_mask() should be given.
static func document(values: Dictionary) -> Dictionary:
	var fields: Dictionary = {}
	for key in values:
		var value: Variant = values[key]
		if typeof(value) == TYPE_BOOL:
			fields[String(key)] = bool_value(bool(value))
		elif typeof(value) == TYPE_INT:
			fields[String(key)] = int_value(int(value))
		else:
			fields[String(key)] = string_value(String(value))
	return {"fields": fields}


# --- Decoding ----------------------------------------------------------------

# `fields` is the inner "fields" dictionary of a Firestore document, not the
# document itself. Missing or wrongly-shaped entries decode to the empty value
# rather than erroring: a partially-written document must not crash a reader.
static func string_field(fields: Dictionary, key: String) -> String:
	var wrapped: Variant = fields.get(key, {})
	if typeof(wrapped) != TYPE_DICTIONARY:
		return ""
	return String((wrapped as Dictionary).get("stringValue", ""))


static func int_field(fields: Dictionary, key: String) -> int:
	var wrapped: Variant = fields.get(key, {})
	if typeof(wrapped) != TYPE_DICTIONARY:
		return 0
	return String((wrapped as Dictionary).get("integerValue", "0")).to_int()


static func bool_field(fields: Dictionary, key: String) -> bool:
	var wrapped: Variant = fields.get(key, {})
	if typeof(wrapped) != TYPE_DICTIONARY:
		return false
	return bool((wrapped as Dictionary).get("booleanValue", false))


# Pull the "fields" dictionary out of a document response, or {} if absent.
static func fields_of(doc: Variant) -> Dictionary:
	if typeof(doc) != TYPE_DICTIONARY:
		return {}
	var fields: Variant = (doc as Dictionary).get("fields", {})
	if typeof(fields) != TYPE_DICTIONARY:
		return {}
	return fields as Dictionary


# --- Update mask --------------------------------------------------------------

# The query-string suffix pinning a PATCH to exactly these fields. Returns a
# leading "?" so it can be appended straight onto a document URL.
static func update_mask(field_paths: Array) -> String:
	var mask := ""
	for field in field_paths:
		mask += ("&" if mask != "" else "?") + "updateMask.fieldPaths=" + String(field)
	return mask
