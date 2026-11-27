class_name LevelStats
extends CanvasLayer
# Docs: features/debug-tools.md — update in the same change as this file.
# Tests: tests/headless/test_level_stats.gd — extend in the same change.
# The Hafren level's performance readout, cycled with P: a perf page (frame time, draw calls and triangles, and how much of
# that the trees and ground cover account for), then an adaptive graphics page (what the controller is doing and why).

const REFRESH_S := 0.25

var view: LevelView
var _label: Label
var _accum := 0.0
var _tris := {}  # Mesh -> triangles per instance
var _frames := PackedFloat32Array()  # every frame's ms since the last refresh
enum Page { OFF, PERF, ADAPTIVE }
var page := Page.OFF


func _ready() -> void:
	layer = 100
	visible = false
	_label = Label.new()
	_label.position = Vector2(4, 4)
	_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	_label.add_theme_color_override("font_color", UITheme.GREEN)
	_label.add_theme_color_override("font_outline_color", UITheme.BLACK)
	_label.add_theme_constant_override("outline_size", 3)
	add_child(_label)


## P: off → perf → adaptive → off.
func cycle() -> void:
	page = (page + 1) % Page.size() as Page
	visible = page != Page.OFF
	_accum = 0.0
	_frames.clear()


func _process(dt: float) -> void:
	if not visible:
		return
	_accum += dt
	_frames.append(dt * 1000.0)
	if _accum < REFRESH_S:
		return
	_accum = 0.0
	var cam := get_viewport().get_camera_3d()
	if page == Page.ADAPTIVE:
		_label.text = adaptive_text(view.adaptive.controller if view.adaptive != null else null, FrameSampler.budget_ms(),
			OutlineSetting.resolve(), view._streamer.stat_near_misses if view._streamer != null else 0,
			view._streamer.near_build_s * 1000.0 if view._streamer != null else 0.0)
	else:
		_label.text = text(cam.global_position if cam != null else Vector3.ZERO)
	_frames.clear()


func text(cam_pos: Vector3) -> String:
	var lines := PackedStringArray()
	lines.append(frame_line(_frames))
	lines.append("tris %s  draws %d  objects %d" % [_k(info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)),
		info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME), info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)])
	lines.append(threads_line(OS.has_feature("threads"), view._streamer._inflight.size() if view._streamer != null else 0))
	var trees := view.get_node_or_null("Trees")
	if trees != null:
		var t := tally(trees, cam_pos)
		lines.append("trees %d in range (%d packed)  tris %s" % [t.y, (trees as LevelTrees).drawn_count(), _k(t.z)])
	var cover := view.get_node_or_null("Ground/Cover") as GroundCover
	if cover != null:
		var c := tally(cover, cam_pos)
		lines.append("cover %d tiles  %d tufts in range  tris %s" % [cover.tiles.size(), c.y, _k(c.z)])
	return "\n".join(lines)


## The adaptive graphics page: budget and headroom, the last decision, then one row per setting.
static func adaptive_text(c: AdaptiveController, budget_ms: float, outlines: bool, near_misses: int, near_build_ms := 0.0) -> String:
	if c == null:
		return "adaptive graphics: not running"
	var lines := PackedStringArray()
	var now := Time.get_ticks_usec() / 1e6
	var state := "off" if not c.enabled else ("at floor" if c.at_floor else "on")
	lines.append("budget %.1f ms  p90 %.1f  spare %+.1f  [%s]" % [budget_ms, c.p90_ms(), c.headroom_ms(budget_ms), state])
	if c.last_decision != "":
		lines.append("last: %s  %ds ago" % [c.last_decision, int(now - c.last_decision_s)])
	lines.append("terrain fell behind %d times  tile build %d ms  draw %.3f ms  ktri %.3f ms" % [near_misses, near_build_ms, c.ms_per_draw(), c.ms_per_kprim()])
	for k in c.knobs:
		var wait := c.raise_wait_s(k, now)
		lines.append("%s %d/%d  %.2f ms%s  n%d  %s" % [k.name, k.level, k.top(), c.est_cost(k), "*" if k.from_fit else " ",
			k.samples, ("wait %ds" % int(wait)) if wait > 0.0 else "-"])
	if outlines:
		lines.append("outlines on (fixed cost, Display settings)")
	return "\n".join(lines)


static func threads_line(threads: bool, building: int) -> String:
	return "threads on  %d chunks building" % building if threads else "threads off"


# Measured from each frame's own time, not Engine's one-second fps average, so a single slow frame shows up as the worst.
static func frame_line(frames: PackedFloat32Array) -> String:
	if frames.is_empty():
		return "-- fps"
	var total := 0.0
	var worst := 0.0
	for ms in frames:
		total += ms
		worst = maxf(worst, ms)
	var avg := total / frames.size()
	return "%d fps  avg %.1f ms  worst %.1f ms" % [roundi(1000.0 / avg), avg, worst]


static func info(what: RenderingServer.RenderingInfo) -> int:
	return RenderingServer.get_rendering_info(what)


# Over every MultiMesh under `root` the camera is close enough to draw (frustum culling aside): x = MultiMeshes, y = instances, z = triangles.
func tally(root: Node, cam_pos: Vector3) -> Vector3i:
	var out := Vector3i.ZERO
	for n in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := n as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm == null or not mmi.is_visible_in_tree():
			continue
		var centre := mmi.global_transform * mmi.get_aabb().get_center()
		if mmi.visibility_range_end > 0.0 and centre.distance_to(cam_pos) > mmi.visibility_range_end:
			continue
		var count := mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
		out.x += 1
		out.y += count
		out.z += count * _mesh_tris(mm.mesh)
	return out


func _mesh_tris(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	if not _tris.has(mesh):
		var n := 0
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			n += (idx.size() if not idx.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
		_tris[mesh] = n
	return _tris[mesh]


static func _k(n: int) -> String:
	return "%.1fk" % (n / 1000.0) if n >= 10000 else str(n)
