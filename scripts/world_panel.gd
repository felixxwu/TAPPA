class_name WorldPanel
extends Node3D
# A MENU THAT EXISTS IN THE 3D WORLD. Hosts an ordinary menu Control tree in an
# off-screen SubViewport and shows it on a NON-billboarded Sprite3D, so the panel is
# an object in the scene — welded at a fixed angle to whatever it is parented to,
# read at whatever angle the authored camera pose gives it. See features/world-panel.md.
#
# THE OFF-SQUARE ANGLE IS THE POINT. There is deliberately no billboarding, no
# camera-facing rotation blend, and no runtime re-orientation anywhere in this class.
# Foreshortening is the intended look. A panel has ONE mounting transform (its parent
# marker) and the shot is composed around it.
#
# Relationship to hq.gd::_build_readout_sprite, which does the same SubViewport →
# Sprite3D trick for map-table pin labels: that path is BILLBOARDED and
# `gui_disable_input = true` (a label, not a menu). This one inverts both. The three
# lessons that path already paid for are inherited here and are NOT optional:
#   1. render_target_update_mode follows visibility, and is never UPDATE_ALWAYS while
#      hidden — 32 pin viewports re-compositing invisible UI cost ~1.9 MP/frame once.
#   2. A SubViewport shown on a 3D quad loses resolution twice, so it is composited at
#      SUPERSAMPLE× the logical size rather than 1:1.
#   3. The house theme's hard black drop shadow is invisible on a black panel; hosts
#      that care clear it per-surface (as _build_readout_sprite does).
#
# WHY A `_frame` CONTROL SITS BETWEEN THE VIEWPORT AND THE HOSTED TREE. Every menu in
# this game is laid out against the LOGICAL canvas DisplayStretch owns —
# DESIGN_HEIGHT tall (display/window/size/viewport_height in project.godot), width following
# the device aspect. A
# hosted tree full of PRESET_FULL_RECT anchors and authored margins only lays out the
# way its author intended if it resolves against a frame of that logical size. So the
# frame is exactly LOGICAL_SIZE and is SCALED UP by SUPERSAMPLE to fill the viewport:
# layout stays at the authored logical height, pixels render at SUPERSAMPLE times it. Host a
# tree directly into
# the viewport instead and every margin in it is half the size it should be.
#
# INPUT: A SubViewport DOES NOT RECEIVE WINDOW EVENTS. It has its own input and focus
# context, so nothing inside a panel — not a Button, not MenuNav — sees anything until
# this node pumps events across. That is why `_unhandled_input` forwards EVERYTHING,
# keyboard and gamepad included, and not just the pointer. Pointer events additionally
# need the ray→panel→pixel conversion below; key events are forwarded verbatim.

# The logical canvas a hosted tree is laid out against: 16:9 at DisplayStretch's
# DESIGN_HEIGHT. Read from DisplayStretch rather than hardcoded so the two cannot
# drift — a panel laid out against a different height than the rest of the game's
# menus would silently mis-size every authored margin in the hosted tree.
static func logical_size() -> Vector2:
	var h := DisplayStretch.DESIGN_HEIGHT
	return Vector2(h * 16.0 / 9.0, h)


# Composite at this multiple of the logical size. A panel is a texture on a quad seen at an angle,
# so it loses resolution twice before the player sees it (the same reason the pin labels needed their
# own larger font).
#
# 4 IS DELIBERATE, AND IT DOES NOT MOVE ANYTHING. The menus are the one surface in the game that
# should NOT look low-res: the PS1 aesthetic comes from the world's internal resolution and the
# dither/quantise post pass, which a menu rendered crisply on a quad does not undermine — while text
# on a foreshortened quad is exactly where softness reads as a bug rather than a style.
#
# Why the geometry is untouched by this number:
#   - world size is `vp.size * pixel_size` and `pixel_size = height_m / vp.size.y`, so the two cancel
#     — a panel is `height_m` metres tall at any supersample.
#   - the frame's scale is `SUPERSAMPLE * ui_scale`, so the layout canvas still exactly fills the
#     viewport; layout is authored against `logical_size / ui_scale` regardless.
#   - `pixel_at` works in UV and multiplies by `vp.size`, so hit-testing follows automatically.
# Changing it only changes how many pixels the same panel is drawn with.
#
# THE COST is real and quadratic: at 4 the render target is (logical * 4)^2 — about 2844x1600, ~4.5 MP
# per panel. Affordable because ONE panel is visible at a time and a hidden panel's target is
# UPDATE_DISABLED (see _apply_visibility), so the bill is one panel's worth, not six. If this ever
# hurts on a phone, this is the first knob to turn back down — it is a look/perf tunable, and no test
# pins it.
const SUPERSAMPLE := 4

# Panel height in metres. The width follows from the 16:9 logical aspect, so the panel
# can never be authored to a shape its hosted tree wasn't laid out for. A look tunable.
#
# KEPT AS A SCRIPT CONST, not read from GameConfig, because it is only ever used as this
# constructor's DEFAULT PARAMETER VALUE — and GDScript default-argument values must be
# compile-time constants, so they cannot call `Config.data` at all. Every shipped station
# calls `WorldPanel.new(height_m, ui_scale)` with its own explicit values (its own
# world_panel_*_height / *_ui_scale pair), so this default only fires for a bare
# `WorldPanel.new()` — test seams and WorldPanelHost's no-spec fallback. THAT fallback is
# the one place a designer can actually retune this number: see
# GameConfig.world_panel_fallback_height / world_panel_fallback_ui_scale and
# WorldPanelHost._spec_now, which read the config field rather than these consts.
const DEFAULT_HEIGHT_M := 2.2

# HOW BIG THE UI READS ON THE PANEL — the lever for "I can see it but it's way too small",
# and the one that making the panel physically bigger does NOT fix.
#
# A hosted tree is laid out against a frame of `logical_size() / ui_scale`, then scaled to
# fill the panel. So ui_scale = 2 lays the menu out on a canvas half as wide and half as
# tall, and every widget on it ends up twice the size on the panel. Moving or enlarging
# the panel changes how big the whole thing is on screen; this changes how big the UI is
# RELATIVE TO THE PANEL, which is the actual complaint when a full-frame layout is hosted
# on one object.
#
# THE TRADE-OFF, and it is real: a smaller canvas fits less. Autowrapped labels wrap to
# more lines and long content can overflow, so a screen pushed too far here needs its
# content trimmed or scrolled rather than just scaled. That is the "content pressure" the
# design doc flagged as the cost of hosting trees verbatim.
#
# THERE IS DELIBERATELY NO AUTO-FIT. An earlier version measured the hosted tree's minimum size and
# grew the canvas back until it fitted, so ui_scale could never clip. It was removed because it could
# not be made to converge: a minimum is NOT independent of the canvas it is measured in — autowrapped
# text changes height with width, and FILL-flagged children report bigger minimums in a bigger box —
# so each refit could enlarge the canvas, which enlarged the minimum, which enlarged the canvas. It
# hung two headless runs outright and would have hung the game. It also made this value feel broken:
# raising it did nothing, because the clamp cancelled it exactly.
#
# So the canvas is EXACTLY logical_size / ui_scale, always. Too high a value clips — which is
# visible, obviously wrong, and one edit away from fixed. That is a much better failure than an
# unbounded resize loop.
const DEFAULT_UI_SCALE := 1.6

var _vp: SubViewport
var _sprite: Sprite3D
var _frame: Control
var _hosted: Control

# A pointer press that STARTED on this panel keeps receiving motion even once it
# leaves the panel's bounds, and keeps it until release. Without this a slider drag
# dies the moment the cursor slips off the quad — which, on a foreshortened panel, is
# a much smaller region of the screen than the player thinks it is.
var _dragging := false



# Test seam ONLY: a Callable returning the Camera3D to project rays from. Production
# leaves this unset and reads the active camera off the viewport. Headless tests need
# to aim a camera at a panel without standing up a whole HQ.
var _camera_override: Callable


func _init(height_m := DEFAULT_HEIGHT_M, ui_scale := DEFAULT_UI_SCALE) -> void:
	var logical := logical_size()
	# Guarded: a zero or negative scale would collapse the frame to nothing and leave a
	# blank panel with no obvious cause.
	var ui := maxf(0.1, ui_scale)

	_vp = SubViewport.new()
	_vp.size = Vector2i(logical * float(SUPERSAMPLE))
	_vp.transparent_bg = true
	# THE FLAG THIS CLASS EXISTS TO INVERT (see the header): a menu needs GUI input.
	_vp.gui_disable_input = false
	# Starts disabled and is armed by visibility alone — see _apply_visibility. Never
	# left compositing a panel nobody is looking at.
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

	# The frame the hosted tree resolves against: `ui_scale` times SMALLER than the
	# logical canvas, then scaled back up by that much on top of the supersample so it
	# still exactly fills the viewport. Net effect — the menu is laid out on a smaller
	# canvas and therefore reads bigger on the panel, at no cost in rendered resolution.
	_frame = Control.new()
	_frame.name = "Frame"
	_frame.size = logical / ui
	_frame.scale = Vector2.ONE * (float(SUPERSAMPLE) * ui)
	# PASS, not STOP: the frame itself must not swallow a press that belongs to a
	# button under it, but it must not be IGNORE either or a hosted tree that called
	# hq.gd::_passthrough_overlay (every diegetic station overlay does) would have
	# nothing left to hit-test against.
	_frame.mouse_filter = Control.MOUSE_FILTER_PASS
	_vp.add_child(_frame)

	_sprite = Sprite3D.new()
	_sprite.name = "Surface"
	_sprite.texture = _vp.get_texture()
	# THE DELIBERATE DIFFERENCE from _build_readout_sprite. Do not "fix" this.
	_sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_sprite.shaded = false
	_sprite.pixel_size = height_m / float(_vp.size.y)
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	# Post-processing is NOT special-cased: the panel is inside the 3D scene, so the
	# grade, fog and tonemap reach it exactly as they reach the car next to it. That
	# cohesion is the whole point of putting menus in the world. The standing risk is
	# that the grade was tuned against terrain and car paint, not against UI text, so
	# a grade retune can quietly hurt panel legibility — something to eyeball when the
	# grade changes, not something to engineer around here.
	_sprite.add_child(_vp)
	add_child(_sprite)

	visibility_changed.connect(_apply_visibility)


# Re-evaluated every frame while the panel is visible, so a panel stays welded to a MOVING
# anchor. Set by WorldPanelHost; unset panels simply keep whatever transform they were given.
#
# WHY PER-FRAME AND NOT JUST ON SYNC. Several station cameras keep moving after the menu opens:
# the map table PANS to the pin you picked, the car-park lineup streams its cars in one per frame
# (moving the anchor the title camera is posed around), and the car-park selection walks down the
# row. The camera re-derives its pose every frame; a panel placed once does not, so it slides out
# of the shot it was framed for. One transform write per frame for the single visible panel is
# nothing next to re-introducing that class of bug per station.
var anchor: Callable


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		place()


# Re-weld the panel to its anchor NOW. The one place a panel's transform is written — _process calls
# it every frame while visible, and a host calls it directly for the same-frame placement a freshly
# shown panel needs (waiting a frame shows the panel at its previous spot first).
func place() -> void:
	if not anchor.is_valid():
		return
	var xf: Variant = anchor.call()
	if xf != null:
		global_transform = xf as Transform3D


func _ready() -> void:
	_apply_visibility()


# Put an existing menu tree on this panel. The tree keeps being built exactly as it is
# built for a CanvasLayer — same widgets, same anchors, same MenuNav.attach call — and
# only its container changes. Reparents if the control already has a parent, so a host
# can move one tree between a CanvasLayer and a panel to A/B the two.
func host(control: Control) -> void:
	if not is_instance_valid(control):
		return
	if control.get_parent() != null:
		control.get_parent().remove_child(control)
	_hosted = control
	_frame.add_child(control)



# The tree this panel is holding RIGHT NOW, or null.
#
# SELF-CORRECTING, because the tree can be taken back without the panel being told:
# WorldPanelHost.release_tree re-parents it to the flat layer directly (it must — freeing a
# panel that still held the tree would free the menu with it). A stored `_hosted` therefore
# went stale on every revert to the flat host, and any caller asking "is this screen on its
# panel?" got YES for a screen sitting on its CanvasLayer — which is exactly how a forced
# re-style painted the panel's opaque label boxes onto the flat menu. Answer from the scene
# tree instead, and let the stale reference go.
func hosted() -> Control:
	if _hosted != null and is_instance_valid(_hosted) and _hosted.get_parent() == _frame:
		return _hosted
	_hosted = null
	return null


func viewport() -> SubViewport:
	return _vp


func surface() -> Sprite3D:
	return _sprite


# The logical-size frame a hosted tree is laid out against (see the header on why it exists).
# Exposed so callers/tests can ask about the layout canvas without depending on a node path.
func frame() -> Control:
	return _frame


# THE CANVAS `node` IS ACTUALLY LAID OUT AGAINST, whichever host is holding it.
#
# Ask this instead of `get_viewport().get_visible_rect().size` whenever the answer is used to
# FIT something (a body scroll's height cap, a column's width). Inside a panel the viewport is
# the SubViewport, whose size is `logical * SUPERSAMPLE` — several times the `_frame` the tree
# is really laid out in (see the `_frame` header) — so a cap measured off it is far too
# generous and the content overflows the panel it is on. Outside a panel this is just the
# viewport rect, so callers need no host special-casing at all.
#
# `fallback` is returned only when the node is in no tree/viewport (a bare unit test).
static func layout_frame_size(node: Node, fallback := Vector2(480, 360)) -> Vector2:
	if not is_instance_valid(node):
		return fallback
	var n: Node = node
	while n != null:
		var panel := n as WorldPanel
		if panel != null:
			var f := panel.frame()
			if f != null:
				return f.size
		n = n.get_parent()
	if node.is_inside_tree():
		var vp := node.get_viewport()
		if vp != null:
			return vp.get_visible_rect().size
	return fallback


# Panel size in METRES, derived from the sprite's own pixel_size and viewport size rather than stored
# separately — so the hit-test region can never disagree with the quad the player is looking at.
func world_size() -> Vector2:
	return Vector2(_vp.size) * _sprite.pixel_size


# Arm the render target only while the panel can actually be seen. THE SINGLE PLACE update mode
# changes, so it cannot drift from visibility.
#
# UPDATE_ALWAYS rather than a one-shot UPDATE_ONCE while shown, for the same reason
# _paint_pin_readout takes it: a Control finishes its deferred container sort a frame after it is
# shown, so a single render taken too early bakes a blank or mis-sized panel and never corrects it.
func _apply_visibility() -> void:
	var shown := is_visible_in_tree()
	_vp.render_target_update_mode = (SubViewport.UPDATE_ALWAYS if shown
		else SubViewport.UPDATE_DISABLED)
	# A hidden panel has nothing to re-weld, so stop ticking it at all rather than early-returning
	# from _process every frame.
	set_process(shown)


func _camera() -> Camera3D:
	if _camera_override.is_valid():
		return _camera_override.call() as Camera3D
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null


# WHERE ON THE PANEL DOES THIS SCREEN POSITION LAND? Returns the hit in VIEWPORT
# PIXELS, or a null Variant when the ray misses the panel's bounds (or hits its back).
#
# Analytic plane intersection, deliberately NOT an Area3D + physics raycast. Three
# reasons, in order of how much they matter:
#   1. It adds NOTHING to the physics world. The map-table station already raycasts
#      for pin picking, and a panel collider parked in front of those pins would
#      intercept their picks — a conflict that simply does not arise if no collider
#      exists.
#   2. It is exact, and independent of the physics frame. A physics query needs a
#      settled physics step before it answers, which makes both the first frame a
#      panel appears and every headless test awkward.
#   3. Foreshortening concentrates mapping error at the far edge of the panel, so the
#      conversion wants to be exactly right rather than approximately right.
# The trade-off accepted: no occlusion test, so a press aimed through geometry that
# stands in front of a panel still reaches the panel. Panels sit at authored camera
# poses with a clear line of sight, so this has no live case; it would need revisiting
# for a panel that can be walked behind.
#
# `bounded` false drops the "is it ON the panel" test and returns the position anyway,
# extrapolated across the panel's infinite plane. That is what a HELD DRAG uses: a slider
# dragged past the end of its track must keep receiving positions (the Range then clamps
# to its own max, which is the behaviour a player expects), and on a foreshortened panel
# the cursor leaves the quad far sooner than it looks like it should. Bounded is the right
# default for everything else — an unbounded press would let a click anywhere on the
# panel's plane, including metres off to the side, land on a button.
func pixel_at(screen_pos: Vector2, bounded := true) -> Variant:
	var cam := _camera()
	if cam == null or not is_visible_in_tree():
		return null

	var xf := _sprite.global_transform
	# Sprite3D lies in its local XY plane facing +Z.
	var plane := Plane(xf.basis.z.normalized(), xf.origin)
	var hit_v: Variant = plane.intersects_ray(cam.project_ray_origin(screen_pos),
		cam.project_ray_normal(screen_pos))
	if hit_v == null:
		return null

	var local: Vector3 = xf.affine_inverse() * (hit_v as Vector3)
	var size_m := world_size()
	if size_m.x <= 0.0 or size_m.y <= 0.0:
		return null
	# Local XY (metres, origin at the panel's centre) → UV (origin top-left). Y flips:
	# 3D up is +Y, GUI down is +Y.
	var uv := Vector2(local.x / size_m.x + 0.5, 0.5 - local.y / size_m.y)
	if bounded and (uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0):
		return null
	return uv * Vector2(_vp.size)


func _panel_input_live() -> bool:
	return is_visible_in_tree() and _hosted != null


# THE PUMP IS SPLIT ACROSS TWO INPUT STAGES ON PURPOSE. It is not tidier to merge them.
#
# POINTER GOES IN `_input` (early). A host station's own tap handling — hq.gd's
# _unhandled_input, which picks cars out of the car park lineup — runs BEFORE its
# descendants, so a panel that forwarded presses at the _unhandled_input stage would
# watch HQ act on a tap that was aimed at a button on the panel. Claiming the press
# early and marking it handled is what stops one tap doing two things.
#
# EVERYTHING ELSE GOES IN `_unhandled_input` (late). Keys must NOT be claimed early:
# native ui_* focus movement and any focused Control's own key handling happen in the
# GUI phase between the two stages, and a panel that swallowed keys before that would
# break the flat menus layered above it.
func _input(event: InputEvent) -> void:
	if not _panel_input_live():
		return
	# A modal owns the screen while it is up (ConfirmPopup lives on a CanvasLayer above
	# everything). Claiming pointer input at the _input stage would otherwise pre-empt
	# the popup's own buttons, which is exactly the class of bug the shared predicate
	# exists to stop hosts re-inventing.
	if MenuNav.input_blocked(self):
		return
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		_forward_pointer(event)


func _unhandled_input(event: InputEvent) -> void:
	# Inert while hidden, for the same reason MenuNav is: a hidden panel that kept
	# pumping would steal menu_* / ui_cancel from whatever is actually on screen.
	if not _panel_input_live():
		return
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		return  # already handled at the _input stage above
	# Keys, gamepad, everything else: verbatim, no ray involved. THIS is what makes
	# MenuNav and ui_accept work inside a panel at all.
	_push(event)


# Pointer → panel-local synthetic event. Touch is not handled separately because
# Godot's `input_devices/pointing/emulate_mouse_from_touch` defaults to on, so taps
# and drags arrive here already as mouse button / motion events.
func _forward_pointer(event: InputEvent) -> void:
	var screen_pos: Vector2 = (event as InputEventMouse).position
	# While a press is held, positions are extrapolated across the panel's plane rather
	# than dropped at its edge — see pixel_at's `bounded`. Explicitly Variant because
	# pixel_at returns null on a miss and an inferred `:=` is an error here.
	var pixel_v: Variant = pixel_at(screen_pos, not _dragging)
	if pixel_v == null:
		# Nothing on this panel: leave the event for whatever is behind it. A press that
		# missed, or idle motion off the quad.
		return
	var pos := pixel_v as Vector2

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			# The grab starts on press and ends on release, which is what lets the two
			# lines above keep feeding a slider once the cursor slips off the quad.
			_dragging = mb.pressed
		var out := mb.duplicate() as InputEventMouseButton
		out.position = pos
		out.global_position = pos
		_push(out)
		return

	var mm := (event as InputEventMouseMotion).duplicate() as InputEventMouseMotion
	mm.position = pos
	mm.global_position = pos
	_push(mm)


# --- Hosting an existing flat menu on a panel ---------------------------------------
#
# THE TWO THINGS A FLAT TREE NEEDS DOING TO IT before it reads correctly on a panel. Both
# live here rather than in each host station, because neither is about any particular
# screen — they are about BEING ON A PANEL, and a second copy in a second station is how
# one of them ends up left behind in the wrong host. Both are fully REVERSIBLE: world-space
# menus are off by default and the flat screens are the shipped look, so nothing here may
# leak into the flat host.

# Marks a PanelContainer built by text_backing(), so apply_host_style can find the wrappers
# it owns without restyling every PanelContainer a screen happens to contain.
const BACKING_META := "world_panel_backing"
# Stashes a tree's flat metrics on the tree itself the first time it is adopted, so they can
# be restored exactly rather than re-derived from a constant that might drift from whatever
# the screen actually authored.
const FLAT_METRICS_META := "world_panel_flat_metrics"
# Which host the tree is currently styled for, so a repeat pass can be skipped entirely.
const APPLIED_META := "world_panel_styled_for_world"
# Opt-in: a Control marked with this is CENTRED vertically while hosted on a panel, and put back
# where it was authored when it returns to its flat layer.
#
# WHY IT IS NEEDED. Several screens anchor their content to the BOTTOM of the frame, which is right
# flat — a row of buttons sitting over the 3D station behind it — but wrong on a panel, where the
# panel IS the menu and there is nothing behind it to leave room for. On the lift that showed up as
# the content JUMPING BANDS between pages: the hub column sat low while MenuPage centred the
# Upgrades/Tuning body, so switching pages moved the menu.
const CENTER_META := "world_panel_center"
const FLAT_ANCHORS_META := "world_panel_flat_anchors"
# Opt-in: a Control marked with this is LEFT-ALIGNED while hosted on a panel, and restored to its
# authored alignment when flat. MenuPage centres its panel horizontally (SHRINK_CENTER), which is
# right for a modal over a screen but means a page whose content width changes lands somewhere
# different each time — so the lift's hub rows and its Upgrades/Tuning page did not share a left edge.
const ALIGN_BEGIN_META := "world_panel_align_begin"
const FLAT_ALIGN_META := "world_panel_flat_align"

# A panel's canvas is SHORT (logical_size / ui_scale), so the screen-authored margins and
# row gaps don't fit once anything wraps to a second line — the bottom action row gets
# pushed clean off the panel. Look tunables; no test pins them.
const PANEL_SEPARATION := 4
const PANEL_MARGIN := 8.0
const BACKING_PAD := 4


# Wrap a bare label so it CAN be given an opaque box when hosted on a panel, and hand back
# the wrapper to add in the label's place.
#
# WHY A WRAPPER: a Label has no background of its own, and the house look for "text on an
# opaque box" is UITheme.panel_box on a PanelContainer — the same thing _build_readout_sprite
# does for the map-table readouts. A Button already carries its own surface and needs none
# of this; a bare label over a sunlit car park is simply unreadable.
#
# FILL, not SHRINK_CENTER, and the caller should autowrap the label: on a narrow panel canvas
# a shrink-to-content box lets a long line grow PAST the panel edge, where it is cut off
# mid-word rather than wrapping. Filling gives the label a real width to wrap within; labels
# stay visually centred via their own horizontal_alignment.
#
# VISIBILITY IS MIRRORED from the child, because call sites hide/show the LABEL by name.
# Without mirroring, a hidden label leaves its wrapper drawing a small empty black blob
# where the text used to be.
static func text_backing(ctrl: Control) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_FILL
	pc.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	pc.set_meta(BACKING_META, true)
	pc.add_child(ctrl)
	pc.visible = ctrl.visible
	ctrl.visibility_changed.connect(func() -> void:
		if is_instance_valid(pc):
			pc.visible = ctrl.visible)
	return pc


# Restyle a hosted tree for the panel (`world` true) or back for its flat layer (false).
# Idempotent per node, and safe on a tree with no backings at all.
#
# `force` RE-WALKS A TREE THAT IS ALREADY ON THE HOST IT ASKS FOR. The cheap early-out below
# keys off the ROOT, so it also skipped nodes added to the tree AFTER it was adopted: content
# rebuilt while hosted (hq.gd rebuilds the garage row on a Mystery Box repaint without going
# through _go_to) kept the flat StyleBoxEmpty on any new backing — a bare label over a sunlit
# car park — and never got centred or left-aligned. Every pass below is idempotent per node
# (backings just re-set their box; _apply_centering / _apply_left_align stash each node's
# authored values on ITS OWN first adopt), so re-walking is safe; it is skipped by default
# only because it is a whole-tree walk on every view change. hq.gd::_normalize_menus passes
# force, which is what makes "rebuilt content gets the house rules" true on both hosts.
static func apply_host_style(root: Control, world: bool, force := false) -> void:
	if not is_instance_valid(root):
		return
	# NOTHING TO DO WHEN THE HOST HASN'T CHANGED. This runs on every sync, which runs on every view
	# change — and each pass below walks the whole tree. In the shipped flat path every walk is a
	# guaranteed no-op after the first restore, so the common case was three full tree walks per
	# screen per view change to change nothing.
	if not force and root.has_meta(APPLIED_META) \
			and bool(root.get_meta(APPLIED_META)) == world:
		return
	root.set_meta(APPLIED_META, world)
	for n in root.find_children("*", "PanelContainer", true, false):
		var pc := n as PanelContainer
		if not pc.has_meta(BACKING_META):
			continue
		# Typed as the common base and assigned in a branch rather than a ternary: a
		# StyleBoxFlat/StyleBoxEmpty ternary is an INCOMPATIBLE_TERNARY warning, which this
		# project's strict-error tests treat as a failure.
		var box: StyleBox = null
		if world:
			box = UITheme.panel_box(1.0, BACKING_PAD)
		else:
			box = StyleBoxEmpty.new()
		pc.add_theme_stylebox_override("panel", box)
	_apply_centering(root, world)
	_apply_left_align(root, world)
	if world:
		# Recorded on first adopt, from whatever the screen actually authored.
		if not root.has_meta(FLAT_METRICS_META):
			# RECORD WHETHER AN OVERRIDE EXISTED, not just the resolved value. get_theme_constant()
			# happily answers from the THEME when the node has no override of its own, so restoring by
			# always calling add_theme_constant_override() would bake a hard override into a tree that
			# never had one — a permanent change to the flat menu, which is the one thing this must
			# never do.
			root.set_meta(FLAT_METRICS_META, {
				"had_separation": root.has_theme_constant_override("separation"),
				"separation": root.get_theme_constant("separation"),
				"offsets": Vector4(root.offset_left, root.offset_top,
					root.offset_right, root.offset_bottom),
			})
		root.add_theme_constant_override("separation", PANEL_SEPARATION)
		_set_offsets(root, Vector4(PANEL_MARGIN, PANEL_MARGIN, -PANEL_MARGIN, -PANEL_MARGIN))
		return
	if not root.has_meta(FLAT_METRICS_META):
		return  # never adopted, so nothing to put back
	var flat: Dictionary = root.get_meta(FLAT_METRICS_META)
	if bool(flat.get("had_separation", true)):
		root.add_theme_constant_override("separation", int(flat.get("separation", 0)))
	else:
		root.remove_theme_constant_override("separation")
	_set_offsets(root, flat.get("offsets", Vector4.ZERO) as Vector4)


# Centre (or restore) every opted-in Control under `root`. Anchors and offsets are stashed on the node
# itself on first adopt, so each screen gets ITS OWN authored values back rather than a shared guess.
static func _apply_centering(root: Control, world: bool) -> void:
	var marked: Array = root.find_children("*", "Control", true, false)
	if root.has_meta(CENTER_META):
		marked.append(root)
	for n in marked:
		var c := n as Control
		if not c.has_meta(CENTER_META):
			continue
		var box := c as BoxContainer
		if world:
			if not c.has_meta(FLAT_ANCHORS_META):
				c.set_meta(FLAT_ANCHORS_META, {
					"anchors": Vector4(c.anchor_left, c.anchor_top, c.anchor_right, c.anchor_bottom),
					"offsets": Vector4(c.offset_left, c.offset_top, c.offset_right, c.offset_bottom),
					"grow_v": c.grow_vertical,
					"alignment": (box.alignment if box != null else 0),
				})
			# FULL-RECT + the container's OWN centre alignment, not an anchor preset.
			#
			# The first attempt used PRESET_VCENTER_WIDE with keep_offsets = true, which kept offsets
			# authored for a BOTTOM-anchored box (left 20 / right -20 / bottom -20) against completely
			# different anchors — the column came out mis-sized and shoved off the right edge, worse
			# than the bottom-anchoring it replaced. Filling the frame and letting the BoxContainer
			# centre its own children is the honest way to say "centre this".
			# The PANEL's margins on all four sides, not the screen's authored horizontal ones — so a
			# centred column and a left-aligned page share one left edge rather than sitting 20 vs 12
			# px in from it. The authored values are still what the flat host gets back, from the meta.
			c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT,
				Control.PRESET_MODE_KEEP_SIZE, int(PANEL_MARGIN))
			c.grow_vertical = Control.GROW_DIRECTION_BOTH
			if box != null:
				box.alignment = BoxContainer.ALIGNMENT_CENTER
			continue
		if not c.has_meta(FLAT_ANCHORS_META):
			continue
		var flat: Dictionary = c.get_meta(FLAT_ANCHORS_META)
		var a: Vector4 = flat.get("anchors", Vector4.ZERO)
		c.anchor_left = a.x
		c.anchor_top = a.y
		c.anchor_right = a.z
		c.anchor_bottom = a.w
		_set_offsets(c, flat.get("offsets", Vector4.ZERO) as Vector4)
		c.grow_vertical = int(flat.get("grow_v", Control.GROW_DIRECTION_BOTH)) as Control.GrowDirection
		if box != null:
			box.alignment = int(flat.get("alignment", BoxContainer.ALIGNMENT_BEGIN)) as BoxContainer.AlignmentMode


# Left-align (or restore) every opted-in Control under `root`, so a panel's content shares ONE left
# edge no matter which page is showing.
static func _apply_left_align(root: Control, world: bool) -> void:
	var marked: Array = root.find_children("*", "Control", true, false)
	if root.has_meta(ALIGN_BEGIN_META):
		marked.append(root)
	for n in marked:
		var c := n as Control
		if not c.has_meta(ALIGN_BEGIN_META):
			continue
		var box := c as BoxContainer
		if world:
			if not c.has_meta(FLAT_ALIGN_META):
				c.set_meta(FLAT_ALIGN_META, {
					"flags": c.size_flags_horizontal,
					"alignment": (box.alignment if box != null else 0),
				})
			c.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			if box != null:
				box.alignment = BoxContainer.ALIGNMENT_BEGIN
			continue
		if not c.has_meta(FLAT_ALIGN_META):
			continue
		var flat: Dictionary = c.get_meta(FLAT_ALIGN_META)
		c.size_flags_horizontal = int(flat.get("flags", Control.SIZE_FILL))
		if box != null:
			box.alignment = int(flat.get("alignment", BoxContainer.ALIGNMENT_BEGIN)) as BoxContainer.AlignmentMode


static func _set_offsets(root: Control, o: Vector4) -> void:
	root.offset_left = o.x
	root.offset_top = o.y
	root.offset_right = o.z
	root.offset_bottom = o.w


# Push into the SubViewport, then mirror its verdict back to the main viewport: if
# something inside the panel consumed the event, the world behind the panel must not
# also act on it (the HQ station handlers all run off the same actions).
func _push(event: InputEvent) -> void:
	_vp.push_input(event, true)
	if _vp.is_input_handled():
		var vp := get_viewport()
		if vp != null:
			vp.set_input_as_handled()
