extends GutTest
# Loading overlay shown by world.gd while the world is built (track, terrain,
# tree/bush scatter). The staged-loading awaits are no-ops under headless, so
# generation must still complete synchronously when main.tscn is instantiated.

# Preloaded (not load()ed) so the scene's script dependencies — world.gd and the
# generators it pulls in — compile when THIS test script is collected, not inside
# a test body. Otherwise any reload-time warning from those scripts gets
# attributed to the running test as an "unexpected error" in an isolated --fast
# run (GUT blames whatever test is executing when the engine logs the warning).
const MAIN_SCENE := preload("res://main.tscn")


func test_set_step_updates_label() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen.set_step("Scattering trees…")
	# The design system uppercases all menu text (house rule 1).
	assert_eq(screen._step.text, "SCATTERING TREES…", "step label reflects set_step() (uppercased)")


func test_finish_frees_overlay() -> void:
	var screen := LoadingScreen.new()
	add_child(screen)
	screen.finish()
	assert_true(screen.is_queued_for_deletion(), "finish() tears the overlay down")


func test_world_generation_completes_synchronously_when_headless() -> void:
	# In headless the _yield_frame() awaits collapse to no-ops, so the entire
	# staged generation chain runs within instantiate()+add_child. The TrackProgress
	# node is wired at the very end of that chain, so its presence proves the whole
	# chain ran — i.e. staging didn't accidentally defer world-gen across frames.
	var scene: Node3D = MAIN_SCENE.instantiate()
	add_child_autofree(scene)
	assert_not_null(scene.get_node_or_null("TrackProgress"),
		"world finished generating synchronously (TrackProgress node is set up)")


func test_loading_overlay_removed_after_generation() -> void:
	var scene: Node3D = MAIN_SCENE.instantiate()
	add_child_autofree(scene)
	# finish() queue_frees the overlay during _ready; one frame later it's gone.
	await get_tree().process_frame
	for child in scene.get_children():
		assert_false(child is LoadingScreen, "loading overlay is removed once the world is ready")
