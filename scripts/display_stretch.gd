extends Node
# Autoload "DisplayStretch": applies a purely stylistic horizontal stretch to the
# ENTIRE rendered frame — the 3D world AND every CanvasLayer of UI on top of it,
# in every scene. The look is a slight anamorphic widening: everything appears
# STRETCH_X times wider than it really is, with no vertical change.
#
# How it works. The project renders with stretch mode "viewport" and (by default)
# aspect "keep_height": the logical frame is DESIGN_HEIGHT tall, the logical width
# grows with the window so wider devices simply see MORE of the world, and the
# whole thing is scaled to the window with square (undistorted) pixels.
#
# We keep that "taller-locked, width-follows-device" behaviour but switch the
# aspect to IGNORE and drive content_scale_size ourselves, so the horizontal and
# vertical scale-to-window factors differ by exactly STRETCH_X:
#
#   logical height = DESIGN_HEIGHT                  -> vertical scale = window.y / DESIGN_HEIGHT
#   logical width  = DESIGN_HEIGHT * aspect / X     -> horizontal scale = X * window.y / DESIGN_HEIGHT
#
# Because the factor is recomputed from DESIGN_HEIGHT / stretch (never from the
# raw window width), the stretch stays a constant factor on any device aspect,
# and wider screens still reveal more world width — just that-many-times fatter.
# Doing it through the stretch system (rather than a post-process shader) is what
# lets it reach the UI too: the post-process pass only sees the 3D viewport, while
# the HUD/menus live on higher CanvasLayers drawn after it.
#
# The factor itself is the authored look value Config.data.horizontal_stretch
# (config/game_config.tres); 1.0 makes this a no-op.

# Logical frame height the game is laid out against (project.godot
# window/size/viewport_height, locked by the original "keep_height" aspect).
const DESIGN_HEIGHT := 400.0


var _last_window_size := Vector2i.ZERO


func _ready() -> void:
	var window := get_window()
	# Per-axis scaling: let horizontal and vertical fit the window independently.
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	window.size_changed.connect(_apply)
	# Apply once now AND again deferred: at _ready the window may still report its
	# pre-maximize override size, and the OS resize that maximizes/snaps it can land
	# before our signal is connected, leaving a stale logical frame that just gets
	# stretched to fill (width stops following the window). The deferred pass re-reads
	# the settled size; _notification keeps us correct on every later resize even if a
	# given size_changed is missed (e.g. some embedded-window cases).
	_apply()
	_apply.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_apply()


# Poll every frame so live-drag resizing updates the viewport continuously
# rather than waiting for size_changed (which may only fire on drag-complete
# on some platforms/configurations).
func _process(_delta: float) -> void:
	var size := get_window().size
	if size != _last_window_size:
		_last_window_size = size
		_apply()


func _apply() -> void:
	var window := get_window()
	var size := window.size
	if size.x <= 0 or size.y <= 0:
		return
	# During a benchmark, render at a LANDSCAPE logical size even if the window is
	# portrait (phone held upright / rotation locked). The 3D pass then does the
	# representative landscape pixel count — otherwise a portrait window renders at
	# ~1/4 the resolution and the benchmark under-measures GPU/fill cost. Visually
	# squished into the portrait window, but the auto-driven run has no viewer.
	var effective := benchmark_window_size(size, Benchmark.active)
	window.content_scale_size = logical_size(effective, Config.data.horizontal_stretch)


# The window size to lay the frame out against. Normally the real window; during
# a benchmark it's forced landscape (wider than tall) so a portrait phone still
# renders the representative landscape resolution. Pure + static for testing.
static func benchmark_window_size(size: Vector2i, benchmark_active: bool) -> Vector2i:
	if benchmark_active and size.y > size.x:
		return Vector2i(size.y, size.x)  # swap portrait -> landscape
	return size


# The logical (pre-stretch) frame size for a given window size and stretch factor.
# Height stays DESIGN_HEIGHT (vertical untouched); width is shrunk by `stretch` so
# the window has to scale it back out by that factor — a pure horizontal widening.
# Pure + static so it's unit-testable without a real Window.
static func logical_size(window_size: Vector2i, stretch: float) -> Vector2i:
	var factor := maxf(stretch, 0.01)
	if window_size.y <= 0:
		return Vector2i(int(DESIGN_HEIGHT), int(DESIGN_HEIGHT))
	var width := int(round(DESIGN_HEIGHT * float(window_size.x) / float(window_size.y) / factor))
	return Vector2i(maxi(width, 1), int(DESIGN_HEIGHT))
