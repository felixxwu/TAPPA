extends SceneTree
# Bake the world's colour grade into the UI palette. Run headless:
#
#     godot --headless --script tools/bake_ui_palette.gd
#
# WHY A BAKE AND NOT A SHADER: the UI lives on CanvasLayers drawn ABOVE the
# post-process container, so ps1_post_process.gdshader never sees it (see
# features/rendering.md → "Colour grade"). Grading it for real would need a
# top layer sampling hint_screen_texture, whose BackBufferCopy costs a
# render-pass break every frame — a fixed cost that doesn't shrink with
# resolution and forces a tile-buffer resolve on mobile GPUs. Since UITheme
# already centralises the whole palette as flat constants, running those
# constants through the same grade maths ONCE, offline, gets the same cohesion
# for zero runtime cost.
#
# This script does not edit anything: it PRINTS the graded literals, which are
# then pasted into scripts/ui_theme.gd's palette (each line keeps its authored
# value in a trailing comment). Re-run it and re-paste if the grade is retuned in
# config/game_config.tres, then re-run tools/build_ui_theme.gd to regenerate
# theme/ui_theme.tres.
#
# The maths below MUST stay in step with shaders/ps1_post_process.gdshader's
# fragment(). The vignette is deliberately omitted — it's a spatial screen effect,
# meaningless on a palette entry. Alpha is preserved untouched.

const LUMA_709 := Vector3(0.2126, 0.7152, 0.0722)

# The authored (ungraded) palette — the design intent, mirrored from UITheme so
# re-running this is idempotent no matter what's currently pasted in there.
const AUTHORED := {
	"BLACK": Color(0.0, 0.0, 0.0, 1.0),
	"PANEL": Color(0.0, 0.0, 0.0, 0.9),
	"PANEL_DIM": Color(0.0, 0.0, 0.0, 0.6),
	"MODAL_DIM": Color(0.0, 0.0, 0.0, 0.96),
	"SURFACE": Color(0.05, 0.06, 0.05, 1.0),
	"SURFACE_HOVER": Color(0.11, 0.14, 0.11, 1.0),
	"INK": Color(0.92, 0.95, 0.90, 1.0),
	"INK_DIM": Color(0.92, 0.95, 0.90, 0.55),
	"GREEN": Color(0.33, 0.86, 0.36, 1.0),
	"GOLD": Color(0.97, 0.80, 0.13, 1.0),
	"RED": Color(0.89, 0.27, 0.22, 1.0),
	"MUTED": Color(0.58, 0.66, 0.54, 0.55),
	"SHADOW": Color(0.0, 0.0, 0.0, 0.95),
}


func _init() -> void:
	# Loaded directly rather than through the Config autoload: a --script
	# SceneTree run has no autoloads.
	var cfg: GameConfig = load("res://config/game_config.tres")
	if cfg == null:
		push_error("could not load config/game_config.tres")
		quit(1)
		return
	print("# Graded with amount=%.3f saturation=%.3f contrast=%.3f" % [
		cfg.grade_amount, cfg.grade_saturation, cfg.grade_contrast])
	print("# shadow_tint=%s highlight_tint=%s" % [cfg.grade_shadow_tint, cfg.grade_highlight_tint])
	for name in AUTHORED:
		var src: Color = AUTHORED[name]
		var out := _grade(src, cfg)
		print("const %s := Color(%.4f, %.4f, %.4f, %.4f)  # authored Color(%.2f, %.2f, %.2f, %.2f)" % [
			name, out.r, out.g, out.b, out.a, src.r, src.g, src.b, src.a])
	quit(0)


# The same pipeline as ps1_post_process.gdshader's fragment(), minus the vignette.
func _grade(src: Color, cfg: GameConfig) -> Color:
	var rgb := Vector3(src.r, src.g, src.b)
	var luma := rgb.dot(LUMA_709)
	var graded := Vector3(luma, luma, luma).lerp(rgb, cfg.grade_saturation)
	graded = (graded - Vector3(0.5, 0.5, 0.5)) * cfg.grade_contrast + Vector3(0.5, 0.5, 0.5)
	var shadow := Vector3(cfg.grade_shadow_tint.r, cfg.grade_shadow_tint.g, cfg.grade_shadow_tint.b)
	var high := Vector3(cfg.grade_highlight_tint.r, cfg.grade_highlight_tint.g, cfg.grade_highlight_tint.b)
	var tint := shadow.lerp(high, smoothstep(0.0, 1.0, luma))
	tint /= maxf(tint.dot(LUMA_709), 1e-3)
	graded *= tint
	graded = rgb.lerp(graded, cfg.grade_amount)
	return Color(clampf(graded.x, 0.0, 1.0), clampf(graded.y, 0.0, 1.0),
		clampf(graded.z, 0.0, 1.0), src.a)
