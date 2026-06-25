extends GutTest
# Loading overlay shown by world.gd while the world is built (track, terrain,
# tree/bush scatter). The staged-loading awaits are no-ops under headless, so
# generation must still complete synchronously when main.tscn is instantiated.


func test_set_step_updates_label() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen.set_step("Scattering trees…")
	assert_eq(screen._step.text, "Scattering trees…", "step label reflects set_step()")


func test_finish_frees_overlay() -> void:
	var screen := LoadingScreen.new()
	add_child(screen)
	screen.finish()
	assert_true(screen.is_queued_for_deletion(), "finish() tears the overlay down")


func test_world_generation_completes_synchronously_when_headless() -> void:
	# In headless the _yield_frame() awaits collapse to no-ops, so the entire
	# staged generation chain runs within instantiate()+add_child. HUD.track_progress
	# is wired at the very end of that chain, so its presence proves the whole
	# chain ran — i.e. staging didn't accidentally defer world-gen across frames.
	var scene := load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	var hud := scene.get_node("HUD")
	assert_not_null(hud.track_progress,
		"world finished generating synchronously (HUD.track_progress is set)")


func test_loading_overlay_removed_after_generation() -> void:
	var scene := load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	# finish() queue_frees the overlay during _ready; one frame later it's gone.
	await get_tree().process_frame
	for child in scene.get_children():
		assert_false(child is LoadingScreen, "loading overlay is removed once the world is ready")
