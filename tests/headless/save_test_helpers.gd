class_name SaveTestHelpers
extends RefCounted
# Setup/teardown helpers for the throwaway-profile pattern used across the
# save-redirect tests (test_save_manager, test_damage_model, test_start_line,
# test_pause_menu, test_menu_flow, test_camera_manager, test_rally_session,
# test_menu_nav, test_input_remap, ...).
#
# Those files each hand-roll the same dance: point the Save autoload at a
# throwaway user:// path, enable saving, load a fresh default, and on teardown
# delete the file (plus its .bak / .tmp siblings) and restore the real profile
# path so the redirect never leaks into another file. These helpers centralise
# that so a new save-backed test doesn't have to re-derive the sibling-suffix
# cleanup or remember to restore DEFAULT_PROFILE_PATH.
#
# ADOPTION IS DEFERRED — the existing 9 save-redirect files are intentionally
# left untouched for now (they work, and rewriting them all is a separate,
# larger change). New tests are encouraged to use these.
#
# Usage:
#   const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
#   const TEST_PATH := "user://test_my_thing.json"
#   func before_each() -> void:
#       _save = SaveTestHelpers.redirect(TEST_PATH)   # fresh default at TEST_PATH
#   func after_each() -> void:
#       SaveTestHelpers.cleanup(TEST_PATH)            # delete + restore real path

# Sibling files the SaveManager can write alongside the main profile.
const _SUFFIXES := ["", ".bak", ".tmp"]


# Point the Save autoload at `path`, enable saving, and load a fresh default
# profile against it. Returns the Save node for convenience.
static func redirect(path: String) -> Node:
	var save: Node = (Engine.get_main_loop() as SceneTree).root.get_node("/root/Save")
	_remove(path)
	save.profile_path = path
	save.save_disabled = false
	save.load_or_new()  # fresh default against the test path
	return save


# Delete the throwaway profile (and its .bak / .tmp siblings) and restore the
# Save autoload's real profile path so the redirect never leaks into other files.
static func cleanup(path: String) -> void:
	_remove(path)
	var save: Node = (Engine.get_main_loop() as SceneTree).root.get_node("/root/Save")
	save.profile_path = save.DEFAULT_PROFILE_PATH


static func _remove(path: String) -> void:
	for suffix in _SUFFIXES:
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))
