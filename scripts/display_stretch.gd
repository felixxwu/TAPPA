extends Node
# Docs: features/rendering.md — update in the same change as this file.
# Tests: tests/headless/test_display_stretch.gd, tests/headless/test_render_smoke.gd — extend in the same change.
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

# Logical frame height the game is laid out against. Comes straight from
# project.godot (window/size/viewport_height), the same on every target — native
# mobile, desktop, and web (including web-touch) all render at the authored value.
# Because everything (3D world AND every UI CanvasLayer) is laid out against this,
# it is the one true fragment lever — the frame is rendered at this height and
# scaled up to the window.
# (Static var rather than const because const can't call into ProjectSettings.)
static var DESIGN_HEIGHT: float = base_design_height()


# The authored logical height from project.godot.
static func base_design_height() -> float:
	# Default must match display/window/size/viewport_height in project.godot.
	return float(ProjectSettings.get_setting("display/window/size/viewport_height", 400))


var _last_window_size := Vector2i.ZERO
# Benchmark state as last applied (active, render_height): the benchmark flips
# these without a window resize, so _process re-applies when they change — this
# is what makes the portrait->landscape swap and the resolution-sweep height take
# effect at Benchmark.start() rather than waiting for the next resize.
var _last_bench_state := [false, 0]


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
	var bench_state := [Benchmark.active, Benchmark.render_height]
	if size != _last_window_size or bench_state != _last_bench_state:
		_last_window_size = size
		_last_bench_state = bench_state
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
	# Resolution sweep: while a benchmark is active, an explicit render_height from
	# the sweep config replaces DESIGN_HEIGHT so runs can measure fill/GPU cost at
	# several resolutions (features/benchmark.md -> "Resolution sweep").
	var height := DESIGN_HEIGHT
	if Benchmark.active and Benchmark.render_height > 0:
		height = float(Benchmark.render_height)
	window.content_scale_size = logical_size(effective, Config.data.horizontal_stretch, height)


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
# `design_height` defaults to the authored height; the benchmark resolution sweep
# passes an override so a run can render at a different (e.g. native) resolution.
static func logical_size(window_size: Vector2i, stretch: float, design_height: float = DESIGN_HEIGHT) -> Vector2i:
	var factor := maxf(stretch, 0.01)
	var h := maxf(design_height, 1.0)
	if window_size.y <= 0:
		return Vector2i(int(h), int(h))
	var width := int(round(h * float(window_size.x) / float(window_size.y) / factor))
	return Vector2i(maxi(width, 1), int(h))
