class_name FirebaseConfig
extends RefCounted
# Docs: features/cloud-save.md — update in the same change as this file.
# Tests: tests/headless/test_cloud_auth.gd — extend in the same change.
# Build configuration for the Firebase project backing optional cloud save.
#
# This is deliberately NOT in scripts/game_config.gd: the config-first rule in
# CLAUDE.md covers gameplay / look values a designer retunes.
# These are backend endpoint identifiers — they change when the Firebase project
# changes, never during tuning, and a wrong value is a build error rather than a
# balance decision.
#
# SECURITY NOTE: API_KEY is a PUBLIC identifier, not a secret — it identifies the
# project to Google's APIs and is designed to ship inside clients. What actually
# protects the data is the Firestore security rules (firestore.rules), which pin
# every document to its owning uid. Do not treat leaking this key as an incident;
# do treat a permissive rules file as one.

const PROJECT_ID := "tapparally"
const API_KEY := "AIzaSyBbW4_34pecs85ffo7k5-gyo6KuwGyNVEs"

# --- Endpoints ---------------------------------------------------------------

# Where a sign-in email's link sends the player (Firebase appends the code as ?oobCode=).
# PLACEHOLDERS until the Cloudflare Pages domain exists: Phase 0.1 of
# todo/2026-11-27-rust-native-migration.md replaces both, and adds the domain to Firebase
# Auth's authorised domains. Until then sendOobCode fails with UNAUTHORIZED_DOMAIN.
const WEB_GAME_URL := "https://pages-domain-set-in-phase-0-1.invalid/"
const SIGN_IN_LANDING_URL := "https://pages-domain-set-in-phase-0-1.invalid/sign-in.html"

# `firebase emulators:exec` sets these two, which points every call at the local emulators
# (the emulator test suite, tests/emulator/). Unset, the game talks to the real Firebase.
const AUTH_EMULATOR_ENV := "FIREBASE_AUTH_EMULATOR_HOST"
const FIRESTORE_EMULATOR_ENV := "FIRESTORE_EMULATOR_HOST"


# The Auth emulator serves both Google auth hosts on one port, each as a path prefix.
static func _auth_base(path: String) -> String:
	var host := OS.get_environment(AUTH_EMULATOR_ENV)
	return "http://%s/%s" % [host, path] if host != "" else "https://" + path


static func _firestore_base() -> String:
	var host := OS.get_environment(FIRESTORE_EMULATOR_ENV)
	return "http://%s/v1" % host if host != "" else "https://firestore.googleapis.com/v1"


# Identity Toolkit endpoints all take the API key as a query parameter.
static func identity(method: String) -> String:
	return "%s/accounts:%s?key=%s" % [_auth_base("identitytoolkit.googleapis.com/v1"), method, API_KEY]


# The web game reads the code from its own URL; everywhere else, and whenever the code must come
# back to THIS tab (re-confirming an account deletion), the landing page shows it for pasting.
static func sign_in_continue_url(for_paste := false) -> String:
	if Platform.is_web() and not for_paste:
		return WEB_GAME_URL
	return SIGN_IN_LANDING_URL


static func token_url() -> String:
	return "%s?key=%s" % [_auth_base("securetoken.googleapis.com/v1/token"), API_KEY]


# The single Firestore document holding a player's profile.
static func user_doc(uid: String) -> String:
	return "%s/projects/%s/databases/(default)/documents/users/%s" % [_firestore_base(), PROJECT_ID, uid]


# Short platform tag stored on the cloud document so the conflict prompt can say
# "from android" rather than showing the player a raw uid.
#
# THE EXACT VALUES, because this string is shown to the PLAYER and every one of them is
# lowercase and terse: "web", or `OS.get_name().to_lower()` — i.e. "macos", "windows",
# "linux", "android", "ios". There is no title-case or friendly form anywhere: it is NOT
# "iPhone", "Desktop" or "Mac". Anything documenting or formatting this value must use the
# real spelling, and a UI that wants a prettier label has to map it deliberately rather than
# assume one. (Written down because an attempt at a new device readout documented the screen
# as showing "from iPhone", a value this function cannot return.)
static func device_tag() -> String:
	if Platform.is_web():
		return "web"
	return OS.get_name().to_lower()
