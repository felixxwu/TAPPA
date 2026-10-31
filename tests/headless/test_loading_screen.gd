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
const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")


# minimal_world() below trims the LIVE Config singleton and documents that restoring it
# is the next file's problem. Restore it here instead: this file sorts ahead of several
# that read ambient config without seating their own baseline, and a stripped world
# (no trees, no rocks, one turn) is a silent wrong answer there rather than a failure.
func after_all() -> void:
	Config.reset()


func test_set_step_updates_label() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen.set_step("Scattering trees…")
	# The design system uppercases all menu text (house rule 1).
	assert_eq(screen._step.text, "SCATTERING TREES…", "step label reflects set_step() (uppercased)")


# A random LoadingTips entry is shown from construction, not "" or a generation-stage
# name — world.gd no longer forwards its stage labels to this label (see _stage()).
func test_step_starts_on_a_random_tip() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	var upper_tips: Array[String] = []
	for tip in LoadingTips.TIPS:
		upper_tips.append(tip.to_upper())
	assert_true(upper_tips.has(screen._step.text),
		"the initial step line is one of the authored tips (uppercased)")


# --- Tip cycling -------------------------------------------------------------
# The tip cycles to a fresh draw every LoadingScreen._TIP_CYCLE_SEC while the
# overlay is up, so a long load doesn't sit on one sentence for its whole
# duration. _process() is driven directly with a synthetic delta rather than
# awaiting a real 7-second timer — the cycle logic is what's under test, not
# the engine's clock.

func _uppercased_tips() -> Array[String]:
	var upper_tips: Array[String] = []
	for tip in LoadingTips.TIPS:
		upper_tips.append(tip.to_upper())
	return upper_tips


func test_tip_cycles_to_a_new_tip_after_seven_seconds() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	var before := screen._step.text
	# A delta just past the cycle threshold should swap the tip. LoadingTips.random()
	# never repeats the previous draw (the pool has 21 entries), so the new text differs.
	screen._process(LoadingScreen._TIP_CYCLE_SEC + 0.01)
	assert_ne(screen._step.text, before, "the tip changed once the cycle interval elapsed")
	assert_true(_uppercased_tips().has(screen._step.text),
		"and the new tip is still one of the authored entries")


func test_tip_does_not_cycle_before_seven_seconds() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	var before := screen._step.text
	screen._process(LoadingScreen._TIP_CYCLE_SEC - 0.01)
	assert_eq(screen._step.text, before, "the tip is unchanged before the cycle interval")


# A caller that claims the step line with set_step() ("Uploading…",
# "Preparing the garage…") owns it — the tip cycle must not overwrite their
# status text on the next tick.
func test_set_step_locks_the_tip_cycle() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen.set_step("Uploading…")
	var locked := screen._step.text
	screen._process(LoadingScreen._TIP_CYCLE_SEC + 0.01)
	assert_eq(screen._step.text, locked, "a locked step line survives a cycle tick")


# --- Animated ellipsis -------------------------------------------------------
# The headline's trailing "…" is replaced by an animated 0 → 1 → 2 → 3 dot
# field in a SIBLING label, so the center-aligned base text never shifts when
# the dot count changes. The dots label's TEXT just holds the visible dots
# (no space padding); constant width instead comes from custom_minimum_size,
# pinned in _init() to the pixel width of _MAX_DOTS dots — this holds
# regardless of whether the UI font is monospace.

func test_headline_strips_the_static_ellipsis() -> void:
	# The "…" that used to terminate the headline is now animated dots in a
	# separate label — set_title() strips it so the two don't stack ("……").
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	assert_false(screen._title.text.ends_with("…"),
		"no static ellipsis on the base headline (the animated dots replace it)")


func test_dots_start_empty() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	assert_eq(screen._dot_count, 0, "starts at 0 visible dots")
	assert_eq(screen._dots.text, "", "0 dots = no visible text")


func test_dots_cycle_zero_through_three() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen._process(LoadingScreen._DOT_STEP_SEC + 0.001)
	assert_eq(screen._dot_count, 1, "one step -> 1 dot")
	assert_eq(screen._dots.text, ".", "1 dot")
	screen._process(LoadingScreen._DOT_STEP_SEC + 0.001)
	assert_eq(screen._dot_count, 2, "two steps -> 2 dots")
	assert_eq(screen._dots.text, "..", "2 dots")
	screen._process(LoadingScreen._DOT_STEP_SEC + 0.001)
	assert_eq(screen._dot_count, 3, "three steps -> 3 dots")
	assert_eq(screen._dots.text, "...", "3 dots")
	# Fourth step wraps back to 0.
	screen._process(LoadingScreen._DOT_STEP_SEC + 0.001)
	assert_eq(screen._dot_count, 0, "wraps back to 0 after 3")
	assert_eq(screen._dots.text, "", "back to no visible text")


# The whole point of the separate dots label: its custom_minimum_size is pinned to
# the pixel width of _MAX_DOTS dots (set once in _init), so the label's LAID-OUT
# width (and thus the centered headline pair's position) never changes as dots
# cycle — even though the label's own text length varies from 0 to _MAX_DOTS.
func test_dots_label_has_constant_minimum_width() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	var expected_w := screen._dots.custom_minimum_size.x
	assert_true(expected_w > 0.0, "a fixed minimum width is pinned")
	for _i in 5:
		assert_eq(screen._dots.custom_minimum_size.x, expected_w,
			"dots label's minimum width never changes as the dot count cycles")
		screen._process(LoadingScreen._DOT_STEP_SEC + 0.001)


# The tip survives an actual world generation: world.gd's stage progression (used to
# forward each stage label — "Placing signs…", "Generating track…" — into this same
# label) must not overwrite it any more. Checked mid-generation, since the overlay is
# only queue_free()'d (not gone yet) by the time add_child_autofree() returns headless.
func test_world_generation_does_not_overwrite_the_tip_with_a_stage_label() -> void:
	SceneHelpers.minimal_world()
	var scene: Node3D = MAIN_SCENE.instantiate()
	add_child_autofree(scene)
	var overlay: LoadingScreen = null
	for child in scene.get_children():
		if child is LoadingScreen:
			overlay = child
	assert_not_null(overlay, "the loading overlay is still reachable (queue_free()'d, not gone yet)")
	var shown := overlay._step.text
	var stage_labels := ["GENERATING TRACK…", "CARVING ROAD INTO TERRAIN…",
		"PRECOMPUTING CHUNKS…", "BUILDING TERRAIN…", "PLACING PROPS…", "FILLING LAKES…",
		"SCATTERING TREES…", "SCATTERING BUSHES…", "PLACING SIGNS…", "WARMING SHADERS…"]
	assert_false(stage_labels.has(shown), "the step line never shows a raw generation-stage label")
	var upper_tips: Array[String] = []
	for tip in LoadingTips.TIPS:
		upper_tips.append(tip.to_upper())
	assert_true(upper_tips.has(shown), "the step line is one of the authored tips")


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
	# The staged chain runs identically on a 1-turn / no-foliage track, so trim the
	# generation (minimal_world) rather than paying the full ~18s build here — this
	# test asserts the chain RAN, not the track's size or tree count.
	SceneHelpers.minimal_world()
	var scene: Node3D = MAIN_SCENE.instantiate()
	add_child_autofree(scene)
	assert_not_null(scene.get_node_or_null("TrackProgress"),
		"world finished generating synchronously (TrackProgress node is set up)")


func test_loading_overlay_removed_after_generation() -> void:
	SceneHelpers.minimal_world()  # the overlay lifecycle is the same on a trimmed track
	var scene: Node3D = MAIN_SCENE.instantiate()
	add_child_autofree(scene)
	# finish() queue_frees the overlay during _ready; one frame later it's gone.
	await get_tree().process_frame
	for child in scene.get_children():
		assert_false(child is LoadingScreen, "loading overlay is removed once the world is ready")


func test_loading_screen_joins_loading_screen_group() -> void:
	var ls: LoadingScreen = autofree(LoadingScreen.new())
	assert_true(ls.is_in_group("loading_screen"),
		"LoadingScreen must be in the 'loading_screen' group so music resume can gate on it")


# Story mode (the cold open's opening lines): each line gets its time, the last one stays, and the
# finish signal fires once every line has had its turn.
func test_story_shows_each_line_for_its_time_then_holds_the_last() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen.set_process(false)  # driven by hand below
	watch_signals(screen)
	screen.story(PackedStringArray(["first", "second"]), 1.0)
	assert_true(screen.is_story())
	assert_false(screen._headline.visible, "the headline gives way")
	assert_false(screen._step.visible, "and the tip too")
	assert_eq(screen.story_line(), "first")
	assert_true(screen.story_running())
	for _i in 9:
		screen._process(0.1)
	assert_eq(screen.story_line(), "first", "not before its time")
	for _i in 2:
		screen._process(0.1)
	assert_eq(screen.story_line(), "second")
	assert_true(screen.story_running(), "the last line still has its time to run")
	assert_signal_not_emitted(screen, "story_finished")
	for _i in 11:
		screen._process(0.1)
	assert_false(screen.story_running())
	assert_signal_emit_count(screen, "story_finished", 1)
	for _i in 20:
		screen._process(0.1)
	assert_eq(screen.story_line(), "second", "the last line stays until finish()")
	assert_signal_emit_count(screen, "story_finished", 1, "once")


# A frame frozen by the world build mustn't eat a line before it has been seen.
func test_a_long_frame_does_not_skip_a_story_line() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	screen.set_process(false)
	screen.story(PackedStringArray(["first", "second"]), 1.0)
	screen._process(5.0)
	assert_eq(screen.story_line(), "first")
