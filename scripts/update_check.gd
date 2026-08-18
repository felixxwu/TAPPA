class_name UpdateCheck
extends RefCounted
# Docs: features/update-check.md — update in the same change as this file.
# Tests: tests/headless/test_update_check.gd — extend in the same change.
# "A newer build is out" check, for the NATIVE builds only.
#
# WHY ONLY NATIVE. The web build is served from a build-unique, cache-busted path
# on itch (see the header of build_web.sh), so a browser player is by construction
# already on the newest build — there is nothing to tell them. Every native build
# needs telling: the itch .exe and the sideloaded itch .apk have no updater at all,
# and the PLAY build does not reliably auto-update either — a closed/internal
# testing track in particular leaves testers sitting on an old build indefinitely.
# So Play is checked too; what changes is only WHERE the prompt sends the player
# (store_url), because pointing a Play install at an off-store download is against
# Play policy. See features/update-check.md.
#
# WHAT IS COMPARED. Every build script stamps application/config/version as
# "0.<git commit count> (<short sha>)" — a monotonically increasing integer with a
# traceability tag glued on. So "is there a newer build?" is an integer compare on
# the commit count, with no version-string ordering to get wrong; anything that
# does not parse (the editor's "0.0-dev") disables the check entirely.
#
# WHERE "LATEST" COMES FROM. A tiny JSON document published to GitHub Pages by the
# release workflow AFTER the store uploads succeed (deploy.yml → deploy-pages), so
# a build that failed to reach itch is never announced. No auth, no rate limit, no
# new backend — and deliberately NOT Firestore: the version is public, unowned data
# and putting it there would mean a rules change plus a CI write credential for
# something a static file answers.
#
# EVERY FAILURE IS A SILENT NO-OP. Offline, DNS failure, a 404 from Pages, a
# malformed document, a Pages outage — all of them return "no newer build" and the
# player sees nothing. A version check must never be something a player notices
# going wrong.

# The document the release workflow publishes. The query string is a cache-buster:
# the response is tiny, and a CDN holding a stale copy is the one failure mode that
# would keep announcing (or hiding) the wrong build.
const VERSION_URL := "https://felixxwu.github.io/TAPPA/version.json"

# Where an itch player is sent. The itch page carries both of the builds it ships
# (Windows .exe, Android .apk), so one link covers them.
const ITCH_URL := "https://felixxwu.itch.io/tappa"

# Where a PLAY player is sent — its own store listing, never the itch download:
# Play's policy is that a Play install updates through Play. The https form (not
# market://) is deliberate: Android hands it to the Play app when installed and
# falls back to a browser when not, so it can't dead-end.
#
# The package id is duplicated in two other places by necessity — export_presets.cfg
# preset.2 `package/unique_name` and deploy.yml's `PACKAGE_NAME` — because there is
# no runtime API that reports it (Godot 4.6 has no OS.get_bundle_identifier).
# Changing the Play package means changing all three.
const PLAY_PACKAGE := "tappa.game"
const PLAY_URL := "https://play.google.com/store/apps/details?id=" + PLAY_PACKAGE

# Save.get_setting / set_setting key holding the newest build the player has
# already been told about. Lives in the DEVICE-LOCAL settings bag (excluded from
# cloud sync — see save_manager.gd) because "I dismissed this on my phone" says
# nothing about the desktop install the same career is synced to.
const DISMISSED_SETTING := "update_prompt_dismissed_build"


# The commit count embedded in a stamped version string ("0.61 (b154d5c)" -> 61),
# or -1 when there isn't one. Unparseable covers the cases that matter: the
# checked-in "0.0-dev" the editor and the test runner see, an empty setting, and
# any future format change — all of which must disable the check rather than guess
# a number.
static func build_number(version: String) -> int:
	var head := version.strip_edges().split(" ")[0]  # drop the " (<sha>)" tag
	var parts := head.split(".")
	var tail := String(parts[parts.size() - 1])
	if not tail.is_valid_int():
		return -1
	var n := tail.to_int()
	return n if n > 0 else -1


# The running build's commit count, or -1 in the editor / tests.
static func current_build() -> int:
	return build_number(str(ProjectSettings.get_setting("application/config/version", "")))


# True when this build is one the player has to update by hand. False disables the
# whole feature — no request is made at all.
static func applicable() -> bool:
	if Platform.is_headless():
		return false
	if Platform.is_web():
		return false  # served from a build-unique path; always current
	return current_build() > 0


# The store this build came from. The `play` feature is set by preset.2's
# custom_features — it is the only thing that distinguishes the two Android builds
# at runtime. Parameterised (rather than reading OS.has_feature inline) so both
# branches are reachable from a test.
static func store_url(play := OS.has_feature("play")) -> String:
	return PLAY_URL if play else ITCH_URL


# Label for the prompt's confirming button. Naming the destination matters here:
# "Get the update" on a Play install would imply a download the player is not
# about to get — Play needs them to press Update on the listing.
static func store_label(play := OS.has_feature("play")) -> String:
	return "Open Google Play" if play else "Get the update"


# GET the published document and return the build number it names, or -1 for
# "don't prompt" (offline, non-2xx, unparseable, or a document with no usable
# build field). `rest` is any object with RestClient's request_json — the cloud
# stack's client in the game, FakeRestClient in tests.
static func fetch_latest_build(rest: Object) -> int:
	if rest == null or not rest.has_method("request_json"):
		return -1
	var url := "%s?from=%d" % [VERSION_URL, current_build()]
	var res: Dictionary = await rest.request_json(
		HTTPClient.METHOD_GET, url, PackedStringArray(["Accept: application/json"]))
	if not bool(res.get("ok", false)):
		return -1
	var json: Variant = res.get("json", {})
	if typeof(json) != TYPE_DICTIONARY:
		return -1
	return _read_build(json.get("build", null))


# The `build` field, whether the publisher wrote it as a number or a string.
# Anything else — null, a nested object, a non-numeric string — is -1.
static func _read_build(value: Variant) -> int:
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			var n := int(value)
			return n if n > 0 else -1
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(value).strip_edges()
			return s.to_int() if s.is_valid_int() and s.to_int() > 0 else -1
		_:
			return -1


# The one decision: show the prompt or not.
#
# `dismissed` is the newest build already shown, so a player who said "Not now" is
# asked again only when a build newer than THAT one ships — not on every launch
# (nagging), and not never (one dismissal muting the check forever).
static func should_prompt(current: int, latest: int, dismissed: int) -> bool:
	if current <= 0 or latest <= 0:
		return false
	return latest > current and latest > dismissed


# Body text for the prompt. Kept here, next to the parsing, so the numbers shown
# can't drift from the numbers compared.
static func prompt_body(current: int, latest: int) -> String:
	return ("A newer version of TAPPA is available.\n\nYou have build %d — the latest is build %d."
		% [current, latest])
