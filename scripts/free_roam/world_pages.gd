class_name WorldPages
extends CanvasLayer
# Docs: features/world-session.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_world_session.gd, tests/headless/test_world_pages.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# Free roam's world pages (todo/2026-10-19-free-roam-pivot.md decisions 21–22), opened over a
# frozen game from the pause menu or the rest-stop page:
#   MAP   — the island: its coast, the biome-ring borders you've crossed, the roads you've driven
#           (and in grey the undriven road near them, `map_roads`),
#           the rest stops you've come across (orange lit, grey not; MiniMap.site_markers, shared
#           with the minimap) and the car. It is
#           also the minimap's "whole map" (tap the minimap, or M / gamepad Back, which closes it too).
#           It frames what has been explored (explored_view), not the whole island. Wherever it's
#           opened it is also the QUICK-TRAVEL picker: Prev / Next (or a tap on a lit rest stop)
#           pick a lit stop, Travel goes there. Travelling from off a checkpoint leaves the money
#           behind (LootDirector.drop_money), after a confirm.
#   STATS — the lifetime counters that matter in free roam, one read-only card each
#           (CardUI.card_page / card_list).
# The map is a plain MenuPage (it is a picture, not a list); both use MenuNav, and Back (Esc /
# gamepad B, or the Back button) closes the page and calls the `on_close` it was opened with.

const STATS_SHOWN: Array = [LifetimeStats.DISTANCE_DRIVEN_M, LifetimeStats.REST_STOPS_LIT, LifetimeStats.TIMES_GAVE_UP]

@export var streamer: TerrainStreamer
@export var rest_stops: RestStops
@export var car: Node3D
@export var loot: LootDirector

var _page: MenuPage
var _cards: CardCarousel
var _on_close := Callable()
var _canvas: MapCanvas
var _targets := PackedInt32Array()
var _selected := 0
var _travel_mode := false
var _here := -1
var travelled := false  # whether the map's last visit ended in a quick travel
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


# The map, which is also the quick-travel picker. `from_site` >= 0: opened at that rest stop (it is
# left out of the targets); otherwise the targets are every lit stop, nearest the car first.
func show_map(on_close: Callable, from_site := -1) -> void:
	_open(on_close)
	travelled = false
	_travel_mode = rest_stops != null
	_here = from_site
	# Transparent body: only the drawn map itself is opaque, over the dim.
	_page = MenuPage.new({"title": "Map", "dim": true, "alpha": 0.0})
	add_child(_page)
	_canvas = MapCanvas.new()
	_canvas.pages = self
	# As big as the frame allows, leaving room for the title, the target line and the actions.
	var frame := UITheme.layout_frame_size(self, Vector2(480.0, 360.0))
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
		_target_label.text = "%d checkpoints reached" % rest_stops.lit_sites.size()
	elif _targets.is_empty():
		_target_label.text = "No other checkpoint reached yet"
	else:
		_target_label.text = rest_stops.name_of(selected_target())
	if _canvas != null:
		_canvas.queue_redraw()


func _travel() -> void:
	var t := selected_target()
	if t < 0:
		return
	if travel_drops_money():
		ConfirmPopup.open(self, "Leave your money?", "Travelling from the road drops your $%d here. Travel from a checkpoint to keep it." % WorldSession.money(),
			[{"label": "Cancel", "callback": Callable()}, {"label": "Travel", "callback": _travel_to.bind(t, true)}], 0, 0)
		return
	_travel_to(t, false)


# Off a checkpoint, a travel can't carry money: it's dropped where the car is.
func travel_drops_money() -> bool:
	return loot != null and _here < 0 and rest_stops.prompt_site() < 0 and WorldSession.money() > 0


func _travel_to(t: int, drop: bool) -> void:
	if drop:
		loot.drop_money()
	_clear()
	travelled = true
	rest_stops.travel_to(t)  # first, so the host sees the car has moved when it takes back over
	if _on_close.is_valid():
		_on_close.call()


# A tap on the map at `local` (in the canvas): select the lit rest stop drawn nearest it, if one is
# within reach of the tap. Returns whether one was picked.
func tap_map_at(local: Vector2) -> bool:
	if _canvas == null or _targets.is_empty():
		return false
	var best := -1
	var best_d := float(UITheme.px(24))
	for k in _targets.size():
		var d: float = _canvas.to_canvas(streamer.sites.pos[_targets[k]]).distance_to(local)
		if d < best_d:
			best_d = d
			best = k
	if best < 0:
		return false
	_selected = best
	_refresh_target()
	return true


# The part of the island the map shows: everything explored (roads driven, sites come across, the
# car), with a margin, never smaller than map_min_view_m across, and never past the island.
func explored_view() -> Rect2:
	var pts := PackedVector2Array()
	if car != null:
		pts.append(Vector2(car.global_position.x, car.global_position.z))
	var net := streamer.network
	for si in net.seg_ax.size():
		if WorldSession.has_driven((net.seg_ax[si] + net.seg_bx[si]) * 0.5, (net.seg_ay[si] + net.seg_by[si]) * 0.5):
			pts.append(Vector2(net.seg_ax[si], net.seg_ay[si]))
			pts.append(Vector2(net.seg_bx[si], net.seg_by[si]))
	for mk: Array in MiniMap.site_markers(streamer.sites, rest_stops.lit_sites if rest_stops != null else {}, Vector2.ZERO, INF):
		pts.append(mk[0])
	return fit_view(pts, Config.data.map_min_view_m, streamer.settings.island_radius_m * 1.05)


# The square view around `pts`: their bounds plus a margin, at least `min_side` across, and at most
# the island (`max_half` either side of the centre).
static func fit_view(pts: PackedVector2Array, min_side: float, max_half: float) -> Rect2:
	if pts.is_empty():
		return Rect2(-Vector2.ONE * max_half, Vector2.ONE * max_half * 2.0)
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var side := minf(maxf(maxf(hi.x - lo.x, hi.y - lo.y) * 1.25, min_side), max_half * 2.0)
	var mid := (lo + hi) * 0.5
	return Rect2(mid - Vector2.ONE * side * 0.5, Vector2.ONE * side)


# Readouts for tests.
func cards() -> CardCarousel:
	return _cards


func action_buttons() -> Array[Button]:
	var out: Array[Button] = [_back_button]
	if _travel_mode:
		out.append_array([_prev_button, _next_button, _travel_button])
	return out


# The drawn map. Fits the island into its rect, sea outside the coast.
# The road segments the map draws: [nearby undriven, driven], as segment indices. A segment is
# nearby when its midpoint's cell lies within `near_m` of a driven cell, so the map shows the
# turnings you passed, not just the line you drove.
static func map_roads(net: RoadNetwork, near_m: float) -> Array:
	var cell := WorldSession.DRIVEN_CELL_M
	var driven := PackedInt32Array()
	var rest := PackedInt32Array()
	var near := {}
	var r := ceili(near_m / cell)
	for si in net.seg_ax.size():
		var mx := (net.seg_ax[si] + net.seg_bx[si]) * 0.5
		var my := (net.seg_ay[si] + net.seg_by[si]) * 0.5
		if not WorldSession.has_driven(mx, my):
			rest.append(si)
			continue
		driven.append(si)
		var c := Vector2i(floori(mx / cell), floori(my / cell))
		if near.has(c):
			continue
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if dx * dx + dy * dy <= r * r:
					near[c + Vector2i(dx, dy)] = true
	var nearby := PackedInt32Array()
	for si in rest:
		var c := Vector2i(floori((net.seg_ax[si] + net.seg_bx[si]) * 0.5 / cell), floori((net.seg_ay[si] + net.seg_by[si]) * 0.5 / cell))
		if near.has(c):
			nearby.append(si)
	return [nearby, driven]


class MapCanvas:
	extends Control
	var pages: WorldPages

	var _k := 1.0
	var _mid := Vector2.ZERO

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		clip_contents = true

	# World xz to this canvas, as last drawn.
	func to_canvas(p: Vector2) -> Vector2:
		return size * 0.5 + (p - _mid) * _k

	func _gui_input(event: InputEvent) -> void:
		var tap: bool = (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) \
			or (event is InputEventScreenTouch and event.pressed)
		if tap and pages.tap_map_at(event.position):
			accept_event()

	func _draw() -> void:
		var st := pages.streamer
		var s := st.settings
		# Frame what has been explored, not the whole island, so the start isn't a speck.
		var view := pages.explored_view()
		var k := minf(size.x / view.size.x, size.y / view.size.y)
		var c := size * 0.5
		var mid := view.get_center()
		_k = k
		_mid = mid
		var to_px := func(p: Vector2) -> Vector2: return c + (p - mid) * k
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.07, 0.1))
		# The coast.
		var coast := PackedVector2Array()
		for i in 96:
			var a := TAU * i / 96.0
			coast.append(to_px.call(Vector2(cos(a), sin(a)) * st.terrain.coast_r(cos(a) * 1000.0, sin(a) * 1000.0)))
		draw_colored_polygon(coast, Color(0.11, 0.13, 0.09))
		# The biome-ring borders crossed (the noisy border, drawn as its average circle).
		var inner := s.inner_radius_m()
		for ring in range(1, WorldSession.max_ring() + 1):
			draw_arc(to_px.call(Vector2.ZERO), inner * ring / s.ring_count * k, 0.0, TAU, 96, Color(1, 1, 1, 0.35), 1.0)
		# The roads driven, over the undriven road near them in grey.
		var net := st.network
		var roads := WorldPages.map_roads(net, Config.data.minimap_nearby_road_m)
		for pass_i in 2:
			var col := Color(0.6, 0.6, 0.6, 0.8) if pass_i == 0 else Color(0.95, 0.9, 0.75)
			for si: int in roads[pass_i]:
				draw_line(to_px.call(Vector2(net.seg_ax[si], net.seg_ay[si])), to_px.call(Vector2(net.seg_bx[si], net.seg_by[si])),
					col, 2.0)
		# The rest stops come across (orange lit, grey not); the travel target ringed.
		var target := pages.selected_target()
		for mk: Array in MiniMap.site_markers(st.sites, pages.rest_stops.lit_sites, Vector2.ZERO, INF):
			var p: Vector2 = to_px.call(mk[0])
			var col := MiniMap.marker_color(mk[1])
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
