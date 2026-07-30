class_name FirebaseConfig
extends RefCounted
# Build configuration for the Firebase project backing optional cloud save.
#
# This is deliberately NOT in config/game_config.tres: the config-first rule in
# CLAUDE.md covers gameplay / look values a designer retunes in the inspector.
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
const AUTH_DOMAIN := "tapparally.firebaseapp.com"

# OAuth 2.0 client ids for Google sign-in. These are NOT the Firebase appId —
# they come from the Google Cloud credentials console:
#   WEB     — auto-created when Google is enabled as a Firebase Auth provider.
#   DESKTOP — created by hand as an "OAuth client ID -> Desktop app". Only a
#             desktop-type client is allowed to use a loopback redirect_uri,
#             which is how the native (Windows / macOS / Android) flow works.
# Empty means "Google sign-in is not configured" — the UI hides the button
# rather than offering a option that cannot work. See features/cloud-save.md.
const GOOGLE_WEB_CLIENT_ID := "406164142327-v43njgg3s2sr7m35mqgabcg78c865rph.apps.googleusercontent.com"
const GOOGLE_DESKTOP_CLIENT_ID := "406164142327-ts31091ct9kc92e63otb7brul3kvfk4g.apps.googleusercontent.com"

# The Desktop client's secret. Google REQUIRES this in the token exchange even
# though PKCE is also in use: its docs exempt only Android, iOS and Chrome
# clients from client_secret, and a "Desktop app" client is none of those —
# omitting it fails with `invalid_request: client_secret is missing`.
#
# It therefore ships inside the game, which Google's installed-app model
# explicitly anticipates ("the client_secret is obviously not treated as a
# secret" in that context) — any distributed binary can be unpacked in minutes,
# so hiding it here would buy nothing real. It is NOT a credential for player
# data: it identifies the app to Google, and PKCE is what actually
# authenticates each individual exchange. Player data is protected by
# firestore.rules and the per-user id token.
#
# The one genuine consequence of it being public: someone could build an app
# that shows YOUR consent screen. If that ever happens, rotate it on the
# Credentials page and ship a build with the new value.
const GOOGLE_DESKTOP_CLIENT_SECRET := "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"

# --- Endpoints ---------------------------------------------------------------

const IDENTITY_URL := "https://identitytoolkit.googleapis.com/v1"
const TOKEN_URL := "https://securetoken.googleapis.com/v1/token"
const FIRESTORE_URL := "https://firestore.googleapis.com/v1"
const GOOGLE_AUTH_URL := "https://accounts.google.com/o/oauth2/v2/auth"
const GOOGLE_TOKEN_URL := "https://oauth2.googleapis.com/token"


# Identity Toolkit endpoints all take the API key as a query parameter.
static func identity(method: String) -> String:
	return "%s/accounts:%s?key=%s" % [IDENTITY_URL, method, API_KEY]


static func token_url() -> String:
	return "%s?key=%s" % [TOKEN_URL, API_KEY]


# The single Firestore document holding a player's profile.
static func user_doc(uid: String) -> String:
	return "%s/projects/%s/databases/(default)/documents/users/%s" % [FIRESTORE_URL, PROJECT_ID, uid]


# True when the console-side Google provider setup has been done for whichever
# flow this platform uses. Callers hide the Google button when false.
static func google_configured() -> bool:
	if Platform.is_web():
		return GOOGLE_WEB_CLIENT_ID != ""
	# Native needs BOTH halves: a Desktop client id without its secret cannot
	# complete the token exchange, so offering the button would be a dead end.
	return GOOGLE_DESKTOP_CLIENT_ID != "" and GOOGLE_DESKTOP_CLIENT_SECRET != ""


# Short platform tag stored on the cloud document so the conflict prompt can say
# "from android" rather than showing the player a raw uid.
static func device_tag() -> String:
	if Platform.is_web():
		return "web"
	return OS.get_name().to_lower()
