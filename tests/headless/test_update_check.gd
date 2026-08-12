extends GutTest
# UpdateCheck — the "a newer native build is out" check (features/update-check.md).
#
# Runs entirely against FakeRestClient: no network, no Pages. Everything worth
# being strict about here is a decision that is invisible when it goes wrong —
# a version string that parses to the wrong number, a malformed document read as
# a real build, or a failed request treated as "you are out of date" — so those
# are what this file pins. Nothing here asserts the CURRENT build number or the
# published URL's contents; those move every commit.

var _rest: FakeRestClient


func before_each() -> void:
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)


# --- Version parsing ---------------------------------------------------------

func test_build_number_reads_the_stamped_commit_count() -> void:
	# The exact shape every build_*.sh writes into application/config/version.
	assert_eq(UpdateCheck.build_number("0.61 (b154d5c)"), 61,
		"the commit count is read out of a stamped version string")


func test_build_number_ignores_the_sha_tag() -> void:
	# A sha can be all digits ("0.61 (1234567)") — proof the tag is dropped
	# before parsing rather than being scanned for numbers.
	assert_eq(UpdateCheck.build_number("0.61 (1234567)"), 61,
		"the sha tag never contributes to the build number")


func test_build_number_rejects_the_dev_version() -> void:
	# What the editor and this test run actually see (project.godot ships
	# "0.0-dev"). Must disable the check, not parse to some number.
	assert_eq(UpdateCheck.build_number("0.0-dev"), -1,
		"the unstamped dev version has no build number")


func test_build_number_rejects_junk() -> void:
	for junk in ["", "   ", "nonsense", "0.", "0.abc", "v1.2.beta"]:
		assert_eq(UpdateCheck.build_number(junk), -1,
			"unparseable version %s has no build number" % [junk])


# --- The prompt decision ------------------------------------------------------

func test_prompts_when_a_newer_build_exists() -> void:
	assert_true(UpdateCheck.should_prompt(61, 74, 0),
		"a newer published build prompts")


func test_silent_when_current_or_ahead() -> void:
	assert_false(UpdateCheck.should_prompt(61, 61, 0), "the same build is not an update")
	assert_false(UpdateCheck.should_prompt(74, 61, 0),
		"a build NEWER than the published one (a local/dev build) never prompts")


func test_a_dismissal_mutes_only_that_build() -> void:
	# "Not now" on 74 must not silence 75 — and must silence 74 on the next launch.
	assert_false(UpdateCheck.should_prompt(61, 74, 74),
		"the build the player already dismissed does not prompt again")
	assert_true(UpdateCheck.should_prompt(61, 75, 74),
		"a build newer than the dismissed one prompts")


func test_unknown_versions_never_prompt() -> void:
	assert_false(UpdateCheck.should_prompt(-1, 74, 0),
		"an unparseable local version disables the prompt")
	assert_false(UpdateCheck.should_prompt(61, -1, 0),
		"an unreadable published version disables the prompt")


# --- Fetching -----------------------------------------------------------------

func test_fetch_reads_the_build_field() -> void:
	_rest.queue_ok({"build": 74, "version": "0.74 (abc1234)"})
	var latest: int = await UpdateCheck.fetch_latest_build(_rest)
	assert_eq(latest, 74, "the published build number is returned")


func test_fetch_accepts_a_string_build() -> void:
	# JSON writers vary; a quoted number must not read as "no update".
	_rest.queue_ok({"build": "74"})
	var latest: int = await UpdateCheck.fetch_latest_build(_rest)
	assert_eq(latest, 74, "a quoted build number is still a build number")


func test_fetch_gets_the_document_by_get() -> void:
	_rest.queue_ok({"build": 74})
	await UpdateCheck.fetch_latest_build(_rest)
	var sent := _rest.last()
	assert_eq(int(sent.get("method", -1)), HTTPClient.METHOD_GET, "the check is a plain GET")
	assert_true(String(sent.get("url", "")).begins_with(UpdateCheck.VERSION_URL),
		"the GET targets the published version document")
	assert_eq(String(sent.get("body", "")), "", "nothing is sent to the version document")


func test_offline_is_a_silent_no_op() -> void:
	_rest.queue_offline()
	var latest: int = await UpdateCheck.fetch_latest_build(_rest)
	assert_eq(latest, -1, "a transport failure reports no newer build")


func test_http_error_is_a_silent_no_op() -> void:
	# A 404 is the realistic one: Pages up, document missing (first deploy, or a
	# renamed file). It must read as "no update", never as an error the player sees.
	_rest.queue_error(404)
	var latest: int = await UpdateCheck.fetch_latest_build(_rest)
	assert_eq(latest, -1, "a non-2xx response reports no newer build")


func test_malformed_documents_are_a_silent_no_op() -> void:
	for body in [{}, {"build": "soon"}, {"build": null}, {"build": {"n": 74}}, {"build": 0}]:
		_rest.queued.clear()
		_rest.queue_ok(body)
		var latest: int = await UpdateCheck.fetch_latest_build(_rest)
		assert_eq(latest, -1, "malformed document %s reports no newer build" % [body])


func test_no_client_is_a_silent_no_op() -> void:
	# Cloud.rest can be null (the cloud stack failed to come up); the check must
	# degrade rather than crash HQ boot.
	var latest: int = await UpdateCheck.fetch_latest_build(null)
	assert_eq(latest, -1, "a missing REST client reports no newer build")


# --- Platform gating ----------------------------------------------------------

func test_not_applicable_headless() -> void:
	# The suite itself is the case: headless, and on the unstamped dev version.
	# Both are reasons to be off, and either one is enough.
	assert_false(UpdateCheck.applicable(),
		"the update check is inert in headless / unstamped builds")


# --- Where the prompt sends the player ----------------------------------------

func test_a_play_build_is_sent_to_play() -> void:
	# NEVER the itch download: a Play install must update through Play. This is the
	# assertion that keeps a well-meaning "one link for everyone" simplification
	# from becoming a policy violation.
	assert_eq(UpdateCheck.store_url(true), UpdateCheck.PLAY_URL,
		"a Play build is sent to its Play listing")
	assert_false(UpdateCheck.store_url(true).contains("itch.io"),
		"a Play build is never sent to an off-store download")


func test_an_itch_build_is_sent_to_itch() -> void:
	assert_eq(UpdateCheck.store_url(false), UpdateCheck.ITCH_URL,
		"the itch builds are sent to the itch page")


func test_the_button_names_the_destination() -> void:
	# "Get the update" on Play would promise a download that isn't coming — the
	# player has to press Update on the listing themselves.
	assert_ne(UpdateCheck.store_label(true), UpdateCheck.store_label(false),
		"the confirming button names the store it opens")
