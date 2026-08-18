class_name WorldPanelHost
extends RefCounted
# Docs: features/world-panel.md — update in the same change as this file.
# Tests: tests/headless/test_menu_flow.gd, tests/headless/test_world_panel.gd — extend in the same change.
# ONE STATION'S WORLD-SPACE MENU, and the swap between its two hosts. See
# features/world-panel.md.
#
# A station that can show its menu in the world has the same four moving parts every time:
# a flat CanvasLayer, the menu tree itself, a WorldPanel, and an anchor transform to weld
# the panel to. This class owns that machinery so a station only supplies the four and calls
# sync() — the alternative is the same ~40 lines of host-swapping, spec-tracking and
# restyling copied per screen, where the copies quietly diverge in the direction of "reverts
# cleanly to the flat host", which is the half nobody re-checks because the flat look is the
# default.
#
# THE TREE IS MOVED, NEVER REBUILT. That is what makes the A/B honest (the two hosts show the
# same widgets with the same wiring) and it is why the panel must never be freed while it
# still holds the tree — doing so takes the whole menu with it. release_tree() exists for
# exactly that ordering.

var flat_layer: CanvasLayer      # the station's ordinary overlay layer
var tree: Control                # the menu tree, owned by whichever host holds it
var panel: WorldPanel            # built lazily on first world sync; freed on retune
var parent: Node                 # where the panel is added in the 3D scene
# Returns the panel's world Transform3D, or null when the station can't place it yet (no
# lineup built, no car on the lift). Re-evaluated on every place() so a panel welded to a
# moving selection follows it.
var anchor: Callable
# Returns Vector2(height_m, ui_scale). Read on every sync so a retune in the inspector
# rebuilds the panel instead of appearing to do nothing until a restart — both values are
# baked in at construction.
var spec: Callable

var _built_spec := Vector2.ZERO


func _init(opts: Dictionary = {}) -> void:
	flat_layer = opts.get("flat_layer", null)
	tree = opts.get("tree", null)
	parent = opts.get("parent", null)
	anchor = opts.get("anchor", Callable())
	spec = opts.get("spec", Callable())


# Put the menu on the host `world` asks for, and show it only when `shown`. Idempotent and
# cheap when nothing has changed, so it is safe to call from a per-view-change refresh.
func sync(world: bool, shown: bool) -> void:
	if tree == null:
		return
	var want := _spec_now()
	# Rebuild on a retune of either baked-in value. The tree goes back to the flat layer
	# FIRST — freeing a panel that still holds it would free the menu too.
	if panel != null and not _built_spec.is_equal_approx(want):
		release_tree()
		panel.queue_free()
		panel = null
	# `shown`, not just `world`: _update_overlays syncs EVERY migrated screen on every view change, so
	# building on `world` alone allocated a render target per station and kept them all for the session.
	# UPDATE_DISABLED stops a hidden panel RENDERING but not its target being allocated, and at the
	# current supersample that is megabytes each. Exactly one panel is ever visible, so build on show.
	if world and shown and panel == null and parent != null:
		panel = WorldPanel.new(want.x, want.y)
		panel.name = "WorldPanel"
		# The panel follows its anchor every frame from here on (see WorldPanel._process); place()
		# stays for the immediate, same-frame placement a freshly shown panel needs.
		panel.anchor = anchor
		_built_spec = want
		parent.add_child(panel)

	WorldPanel.apply_host_style(tree, world)

	if world and panel != null:
		if panel.hosted() != tree:
			panel.host(tree)
		_stand_down_flat()
		panel.visible = shown
		place()
	elif world:
		# World mode, but this screen isn't showing and has no panel yet — leave both hosts down.
		_stand_down_flat()
	else:
		release_tree()
		if flat_layer != null:
			flat_layer.visible = shown
		if panel != null:
			panel.visible = false


# IS THE TREE ON THE PANEL RIGHT NOW? The one authoritative answer to "which host is live",
# so callers stop deriving it from parent identity (`tree.get_parent() != flat_layer`) — a
# spelling of the question that quietly changes meaning the moment a tree is parked anywhere
# else, and which was already duplicated in hq.gd::_normalize_menus.
func is_world() -> bool:
	return panel != null and panel.hosted() == tree


# Stand the flat layer down — and SAY SO when something else is riding on it.
#
# This is the exact line that made the car park's Change-Upgrades modal invisible: UI parented
# to a station's CanvasLayer renders nowhere once the tree migrates, and nothing failed, warned
# or looked wrong in code review. The modal was built, gated, nav-wired and on nobody's screen.
#
# So the moment the invalid state comes into existence, name it. Debug builds only (same gating
# as the F7/F8 panel keys) — it costs nothing shipped, and it prints while the developer is
# looking at the blank screen, which is the difference between "Change Upgrades does nothing"
# and a named node in the log. UI that legitimately belongs to the flat layer and accepts going
# with it sets ALLOW_HIDDEN_META — nothing does today (the build watermark, which used to be the
# one accepted stray, now has its own layer), so the warning firing means a real mistake.
const ALLOW_HIDDEN_META := "world_panel_ok_hidden"


func _stand_down_flat() -> void:
	if flat_layer == null:
		return
	flat_layer.visible = false
	if not OS.is_debug_build():
		return
	for child in flat_layer.get_children():
		if child == tree or child.has_meta(ALLOW_HIDDEN_META) or not (child is CanvasItem):
			continue
		push_warning(("WorldPanelHost: '%s' is parented to the hidden flat layer '%s' and will "
			+ "render nowhere. Give it its own CanvasLayer (MenuPage.open_modal / ConfirmPopup), "
			+ "or set ALLOW_HIDDEN_META if it is meant to go down with the layer.")
			% [child.name, flat_layer.name])


# Hand the tree back to its flat layer. Safe to call when it is already there.
func release_tree() -> void:
	if tree == null or flat_layer == null or tree.get_parent() == flat_layer:
		return
	if tree.get_parent() != null:
		tree.get_parent().remove_child(tree)
	flat_layer.add_child(tree)


# Re-weld the panel to its anchor. Called on every sync, and by the station whenever its
# selection changes (a panel welded to the focused car has to travel with it).
func place() -> void:
	if panel != null:
		panel.place()


func _spec_now() -> Vector2:
	if not spec.is_valid():
		# Every shipped station supplies its own `spec`, so this only fires for a host built
		# with none at all (a test seam). Reads GameConfig.world_panel_fallback_height /
		# world_panel_fallback_ui_scale rather than WorldPanel's own DEFAULT_HEIGHT_M /
		# DEFAULT_UI_SCALE consts — those exist only because GDScript default-argument values
		# must be compile-time constants (see WorldPanel's header comment on them) and so
		# can't be retuned from config; this IS the retunable path.
		var cfg: GameConfig = Config.data
		return Vector2(cfg.world_panel_fallback_height, cfg.world_panel_fallback_ui_scale)
	return spec.call() as Vector2
