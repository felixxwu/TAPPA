class_name LevelMap
extends Control
# Docs: features/level-editor.md — update in the same change as this file.
# The level view's full-screen map (M, or the pause menu's Map row): the road network over trees and buildings, pan / zoom, and teleport to one of the save's teleport points.

# The map closed: `teleported` when it closed by teleporting (the game is running again), `over_pause` when the pause menu opened it (open_over_pause) and should take back over.
signal closed(teleported: bool, over_pause: bool)

const IMAGE_PX := 4096
const GROUND := Color(0.80, 0.78, 0.66)
const TREE := Color(0.33, 0.47, 0.28)
const BUILDING := Color(0.45, 0.38, 0.34)
const ROAD := Color(0.93, 0.55, 0.16)
const TARMAC := Color(0.36, 0.37, 0.4)
const SNOW := Color(0.93, 0.95, 0.99)  # the biome mask's snow, painted over the ground under the trees
const SNOW_TREE := Color(0.42, 0.5, 0.46)  # a tree standing in the snow: frosted, so the snowfield still reads through the forest
const PATCH := Color(0.72, 0.66, 0.55)
const HEDGE := Color(0.16, 0.26, 0.12)
const FENCE := Color(0.5, 0.38, 0.24)
const LOG_PILE := Color(0.55, 0.36, 0.2)
const TELEPORT := TeleportBeacons.TELEPORT_TINT
const SHOP := Color(0.62, 0.25, 0.68)  # the shop obelisks' purple (TeleportBeacons.SHOP_TINT, lightened to read on the map)
const COVER_PX := 1024    # the ground cover is sampled this coarsely; it is only a faint wash under the trees
const COVER_TINT := 0.3   # how far the ground leans toward each cover type's colour
const MIN_MARK_PX := 7.0  # log piles never draw smaller than this, so they show when zoomed out
const ROUTE := Color(0.25, 0.8, 0.95)
const ROUTE_PX := 4.0
const ROAD_EDGE := Color(0.25, 0.15, 0.08)
const WASD := {KEY_W: Vector2.UP, KEY_A: Vector2.LEFT, KEY_S: Vector2.DOWN, KEY_D: Vector2.RIGHT}
const PAN_SPEED_PX := 600.0
const PICK_PX := 20.0  # how close the pointer (or the pad's crosshair) must be to a point or shop to hover and pick it
const NAME_GAP_PX := 12.0  # from a teleport's centre to its name
const NAME_PAD_PX := 3.0   # the dark box round a teleport's name
const NAME_BACK := Color(0.0, 0.0, 0.0, 0.6)
const FOG := Color(0.06, 0.058, 0.05)  # the undiscovered ground, near black: GROUND.darkened(0.925), the same as off the level's edge
const BORDER := Color(0.80, 0.78, 0.66, 0.35)  # the faint line round the level's edge, so the world's end shows through the fog
const BORDER_PX := 2.0
const REVEAL_TICK_S := 0.25         # how often the car's position is stamped into the discovery grid
const SEEN_KEY := "level_map_seen"  # the Save setting holding the discovery grid (LevelDiscovery.to_save)

var view: LevelView
var center := Vector2.ZERO  # world x, z at the middle of the screen
var zoom := 1.0             # screen pixels per metre
var _texture: ImageTexture
var _chains: Array[PackedVector2Array] = []  # road lines, split wherever the surface changes
var _tarmac: Array[bool] = []                 # per line in _chains
var _widths := PackedFloat32Array()           # per line in _chains, the road's full width in metres
var _buildings: Array[PackedVector2Array] = []  # each building's footprint corners in world metres
var _route := PackedVector2Array()  # the sat-nav line to the active delivery's target, worked out each time the map opens
var back_button: Button  # bottom-left "< Back": the way a touch screen (no M, no Esc) closes the map
var deliveries_button: Button  # beside Back: every delivery from the points found so far
var _buttons: HBoxContainer
var _preview_labels := {}  # while previewing: teleport point position -> "START" / "END"; every other point goes unnamed
var _start := Callable()  # set while a delivery's route is up for the player to confirm (preview); Back runs _cancel
var _cancel := Callable()
var _before := []  # the map's [visible, center, zoom, route] from before the preview, put back after it
var _over_pause := false  # opened from the pause menu: closing leaves the game paused for it
var _busy := false
var _pad_used := false  # a gamepad aims with the centre crosshair instead of the mouse
var _drag_from := Vector2.ZERO
var _touches := {}       # finger index -> screen position, for two-finger pinch zoom on a touch screen
var _pinched := false    # this touch gesture pinched, so lifting the fingers doesn't teleport
var _painted: Image  # the image when painted on the main thread (no thread support)
var _painter: Thread  # paints the map image in the background from load, so the first M opens instantly
var discovery: LevelDiscovery  # where the car has driven: only ground near it is drawn, the rest is under fog
var _fog: CanvasTexture        # discovery's fog, linear filtered so its edge is soft at any zoom
var _fog_dirty := true
var _reveal_clock := 0.0
var _revealed_at := Vector2.INF  # where the car was last stamped; it is only stamped again once it has moved a grid cell


func _init() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	process_mode = PROCESS_MODE_ALWAYS
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	# Full menu-row bars, big enough to hit with a thumb: a phone (no M, no Esc) closes the map with Back.
	_buttons = HBoxContainer.new()
	_buttons.anchor_top = 1.0
	_buttons.anchor_bottom = 1.0
	_buttons.offset_left = UITheme.FONT_SIZE
	_buttons.offset_top = -UITheme.FONT_SIZE - UITheme.MENU_ROW_H
	_buttons.offset_bottom = -UITheme.FONT_SIZE
	_buttons.grow_vertical = GROW_DIRECTION_BEGIN
	_buttons.add_theme_constant_override("separation", UITheme.FONT_SIZE)
	add_child(_buttons)
	back_button = UITheme.row_button(UITheme.caps("< Back"), close)
	deliveries_button = UITheme.row_button(UITheme.caps("All Delivery Jobs"), _open_deliveries)
	for b: Button in [back_button, deliveries_button]:
		b.custom_minimum_size = Vector2(UITheme.BUTTON_MIN_W, UITheme.MENU_ROW_H)
		_buttons.add_child(b)


func _ready() -> void:
	var cfg: GameConfig = Config.data
	discovery = LevelDiscovery.new(size_m(), cfg.level_map_reveal_cell_m)
	discovery.load_save(Save.get_setting(SEEN_KEY), view._save_path)
	if OS.has_feature("threads"):
		_painter = Thread.new()
		_painter.start(_paint)
	else:
		_painted = _paint()


func _exit_tree() -> void:
	if _painter != null:
		_painter.wait_to_finish()
		_painter = null


func size_m() -> float:
	return view.data.size


# M / the pad's Back: open from driving, or close. Does nothing over another paused page.
func toggle() -> void:
	if visible:
		close()
	elif not get_tree().paused:
		_open()


# The pause menu's Map row: the game is already paused, and closing hands back to the menu (`closed`).
func open_over_pause() -> void:
	if visible or _busy:
		return
	_over_pause = true
	_open()


func close() -> void:
	if _start.is_valid():
		_end_preview(false)
		return
	if _busy or not visible:
		return
	visible = false
	var over := _over_pause
	_over_pause = false
	get_tree().paused = over  # stays frozen under the pause menu it came from
	closed.emit(false, over)


func _open() -> void:
	if _busy:
		return
	visible = true
	get_tree().paused = true
	_touches.clear()
	if visible:
		build()
		reveal_at_car()
		update_fog()
		var car := view.get_parent().get_node_or_null("Car") as Node3D
		if car != null:
			center = Vector2(car.global_position.x, car.global_position.z)
		_route = _delivery_route(center if car != null else Vector2.ZERO)
		zoom = maxf(zoom, fit_zoom())
		queue_redraw()


# Shows a delivery's `route` fitted to the screen before it starts, its All Delivery Jobs button turned into Start: Start runs
# `start`, Back runs `cancel`, and either puts the map back as it was (closed, or open under the delivery's page).
func preview(route: PackedVector2Array, start: Callable, cancel: Callable) -> void:
	_before = [visible, center, zoom, _route]
	_start = start
	_cancel = cancel
	_route = route
	_preview_labels = {}
	if route.size() > 1:
		_preview_labels[_teleport_near(route[0])] = "START"
		_preview_labels[_teleport_near(route[route.size() - 1])] = "END"
	visible = true
	build()
	update_fog()
	var box := Rect2(route[0], Vector2.ZERO) if route.size() > 0 else Rect2()
	for p in route:
		box = box.expand(p)
	center = box.get_center()
	zoom = clampf(minf(size.x / maxf(box.size.x, 1.0), size.y / maxf(box.size.y, 1.0)) * 0.7, fit_zoom(), 20.0)
	deliveries_button.text = UITheme.caps("Start")
	queue_redraw()


# The position of the level's teleport point nearest `p` (a route's end is a teleport point).
func _teleport_near(p: Vector2) -> Vector2:
	var best := Vector2.INF
	for t: Dictionary in view.level.get("teleports", []):
		var at := Vector2(float(t["x"]), float(t["z"]))
		if best == Vector2.INF or at.distance_to(p) < best.distance_to(p):
			best = at
	return best


func _end_preview(started: bool) -> void:
	_preview_labels = {}
	var run := _start if started else _cancel
	_start = Callable()
	_cancel = Callable()
	visible = _before[0]
	center = _before[1]
	zoom = _before[2]
	_route = _before[3]
	deliveries_button.text = UITheme.caps("All Delivery Jobs")
	queue_redraw()
	run.call()


func _delivery_route(from: Vector2) -> PackedVector2Array:
	for t: Dictionary in view.level.get("teleports", []):
		if t.get("name", "") == LevelView.nav_target():
			return view._bake._roads().route(from, Vector2(float(t["x"]), float(t["z"])))
	return PackedVector2Array()


func fit_zoom() -> float:
	return minf(size.x, size.y) / size_m()


func to_screen(w: Vector2) -> Vector2:
	return size / 2.0 + (w - center) * zoom


func to_world(s: Vector2) -> Vector2:
	return center + (s - size / 2.0) / zoom


# The shops the player has found, the same way as teleport points.
func known_shops() -> Array:
	return view.level.get("shops", []).filter(func(t: Dictionary) -> bool:
		return discovery != null and discovery.shown(Vector2(float(t["x"]), float(t["z"]))) > 0.0)


# The teleport points the player has found: those the explored area reaches. Only these show on the maps or can be teleported to.
func known_teleports() -> Array:
	return view.level.get("teleports", []).filter(func(t: Dictionary) -> bool:
		return discovery != null and discovery.shown(Vector2(float(t["x"]), float(t["z"]))) > 0.0)


# Reveals the whole level, every teleport point with it (Settings → Dev → Unlock whole map).
func reveal_all() -> void:
	discovery.stamp(Vector2.ZERO, size_m(), 0.0)
	_fog_dirty = true
	save_discovery()
	queue_redraw()


# The found teleport point (`teleports`: [{x, z, heading?}]) nearest a world spot; INF when none is found yet.
func nearest_teleport(w: Vector2) -> Vector2:
	var best := Vector2.INF
	for t: Dictionary in known_teleports():
		var p := Vector2(float(t["x"]), float(t["z"]))
		if p.distance_squared_to(w) < best.distance_squared_to(w):
			best = p
	return best


# The found teleport point or shop under screen spot `s` (within PICK_PX), the one hovered and picked; INF when none is.
func hovered(s: Vector2) -> Vector2:
	var best := Vector2.INF
	for t: Dictionary in known_teleports() + known_shops():
		var p := Vector2(float(t["x"]), float(t["z"]))
		var d := to_screen(p).distance_to(s)
		if d <= PICK_PX and (best == Vector2.INF or d < to_screen(best).distance_to(s)):
			best = p
	return best


# Screen boxes for the names of the teleports and shops, one per anchor (its marker's screen spot): right of the
# marker, else left, else nudged a line up or down (then further) so names close together stack instead of covering
# each other. A name with no free spot left (one already placed, another marker or the screen's edge in every one) gets
# an empty Rect2 and isn't drawn, so zoomed far out the map thins its names rather than piling them up; `first` (the
# aimed-at teleport, or -1) is placed before the rest so its name always shows. A zero width (no name) is skipped.
static func place_names(anchors: PackedVector2Array, widths: PackedFloat32Array, line_h: float, bounds: Rect2, first: int) -> Array[Rect2]:
	var out: Array[Rect2] = []
	out.resize(anchors.size())
	var taken: Array[Rect2] = []
	for a in anchors:
		taken.append(Rect2(a - Vector2(8, 8), Vector2(16, 16)))
	var order := range(anchors.size())
	if first >= 0 and first < anchors.size():
		order.erase(first)
		order.push_front(first)
	for i: int in order:
		if widths[i] <= 0.0:
			continue
		var step := line_h + NAME_PAD_PX * 2.0 + 2.0
		var spots: Array[Vector2] = []
		for k in [0, -1, 1, -2, 2, -3, 3]:
			var y := roundf(anchors[i].y - line_h / 2.0 + k * step)
			spots.append(Vector2(roundf(anchors[i].x + NAME_GAP_PX), y))
			spots.append(Vector2(roundf(anchors[i].x - NAME_GAP_PX - widths[i]), y))
		for spot in spots:
			var r := Rect2(spot, Vector2(ceilf(widths[i]), line_h))
			var padded := r.grow(NAME_PAD_PX)
			if not bounds.encloses(padded) or taken.any(func(o: Rect2) -> bool: return o.intersects(padded)):
				continue
			out[i] = r
			taken.append(padded)
			break
	return out


# Uploads the painted image and traces the road lines; the level view calls it behind the loading screen, since the upload alone stalls a frame for tens of ms.
func build() -> void:
	if _texture != null or (_painter == null and _painted == null):
		return
	var img: Image = _painter.wait_to_finish() if _painter != null else _painted  # waits only if the painting isn't done yet
	_texture = ImageTexture.create_from_image(img)
	_painter = null
	_painted = null
	var b := view._bake
	var line := PackedVector2Array()
	for i in b.sx.size():
		var paved := b.st[i] >= 0.5
		if i > 0 and b.sc[i] != b.sc[i - 1]:
			_add_line(line, b.st[i - 1] >= 0.5, _width_of(b.sw[i - 1]))
			line = PackedVector2Array()
		elif i > 0 and (paved != (b.st[i - 1] >= 0.5) or _width_of(b.sw[i]) != _width_of(b.sw[i - 1])):
			_add_line(line, b.st[i - 1] >= 0.5, _width_of(b.sw[i - 1]))
			line = PackedVector2Array([line[-1]])  # the next line starts where this one ended, so the road has no gap
		line.append(Vector2(b.sx[i], b.sz[i]))
	if b.sx.size() > 0:
		_add_line(line, b.st[-1] >= 0.5, _width_of(b.sw[-1]))
	for bd: Dictionary in view.level.get("buildings", []):
		_buildings.append(footprint(bd))


# A road's full width from its half-width, in 0.25 m steps so a line only splits where the width visibly changes.
static func _width_of(half_width: float) -> float:
	return snappedf(2.0 * half_width, 0.25)


func _add_line(line: PackedVector2Array, paved: bool, width: float) -> void:
	_chains.append(line)
	_tarmac.append(paved)
	_widths.append(width)


# A save's building ({x, z, rot, L, W}) as its four corners in world x, z.
static func footprint(bd: Dictionary) -> PackedVector2Array:
	var rot := float(bd.get("rot", 0.0))
	var ax := Vector2(cos(rot), -sin(rot)) * float(bd.get("L", 8.0)) / 2.0
	var az := Vector2(sin(rot), cos(rot)) * float(bd.get("W", 6.0)) / 2.0
	var c := Vector2(float(bd["x"]), float(bd["z"]))
	return PackedVector2Array([c + ax + az, c + ax - az, c - ax - az, c - ax + az])


func _paint() -> Image:
	var b := view._bake
	var half := size_m() / 2.0
	var k := IMAGE_PX / size_m()
	var biome := LevelStreamer.decode_biome(view.level, size_m())
	var img := _cover_image(biome)
	_paint_trees(img, b, half, k, biome)
	return img


# The ground, faintly tinted by the save's ground cover (heather, rush, ...) in each type's own colour, with the
# biome mask's snow over it, scaled up to IMAGE_PX (the bilinear resize softens the snow's 10 m cell edges).
func _cover_image(biome := PackedByteArray()) -> Image:
	var cov := GroundCover.decode_cover(view.level)
	var grid := roundi(sqrt(cov.size()))
	var img := Image.create(COVER_PX, COVER_PX, false, Image.FORMAT_RGB8)
	img.fill(GROUND)
	if grid > 0:
		var palette := PackedByteArray()
		var tints := GroundCover.tints(view.level.get("coverKinds", {}))
		for id in 256:
			var c := GROUND.lerp(tints.get(id, GROUND), COVER_TINT)
			palette.append_array([c.r8, c.g8, c.b8])
		var px := img.get_data()
		for y in COVER_PX:
			var row := floori((y + 0.5) * grid / COVER_PX) * grid
			for x in COVER_PX:
				var id := cov[row + floori((x + 0.5) * grid / COVER_PX)] * 3
				var i := (y * COVER_PX + x) * 3
				px[i] = palette[id]
				px[i + 1] = palette[id + 1]
				px[i + 2] = palette[id + 2]
		img.set_data(COVER_PX, COVER_PX, false, Image.FORMAT_RGB8, px)
	_paint_snow(img, biome)
	img.resize(IMAGE_PX, IMAGE_PX, Image.INTERPOLATE_BILINEAR)
	return img


# Paints the save's snow (the biome mask, LevelStreamer.decode_biome) over the cover image in SNOW, one rect per run
# of snow cells along a row (native fills, so the 1024² image costs no per-pixel GDScript loop).
func _paint_snow(img: Image, biome: PackedByteArray) -> void:
	if biome.is_empty():
		return
	var n := ceili(size_m() / LevelStreamer.BIOME_CELL)
	var k := LevelStreamer.BIOME_CELL * COVER_PX / size_m()  # a biome cell's width in cover pixels
	for r in n:
		var y0 := roundi(r * k)
		var y1 := roundi((r + 1) * k)
		var c := 0
		while c < n:
			if biome[r * n + c] != LevelStreamer.BIOME_SNOW:
				c += 1
				continue
			var start := c
			while c < n and biome[r * n + c] == LevelStreamer.BIOME_SNOW:
				c += 1
			var x0 := roundi(start * k)
			img.fill_rect(Rect2i(x0, y0, roundi(c * k) - x0, y1 - y0), SNOW)


# Whether the biome mask (LevelStreamer.decode_biome) has snow at world (x, z); false off the level or with no mask.
func snow_cell(biome: PackedByteArray, x: float, z: float) -> bool:
	if biome.is_empty():
		return false
	var n := ceili(size_m() / LevelStreamer.BIOME_CELL)
	var c := floori((x + size_m() / 2.0) / LevelStreamer.BIOME_CELL)
	var r := floori((z + size_m() / 2.0) / LevelStreamer.BIOME_CELL)
	return c >= 0 and r >= 0 and c < n and r < n and biome[r * n + c] == LevelStreamer.BIOME_SNOW


# Each tree as a disc as wide as its canopy, darker in the middle so neighbouring crowns stay apart; frosted
# (SNOW_TREE) where it stands in the snow, so a snowy forest still reads as snow.
func _paint_trees(img: Image, b: LevelBake, half: float, k: float, biome := PackedByteArray()) -> void:
	var px := img.get_data()
	var green := [_rgb(TREE), _rgb(TREE.darkened(0.3))]
	var frost := [_rgb(SNOW_TREE), _rgb(SNOW_TREE.darkened(0.3))]
	for t in b.tree_count():
		var o := t * 12
		var cx := (b.tree_xf[o + 3] + half) * k
		var cz := (b.tree_xf[o + 11] + half) * k
		var look: Array = frost if snow_cell(biome, b.tree_xf[o + 3], b.tree_xf[o + 11]) else green
		var edge: PackedByteArray = look[0]
		var core: PackedByteArray = look[1]
		var r := maxf(Vector2(b.tree_xf[o], b.tree_xf[o + 8]).length() * 0.5 * k, 0.7)
		var ri := ceili(r)
		for y in range(maxi(int(cz) - ri, 0), mini(int(cz) + ri + 1, IMAGE_PX)):
			for x in range(maxi(int(cx) - ri, 0), mini(int(cx) + ri + 1, IMAGE_PX)):
				var d2 := (x + 0.5 - cx) ** 2 + (y + 0.5 - cz) ** 2
				if d2 <= r * r:
					var c := core if d2 < r * r * 0.25 else edge
					var i := (y * IMAGE_PX + x) * 3
					px[i] = c[0]
					px[i + 1] = c[1]
					px[i + 2] = c[2]
	img.set_data(IMAGE_PX, IMAGE_PX, false, Image.FORMAT_RGB8, px)


static func _rgb(c: Color) -> PackedByteArray:
	return PackedByteArray([c.r8, c.g8, c.b8])


func _draw() -> void:
	var xf := Transform2D(0.0, Vector2(zoom, zoom), 0.0, size / 2.0 - center * zoom)
	draw_rect(Rect2(Vector2.ZERO, size), FOG)
	paint(self, xf, zoom, 1.0, _route)
	var aim := get_local_mouse_position() if _mouse_inside() else size / 2.0
	var target := hovered(aim)
	var teleports := known_teleports()
	var shops := known_shops()
	var names: Array = teleports.map(func(t: Dictionary) -> String: return String(t.get("name", ""))) \
		+ shops.map(func(t: Dictionary) -> String: return String(t.get("name", "")))
	if _start.is_valid():
		for i in teleports.size():
			names[i] = _preview_labels.get(Vector2(float(teleports[i]["x"]), float(teleports[i]["z"])), "")
	var anchors := PackedVector2Array()
	var widths := PackedFloat32Array()
	var first := -1
	var font := UITheme.font()
	for i in teleports.size():
		var t: Dictionary = teleports[i]
		var wp := Vector2(float(t["x"]), float(t["z"]))
		var tp := to_screen(wp)
		draw_diamond(self, tp, 8.0)
		anchors.append(tp)
		widths.append(font.get_string_size(String(names[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SIZE).x)
		if wp == target:
			first = i
	for i in shops.size():
		var wp := Vector2(float(shops[i]["x"]), float(shops[i]["z"]))
		var sp := to_screen(wp)
		draw_shop(self, sp, 7.0)
		anchors.append(sp)
		widths.append(font.get_string_size(String(shops[i].get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SIZE).x)
		if wp == target:
			first = teleports.size() + i
	var line_h := float(UITheme.FONT_SIZE)
	var rects := place_names(anchors, widths, line_h, Rect2(Vector2.ZERO, size), first)
	for i in rects.size():
		if rects[i].size == Vector2.ZERO or String(names[i]).is_empty():
			continue
		draw_rect(rects[i].grow(NAME_PAD_PX), NAME_BACK)
		var base := (rects[i].position + Vector2(0, roundf((line_h + font.get_ascent(UITheme.FONT_SIZE) - font.get_descent(UITheme.FONT_SIZE)) / 2.0))).round()
		draw_string(font, base, String(names[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SIZE,
			TELEPORT if i == first else SHOP.lightened(0.4) if i >= teleports.size() else UITheme.INK)
	paint_car(self, xf, 1.0)
	if target != Vector2.INF:
		draw_arc(to_screen(target), 12.0, 0.0, TAU, 24, UITheme.INK, 2.0)
	if not _mouse_inside():
		draw_line(size / 2.0 - Vector2(10, 0), size / 2.0 + Vector2(10, 0), UITheme.INK, 2.0)
		draw_line(size / 2.0 - Vector2(0, 10), size / 2.0 + Vector2(0, 10), UITheme.INK, 2.0)


# Draws the map's content (ground, roads, buildings, log piles, fog, border, route) on any canvas item through `xf`
# (world metres to that item's pixels, so it can be rotated); the minimap shares it. `ui` scales the fixed-pixel marks.
## `clip` (world metres) skips everything outside it: the minimap shows a few hundred metres of a 5 km map.
func paint(ci: CanvasItem, xf: Transform2D, zm: float, ui: float, route: PackedVector2Array, clip := Rect2()) -> void:
	var half := size_m() / 2.0
	var world := Rect2(Vector2(-half, -half), Vector2.ONE * size_m())
	if not clip.has_area():
		clip = world.grow(half)
	_ensure_boxes()
	ci.draw_set_transform_matrix(xf)
	if _texture != null:  # build() uploads it behind the loading screen; a headless run never does
		ci.draw_texture_rect(_texture, world, false)
	for i in view._bake.patches.size():
		if _boxes["patches"][i].intersects(clip):
			ci.draw_colored_polygon(view._bake.patches[i], PATCH)
	for i in _fence_lines.size():
		if _fence_lines[i].size() > 1 and _boxes["fences"][i].intersects(clip):
			ci.draw_polyline(_fence_lines[i], HEDGE if _fence_hedge[i] else FENCE, 1.5 if _fence_hedge[i] else maxf(0.5, ui / zm))
	for i in _chains.size():
		if _chains[i].size() > 1 and _boxes["chains"][i].intersects(clip):
			ci.draw_polyline(_chains[i], ROAD_EDGE, _widths[i] + 2.0 * ui / zm)
	for i in _chains.size():
		if _chains[i].size() > 1 and _boxes["chains"][i].intersects(clip):
			ci.draw_polyline(_chains[i], TARMAC if _tarmac[i] else ROAD, _widths[i])
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)
	for b in _buildings.size():
		if not _boxes["buildings"][b].intersects(clip):
			continue
		var fp = _buildings[b]
		var pts := PackedVector2Array()
		for corner in fp:
			pts.append(xf * corner)
		ci.draw_colored_polygon(pts, BUILDING)
		pts.append(pts[0])
		ci.draw_polyline(pts, ROAD_EDGE, ui)
	for pile: Dictionary in view.level.get("logPiles", []):
		if not clip.has_point(Vector2(float(pile["x"]), float(pile["z"]))):
			continue
		ci.draw_circle(xf * Vector2(float(pile["x"]), float(pile["z"])), maxf(MIN_MARK_PX * ui, 4.0 * zm) / 2.0, LOG_PILE)
	ci.draw_set_transform_matrix(xf)
	if _fog != null:
		ci.draw_texture_rect(_fog, Rect2(Vector2(-half, -half), Vector2.ONE * discovery.cells * discovery.cell_m), false)
	ci.draw_rect(world, BORDER, false, BORDER_PX * ui / zm)
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)
	if route.size() > 1:
		var pts := PackedVector2Array()
		for q in route:
			pts.append(xf * q)
		ci.draw_polyline(pts, ROUTE, ROUTE_PX * ui, true)


var _boxes := {}  # what paint draws, as world-space bounding boxes, so a clipped paint can skip what's off the picture
var _fence_lines: Array[PackedVector2Array] = []
var _fence_hedge: Array[bool] = []


static func box_of(pts: Variant) -> Rect2:
	var r := Rect2()
	var first := true
	for p: Vector2 in pts:
		if first:
			r = Rect2(p, Vector2.ZERO)
			first = false
		else:
			r = r.expand(p)
	return r.grow(10.0)


func _ensure_boxes() -> void:
	if not _boxes.is_empty() and _boxes["chains"].size() == _chains.size():
		return
	_fence_lines.clear()
	_fence_hedge.clear()
	for f: Dictionary in view.level.get("fences", []):
		var line := PackedVector2Array()
		for p: Array in f.get("pts", []):
			line.append(Vector2(float(p[0]), float(p[1])))
		_fence_lines.append(line)
		_fence_hedge.append(f.get("kind", "fence") == "hedge")
	_boxes = {
		"patches": view._bake.patches.map(box_of),
		"fences": _fence_lines.map(box_of),
		"chains": _chains.map(box_of),
		"buildings": _buildings.map(box_of),
	}


static func draw_diamond(ci: CanvasItem, p: Vector2, r: float) -> void:
	ci.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -r), p + Vector2(r, 0), p + Vector2(0, r), p + Vector2(-r, 0)]), TELEPORT)


# A shop on the map: a purple square, so it reads apart from the teleport diamonds.
static func draw_shop(ci: CanvasItem, p: Vector2, r: float) -> void:
	ci.draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), SHOP)


func paint_teleports(ci: CanvasItem, xf: Transform2D, ui: float) -> void:
	for t: Dictionary in known_teleports():
		draw_diamond(ci, xf * Vector2(float(t["x"]), float(t["z"])), 8.0 * ui)
	for t: Dictionary in known_shops():
		draw_shop(ci, xf * Vector2(float(t["x"]), float(t["z"])), 7.0 * ui)


# The car as a white arrow pointing the way it faces, through `xf`.
func paint_car(ci: CanvasItem, xf: Transform2D, ui: float) -> void:
	var car := view.get_parent().get_node_or_null("Car") as Node3D
	if car == null:
		return
	var p := xf * Vector2(car.global_position.x, car.global_position.z)
	var f := xf.basis_xform(Vector2(-car.global_basis.z.x, -car.global_basis.z.z)).normalized() * 12.0 * ui
	ci.draw_colored_polygon(PackedVector2Array([p + f, p - f * 0.6 + f.orthogonal() * 0.6, p - f * 0.6 - f.orthogonal() * 0.6]), Color.WHITE)


func _mouse_inside() -> bool:
	return Rect2(Vector2.ZERO, size).has_point(get_local_mouse_position()) and Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE and not _pad_used



func zoom_by(f: float, at: Vector2) -> void:
	var w := to_world(at)
	zoom = clampf(zoom * f, fit_zoom() * 0.5, 20.0)
	center = w - (at - size / 2.0) / zoom
	queue_redraw()


# A card page (a point's page, a shop) or a yes / no popup is up over the map: it takes the input, and the map stays put.
func covered() -> bool:
	var page_up: bool = (view.deliveries_page != null and view.deliveries_page.visible) or view._from_service
	return (page_up and not _start.is_valid()) or view.store != null or view.wreck_page != null or (view._pause != null and view._pause.is_open()) or ConfirmPopup.any_open(get_tree()) != null


func _input(event: InputEvent) -> void:
	if covered():
		return
	var toggle_key: bool = (event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_M) \
		or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_BACK)
	if toggle_key:
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not visible:
		return
	if event is InputEventMouseButton and _buttons.get_global_rect().has_point(event.position):
		return  # left for the buttons' own GUI input
	get_viewport().set_input_as_handled()
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_pad_used = true
	elif event is InputEventMouseMotion:
		_pad_used = false
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		touch(event)
	elif event.is_action_pressed("ui_cancel"):
		close()
	elif (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_Y):
		_open_deliveries()
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: zoom_by(1.2, event.position)
			MOUSE_BUTTON_WHEEL_DOWN: zoom_by(1.0 / 1.2, event.position)
			MOUSE_BUTTON_LEFT:
				_drag_from = event.position
				_pinched = _touches.size() >= 2
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if event.position.distance_to(_drag_from) < 6.0 and not _pinched:
			_pick_at(event.position)
	elif event is InputEventPanGesture:  # a Mac trackpad's two-finger scroll
		if _touches.size() < 2:  # a phone's own pinch already zooms through `touch`
			zoom_by(pow(1.1, -event.delta.y), event.position)
	elif event is InputEventMagnifyGesture:
		if _touches.size() < 2:
			zoom_by(event.factor, event.position)
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		if _touches.size() >= 2:
			return  # the first finger's emulated mouse: the pinch pans the map itself

		center -= event.relative / zoom
		queue_redraw()
	elif event is InputEventMouseMotion:
		queue_redraw()
	elif event.is_action_pressed("ui_accept") or event.is_action_pressed("menu_select"):
		if _start.is_valid():
			_end_preview(true)
		else:
			_pick_at(size / 2.0)
	elif (event is InputEventKey and event.pressed and event.keycode in [KEY_EQUAL, KEY_KP_ADD]) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_RIGHT_SHOULDER):
		zoom_by(1.5, size / 2.0)
	elif (event is InputEventKey and event.pressed and event.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_LEFT_SHOULDER):
		zoom_by(1.0 / 1.5, size / 2.0)


# Touch screens: one finger pans through the emulated mouse; two fingers pinch to zoom round their midpoint and pan as it moves.
func touch(event: InputEvent) -> void:
	var before := _pinch()
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
	elif _touches.has(event.index):
		_touches[event.index] = event.position
	if _touches.size() >= 2:
		_pinched = true
	var after := _pinch()
	if event is InputEventScreenDrag and before.size() == 2 and after.size() == 2 and before[1] > 0.0:
		center -= (after[0] - before[0]) / zoom
		zoom_by(after[1] / before[1], after[0])


# The first two fingers' midpoint and spread, or [] with fewer than two down.
func _pinch() -> Array:
	if _touches.size() < 2:
		return []
	var keys := _touches.keys()
	keys.sort()
	var a: Vector2 = _touches[keys[0]]
	var b: Vector2 = _touches[keys[1]]
	return [(a + b) / 2.0, a.distance_to(b)]


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"level_map", Time.get_ticks_usec() - __t)


func _physics_process(delta: float) -> void:
	if visible:
		return
	_reveal_clock += delta
	if _reveal_clock >= REVEAL_TICK_S and not get_tree().paused:
		_reveal_clock = 0.0
		reveal_at_car()


func _timed_process(delta: float) -> void:
	if _painter != null and not _painter.is_alive():
		build()
	if not visible:
		return
	if covered():
		return
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	for key: Key in WASD:
		if Input.is_physical_key_pressed(key):
			dir += WASD[key]
	dir = dir.limit_length()
	if dir != Vector2.ZERO:
		center += dir * PAN_SPEED_PX * delta / zoom
		queue_redraw()


# Shows the map within level_map_reveal_radius_m of the car.
func reveal_at_car() -> void:
	var car := view.get_parent().get_node_or_null("Car") as Node3D
	if car == null or discovery == null:
		return
	var at := Vector2(car.global_position.x, car.global_position.z)
	if at.distance_to(_revealed_at) < discovery.cell_m:
		return
	_revealed_at = at
	var cfg: GameConfig = Config.data
	if discovery.stamp(at, cfg.level_map_reveal_radius_m, cfg.level_map_reveal_feather_m):
		_fog_dirty = true


# Saves the discovery grid if it has grown since the last save; LevelView calls it with the car's pose.
func save_discovery() -> void:
	if discovery != null and discovery.changed:
		discovery.changed = false
		Save.set_setting(SEEN_KEY, discovery.to_save(view._save_path))


func update_fog() -> void:
	if not _fog_dirty or discovery == null:
		return
	_fog_dirty = false
	if _fog == null:
		_fog = CanvasTexture.new()
		_fog.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var img := discovery.fog_image(FOG)
	var tex := _fog.diffuse_texture as ImageTexture
	if tex != null and tex.get_size() == Vector2(img.get_size()):
		tex.update(img)
	else:
		_fog.diffuse_texture = ImageTexture.create_from_image(img)


# Picks what's under screen spot `s`; with Settings → Dev → "Teleport anywhere" on, empty ground teleports straight there.
func _pick_at(s: Vector2) -> void:
	var p := hovered(s)
	if p == Vector2.INF and Config.data.dev_teleport_anywhere and not _start.is_valid() and not covered():
		await teleport(to_world(s))
	else:
		pick(p)


# Teleports straight to the found teleport point at `p`, free; or opens the found shop there, its stock to buy.
func pick(p: Vector2) -> void:
	if _busy or _start.is_valid():
		return
	for t: Dictionary in known_teleports():
		if Vector2(float(t["x"]), float(t["z"])) == p:
			if LevelView.delivery.is_empty():
				teleport(p)
			else:
				var popup := ConfirmPopup.open(view, "Abandon delivery?", "Teleporting drops the cargo you are carrying.", [{"label": "No", "callback": Callable()},
					{"label": "Yes", "callback": teleport.bind(p)}], 1, 0)
				if popup != null:
					popup.process_mode = Node.PROCESS_MODE_ALWAYS
			return
	var shops: Array = view.level.get("shops", [])
	for t: Dictionary in known_shops():
		if Vector2(float(t["x"]), float(t["z"])) == p:
			view.open_store(shops.find(t), true)
			return


func _open_deliveries() -> void:
	if _start.is_valid():
		_end_preview(true)
	elif not _busy and view.deliveries_page == null:
		view.open_deliveries()


# A delivery picked on a clicked point's page teleports the car itself: the map just closes, without `closed`, which would abandon it.
func hide_for_delivery() -> void:
	visible = false
	_over_pause = false


# Puts the car exactly on teleport point `p`, facing its heading, loading the ground there before the game resumes so the car doesn't fall through.
func teleport(p: Vector2) -> void:
	var car := view.get_parent().get_node_or_null("Car") as VehicleBody3D
	if car == null or _busy or p == Vector2.INF:
		return
	_busy = true
	visible = false
	await view.place_car_on(p)
	get_tree().paused = false
	_busy = false
	var over := _over_pause
	_over_pause = false
	closed.emit(true, over)
