extends GutTest
# NpcDialogue: pages type out, confirm finishes a page then turns it, and the last confirm closes it.

var d: NpcDialogue


func before_each() -> void:
	d = NpcDialogue.open(self, "res://textures/npc/tutorial.webp", ["First page.", "Second page."])
	watch_signals(d)


func after_each() -> void:
	if is_instance_valid(d):
		d.free()


func test_a_page_types_out_over_time() -> void:
	assert_true(d.typing(), "starts with nothing shown")
	d._process(1000.0)
	assert_false(d.typing(), "fully shown after long enough")


func test_confirm_finishes_the_page_then_turns_it_then_closes() -> void:
	d.advance()
	assert_false(d.typing(), "the first confirm shows the whole page")
	assert_eq(d.page, 0)
	d.advance()
	assert_eq(d.page, 1, "the next confirm turns the page")
	d.advance()
	d.advance()
	assert_signal_emitted(d, "finished")
	assert_true(d.is_queued_for_deletion())


func test_it_swallows_input_while_open() -> void:
	var ev := InputEventAction.new()
	ev.action = "menu_down"
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	assert_eq(d.page, 0, "menu input doesn't turn the page")
	var ok := InputEventAction.new()
	ok.action = "menu_select"
	ok.pressed = true
	Input.parse_input_event(ok)
	await get_tree().process_frame
	assert_false(d.typing(), "confirm reaches the dialogue")


func test_fill_puts_the_number_into_pages_that_ask_for_one() -> void:
	assert_eq(NpcLines.fill(["Has %d.", "No number, 100%."], 3), ["Has 3.", "No number, 100%."])
