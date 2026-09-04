extends GutTest
# UsernamePopup (scripts/username_popup.gd) — the cloud display name: its sanitiser and
# its profile round-trip. The name is what the challenge board shows, so it is the one
# piece of the account layer with house rules of its own.
#
# SALVAGED from the deleted test_menu_flow.gd, which owned these two tests because the
# popup used to be raised from the global standings page. That page is gone (decision 30)
# and `AccountMenu` raises the popup now — but the rules below are the popup's own and
# need no host at all, which is why they live in their own file rather than following the
# screen into deletion.
#
# The wording of the rules is deliberate and not arbitrary: names render UPPERCASE
# everywhere (UITheme.enforce), a board row is narrow, and a name that filters away to
# nothing must be REFUSED rather than stored blank.

const TEST_PATH := "user://test_username_profile.json"

var _save: Node


func before_each() -> void:
	_save = Save
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()


func after_each() -> void:
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func test_the_sanitiser_enforces_the_house_rules() -> void:
	assert_eq(UsernamePopup.sanitize("  kangaroo "), "KANGAROO", "trimmed and uppercased")
	assert_eq(UsernamePopup.sanitize("k@ng#aroo!"), "KNGAROO", "illegal characters dropped")
	assert_eq(UsernamePopup.sanitize("a     b"), "A B", "runs of spaces collapse")
	assert_eq(UsernamePopup.sanitize("   "), "", "a name that filters away to nothing is empty")
	assert_lte(UsernamePopup.sanitize("ABCDEFGHIJKLMNOPQRSTUVWXYZ").length(),
		UsernamePopup.MAX_LEN, "a long name is capped")


# The chosen name round-trips through the profile, so the account menu and the board agree
# about who the player is.
func test_the_name_round_trips_through_the_profile() -> void:
	assert_eq(UsernamePopup.store("milk float"), "MILK FLOAT", "store returns the stored form")
	assert_eq(UsernamePopup.current(), "MILK FLOAT", "and current() reads it back")
	assert_eq(UsernamePopup.store("!!!"), "", "an unusable name is rejected")
	assert_eq(UsernamePopup.current(), "MILK FLOAT", "and leaves the existing one alone")
