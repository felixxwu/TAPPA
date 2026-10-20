class_name WorldPages
extends CanvasLayer
# Docs: features/world-session.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_world_session.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# Free roam's world pages (todo/2026-10-19-free-roam-pivot.md decisions 21–22), opened over a
# frozen game from the pause menu or the rest-stop page:
#   MAP   — the island: its coast, the biome-ring borders you've crossed, the roads you've driven,
#           the rest stops you've come across (orange lit, grey not), loot you've seen that's
#           still lying there (MiniMap.site_markers, shared with the minimap) and the car. It is
#           also the minimap's "whole map" (tap the minimap, or M / gamepad Back, which closes it too). Opened from a rest stop it doubles as the travel
#           picker: Prev / Next step through the lit stops, Travel goes there.
#   STATS — the lifetime counters that matter in free roam, one read-only card each
#           (CardUI.card_page / card_list).
# The map is a plain MenuPage (it is a picture, not a list); both use MenuNav, and Back (Esc /
# gamepad B, or the Back button) closes the page and calls the `on_close` it was opened with.

const STATS_SHOWN: Array = [LifetimeStats.DISTANCE_DRIVEN_M, LifetimeStats.REST_STOPS_LIT, LifetimeStats.TIMES_GAVE_UP]

@export var streamer: TerrainStreamer
@export var rest_stops: RestStops
@export var car: Node3D
@export var loot: Node  # LootDirector, for the loot still lying at seen sites

var _page: MenuPage
var _cards: CardCarousel
var _on_close := Callable()
var _canvas: MapCanvas
var _targets := PackedInt32Array()
var _selected := 0
var _travel_mode := false
var _here := -1
var _target_label: Label
var _travel_button: Button
var _prev_button: Button
var _next_button: Button
var _back_button: Button


func _init() -> void:
	layer = 7
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_open() -> bool:
	return _page != null


# The map. `from_site` >= 0 opens it as the travel picker at that rest stop.
func show_map(on_close: Callable, from_site := -1) -> void:
	_open(on_close)
	_travel_mode = from_site >= 0
	_here = from_site
	# Transparent body: only the drawn map itself is opaque, over the dim.
	_page = MenuPage.new({"title": "Map", "dim": true, "alpha": 0.0})
	add_child(_page)
	_canvas = MapCanvas.new()
	_canvas.pages = self
	# As big as the frame allows, leaving room for the title, the target line and the actions.
	var frame := WorldPanel.layout_frame_size(self, Vector2(480.0, 360.0))
	var side := maxf(minf(frame.x * 0.9, frame.y - UITheme.px(170)), UITheme.px(200))
	_canvas.custom_minimum_size = Vector2(side, side)
	_page.body().add_child(_canvas)
	_target_label = Label.new()
	_page.body().add_child(_target_label)
	_back_button = _page.add_action(UITheme.row_button("< Back", close))
	if _travel_mode:
		_targets = rest_stops.travel_targets(from_site)
		_prev_button = _page.add_action(UITheme.row_button("<", _step.bind(-1)))
		_next_button = _page.add_action(UITheme.row_button(">", _step.bind(1)))
		_travel_button = _page.add_action(UITheme.row_button("Travel", _travel))
		for b in [_prev_button, _next_button, _travel_button]:
			b.disabled = _targets.is_empty()
	_selected = 0
	_refresh_target()
	UITheme.enforce(_page)
	MenuNav.attach(_page, {first = _travel_button if _travel_mode and not _targets.is_empty() else _back_button, on_back = close})


func show_stats(on_close: Callable) -> void:
	_open(on_close)
	_page = CardUI.card_page(self, {"title": "Stats", "dim": true})
	var entries: Array = []
	for id in STATS_SHOWN:
		entries.append({"title": stat_text(id, Save.lifetime_stat(id)), "subtitle": LifetimeStats.label_for(id),
			"icon": STAT_ICONS.get(id, "stats")})
	entries.append({"title": "%d of %d" % [WorldSession.max_ring() + 1, streamer.settings.ring_count],
		"subtitle": "Biome rings reached", "icon": "region"})
	_cards = CardUI.card_list(_page, entries)
	_back_button = _page.add_action(UITheme.row_button("< Back", close))
	UITheme.enforce(_page)
	MenuNav.attach(_page, {first = _cards, on_back = close})


const STAT_ICONS := {
	LifetimeStats.DISTANCE_DRIVEN_M: "travel",
	LifetimeStats.REST_STOPS_LIT: "rest_stop",
	LifetimeStats.TIMES_GAVE_UP: "reset_road",
}


static func stat_text(id: String, value: int) -> String:
	if id == LifetimeStats.DISTANCE_DRIVEN_M:
		return "%.1f km" % (value / 1000.0)
	return str(value)


func _open(on_close: Callable) -> void:
	_clear()
	_on_close = on_close


func close() -> void:
	_clear()
	if _on_close.is_valid():
		_on_close.call()


func _clear() -> void:
	if _page != null:
		_page.queue_free()
		_page = null
	_canvas = null
	_cards = null


# M / gamepad Back (`toggle_map`, the key that opens the full map from driving) closes the map too.
func _unhandled_input(event: InputEvent) -> void:
	if _canvas != null and event.is_action_pressed("toggle_map") and not event.is_echo():
		get_viewport().set_input_as_handled()
		close()


func _step(dir: int) -> void:
	if _targets.is_empty():
		return
	_selected = posmod(_selected + dir, _targets.size())
	_refresh_target()


func selected_target() -> int:
	return _targets[_selected] if _travel_mode and not _targets.is_empty() else -1


func _refresh_target() -> void:
	if _target_label == null:
		return
	if not _travel_mode:
		_target_label.text = "%d rest stops lit" % rest_stops.lit_sites.size()
	elif _targets.is_empty():
		_target_label.text = "No other rest stop is lit yet"
	else:
		_target_label.text = rest_stops.name_of(selected_target())
	if _canvas != null:
		_canvas.queue_redraw()


func _travel() -> void:
	var t := selected_target()
	if t < 0:
		return
	_clear()
	rest_stops.travel_to(t)  # first, so the host sees the car has moved when it takes back over
	if _on_close.is_valid():
		_on_close.call()


# Readouts for tests.
func cards() -> CardCarousel:
	return _cards


func action_buttons() -> Array[Button]:
	var out: Array[Button] = [_back_button]
	if _travel_mode:
		out.append_array([_prev_button, _next_button, _travel_button])
	return out


# The drawn map. Fits the island into its rect, sea outside the coast.
class MapCanvas:
	extends Control
	var pages: WorldPages

	func _draw() -> void:
		var st := pages.streamer
		var s := st.settings
		var r_world := s.island_radius_m * 1.05
		var c := size * 0.5
		var k := minf(size.x, size.y) * 0.5 / r_world
		var to_px := func(p: Vector2) -> Vector2: return c + p * k
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.11, 0.2, 0.28))
		# The coast.
		var coast := PackedVector2Array()
		for i in 96:
			var a := TAU * i / 96.0
			coast.append(to_px.call(Vector2(cos(a), sin(a)) * st.terrain.coast_r(cos(a) * 1000.0, sin(a) * 1000.0)))
		draw_colored_polygon(coast, Color(0.32, 0.38, 0.27))
		# The biome-ring borders crossed (the noisy border, drawn as its average circle).
		var inner := s.island_radius_m * 0.82
		for ring in range(1, WorldSession.max_ring() + 1):
			draw_arc(c, inner * ring / s.ring_count * k, 0.0, TAU, 64, Color(1, 1, 1, 0.35), 1.0)
		# The roads driven.
		var net := st.network
		for si in net.seg_ax.size():
			var mx := (net.seg_ax[si] + net.seg_bx[si]) * 0.5
			var my := (net.seg_ay[si] + net.seg_by[si]) * 0.5
			if WorldSession.has_driven(mx, my):
				draw_line(to_px.call(Vector2(net.seg_ax[si], net.seg_ay[si])), to_px.call(Vector2(net.seg_bx[si], net.seg_by[si])),
					Color(0.95, 0.9, 0.75), 2.0)
		# The sites come across: rest stops (orange lit, grey not) and loot still lying there; the
		# travel target ringed.
		var target := pages.selected_target()
		for mk: Array in MiniMap.site_markers(st.sites, pages.rest_stops.lit_sites, pages.loot, Vector2.ZERO, INF):
			var p: Vector2 = to_px.call(mk[0])
			var col := MiniMap.marker_color(mk[1])
			if mk[1] == MiniMap.Marker.LOOT:
				draw_colored_polygon(PackedVector2Array([p + Vector2(0, -4.5), p + Vector2(4.5, 0), p + Vector2(0, 4.5), p + Vector2(-4.5, 0)]), col)
			else:
				draw_circle(p, 5.0, Color.BLACK)
				draw_circle(p, 4.0, col)
			if mk[2] == target:
				draw_arc(p, 8.0, 0.0, TAU, 24, Color.WHITE, 2.0)
		# The car.
		if pages.car != null:
			var cp: Vector2 = to_px.call(Vector2(pages.car.global_position.x, pages.car.global_position.z))
			var f := -pages.car.global_transform.basis.z
			var fwd := Vector2(f.x, f.z).normalized() if Vector2(f.x, f.z).length() > 0.01 else Vector2.UP
			var side := Vector2(-fwd.y, fwd.x)
			draw_colored_polygon(PackedVector2Array([cp + fwd * 7.0, cp - fwd * 4.0 + side * 4.0, cp - fwd * 4.0 - side * 4.0]), Color.WHITE)
