extends Node
# Autoload "WebFullscreen": keeps the WEB build in fullscreen landscape.
#
# A mobile browser first loads the game canvas at the page's (often PORTRAIT)
# size, and browsers only allow fullscreen from a user gesture. So whenever the
# viewport is portrait this puts up a full-screen "tap to play" overlay whose tap
# (or ui_accept from keyboard/gamepad — the button grabs focus) requests
# fullscreen; the export's fullscreenchange handler (export_presets.cfg
# head_include) then locks the orientation to landscape.
#
# It lives in an autoload (not a scene) on purpose: it must work EVERYWHERE — the
# title, the garage, AND while driving — and re-appear whenever the page falls
# back to portrait (browser reopened after being closed, fullscreen exited), not
# just at boot. Entirely inert off the web build.

# The overlay sits above every in-game / menu CanvasLayer (the perf overlay is
# 100, the benchmark results 110, HQ station overlays are low single digits).
const OVERLAY_LAYER := 512

var _layer: CanvasLayer
var _last_size := Vector2i.ZERO


func _ready() -> void:
	if not OS.has_feature("web"):
		set_process(false)
		return
	_update()


# Poll the window size and re-evaluate on any change. Polling (rather than only
# window.size_changed) mirrors DisplayStretch: size_changed can be missed on some
# web/embedded configs, and the check is a cheap Vector2i compare.
func _process(_delta: float) -> void:
	var size := DisplayServer.window_get_size()
	if size == _last_size:
		return
	_last_size = size
	_update()


# The orientation predicate, pure so it's unit-testable without a real window. A
# SQUARE viewport counts as landscape (no prompt, no fullscreen re-request) — only a
# strictly taller-than-wide viewport is the "needs rotating" case.
static func is_portrait(size: Vector2i) -> bool:
	return size.y > size.x


# Show the prompt while portrait, hide it once landscape. Suppressed during a
# benchmark run (the dev auto-profiling loop drives the game with no user present;
# the overlay would only block the view / steal focus).
func _update() -> void:
	if Benchmark.active:
		_hide()
		return
	if is_portrait(DisplayServer.window_get_size()):
		_show()
	else:
		_hide()


# Request canvas fullscreen, but only from a portrait viewport — idempotent when
# already landscape (desktop, or an embedder like itch.io that auto-presents
# fullscreen, where re-requesting would flip it back to portrait). Public so a
# host can also trigger it from its own gesture if desired.
func request_fullscreen() -> void:
	if not OS.has_feature("web"):
		return
	if not is_portrait(DisplayServer.window_get_size()):
		return
	# Best-effort console breadcrumb for on-device debugging (chrome://inspect).
	JavaScriptBridge.eval("console.log('[rally] requesting fullscreen from portrait viewport');", true)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _show() -> void:
	if _layer != null:
		return
	var layer := CanvasLayer.new()
	layer.layer = OVERLAY_LAYER
	add_child(layer)
	_layer = layer
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.03, 0.03, 0.05, 1.0)
	layer.add_child(backdrop)
	# A full-rect, textless Button underneath catches a tap ANYWHERE and provides
	# keyboard/gamepad navigability (FOCUS_ALL + grab_focus → ui_accept fires it).
	var btn := Button.new()
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	btn.flat = true
	btn.focus_mode = Control.FOCUS_ALL
	btn.pressed.connect(request_fullscreen)
	layer.add_child(btn)
	# The visible text sits on top as an autowrapping, centred Label so it fits the
	# narrow portrait logical width (the anamorphic stretch shrinks it further); it
	# ignores the mouse so taps fall through to the button beneath.
	var label := Label.new()
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.offset_left = 16
	label.offset_right = -16
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = "TAP TO PLAY\n\nrotate your phone to landscape"
	label.add_theme_font_size_override("font_size", 20)
	layer.add_child(label)
	btn.grab_focus()


func _hide() -> void:
	if _layer == null:
		return
	_layer.queue_free()
	_layer = null
