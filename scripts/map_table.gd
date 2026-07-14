class_name MapTable
extends Node3D
# Procedural model for the HQ rally map table (features/menus.md TABLE station): a
# wooden tabletop on four legs, with a skirt apron under the top edge and low
# stretcher rails tying the legs together. The flat satellite map plane + the rally
# pins are laid on top by hq.gd; this class only builds the furniture.
#
# Built entirely from code so it fits the project's procedural-asset style (cf.
# FinishArch, garage.gd). The wood look is a generated grain texture (no binary
# asset to ship), cached statically and shared across all parts/instances.
#
# Sized to `table_size` (X, height, Z) with its origin at the FLOOR centre, so the
# top surface sits at exactly y = table_size.y — unchanged from the old single-box
# placeholder, which keeps the map plane, the pins and the table camera framing
# aligned. Standalone-renderable: tools/render_map_table.gd builds one in a
# SubViewport and shoots it from several angles for visual iteration.

# --- Geometry params (metres) -------------------------------------------------
@export var table_size := Vector3(4.6, 0.9, 4.6)  # footprint X/Z and total height
@export var top_thickness := 0.16     # tabletop slab thickness
@export var top_overhang := 0.08      # how far the top oversails the legs/apron
@export var apron_height := 0.22      # depth of the skirt rail under the top
@export var apron_inset := 0.30       # how far the apron sits in from the edge
@export var leg_size := 0.22          # square cross-section of each leg
@export var leg_inset := 0.42         # leg centre offset in from the edge
@export var stretcher_size := 0.12    # square section of the low tie rails
@export var stretcher_y := 0.28       # height of the stretcher rails' centre

# --- Wood look ----------------------------------------------------------------
# Two tones so the slab top reads richer than the legs; both tile the same grain.
@export var top_tint := Color(0.46, 0.31, 0.18)
@export var frame_tint := Color(0.36, 0.24, 0.14)

# One shared wood texture for the whole game (deterministic, generated once).
static var _wood_tex: Texture2D


func _ready() -> void:
	build()


# Top surface height (local Y) — where the map plane / pins are laid by the caller.
func top_y() -> float:
	return table_size.y


func build() -> void:
	for c in get_children():
		c.queue_free()

	var hx := table_size.x * 0.5
	var hz := table_size.z * 0.5
	var top := table_size.y
	var tex := _wood_texture()

	# Tabletop slab — its top face sits exactly at y = table_size.y. Grain tiles a
	# little over the broad top so it doesn't read as one stretched smear.
	var top_mat := _wood_mat(tex, top_tint, Vector3(2.0, 2.0, 1.0))
	_box(
		Vector3(0.0, top - top_thickness * 0.5, 0.0),
		Vector3(table_size.x + top_overhang * 2.0, top_thickness, table_size.z + top_overhang * 2.0),
		top_mat)

	# Apron skirt: four rails just under the top, inset from the edge, framing the legs.
	var frame_mat := _wood_mat(tex, frame_tint, Vector3(2.0, 1.0, 1.0))
	var apron_top := top - top_thickness
	var apron_cy := apron_top - apron_height * 0.5
	var ax := hx - apron_inset
	var az := hz - apron_inset
	# Rails along X (front/back), then along Z (sides); the side rails are shortened
	# so the four meet at the corners instead of overlapping.
	_box(Vector3(0.0, apron_cy, az), Vector3(ax * 2.0, apron_height, leg_size), frame_mat)
	_box(Vector3(0.0, apron_cy, -az), Vector3(ax * 2.0, apron_height, leg_size), frame_mat)
	_box(Vector3(ax, apron_cy, 0.0), Vector3(leg_size, apron_height, az * 2.0 - leg_size), frame_mat)
	_box(Vector3(-ax, apron_cy, 0.0), Vector3(leg_size, apron_height, az * 2.0 - leg_size), frame_mat)

	# Four legs from the floor up to the underside of the tabletop slab.
	var leg_h := top - top_thickness
	var lx := hx - leg_inset
	var lz := hz - leg_inset
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(Vector3(sx * lx, leg_h * 0.5, sz * lz),
				Vector3(leg_size, leg_h, leg_size), frame_mat)

	# Low stretcher rails tying opposite legs front-to-back, for a sturdy read.
	for sx in [-1.0, 1.0]:
		_box(Vector3(sx * lx, stretcher_y, 0.0),
			Vector3(stretcher_size, stretcher_size, lz * 2.0), frame_mat)
	# A single centre cross rail along X joining the two stretchers.
	_box(Vector3(0.0, stretcher_y, 0.0),
		Vector3(lx * 2.0, stretcher_size, stretcher_size), frame_mat)


# A box mesh of `size` centred at local `pos`, carrying `mat`.
func _box(pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshUtil.box(size, mat, pos)
	add_child(mi)
	return mi


# A wood material: the shared grain texture, tinted, tiled by `uv`. Lightly glossy
# so the varnished top catches the garage lights.
func _wood_mat(tex: Texture2D, tint: Color, uv: Vector3) -> StandardMaterial3D:
	var m := PS1Material.lit_textured(tex, uv, tint, 0.62)
	m.metallic = 0.0
	m.metallic_specular = 0.35  # slightly duller than the default 0.5 varnish sheen
	return m


# Procedural tileable wood-grain texture: a warm base with darker plank seams, long
# along-grain streaks and a few knots, plus fine noise. Greyscale-ish so the per-part
# `albedo_color` tint sets the actual hue. Generated once and cached for the session.
static func _wood_texture() -> Texture2D:
	if _wood_tex != null:
		return _wood_tex
	var n := 256
	var img := Image.create(n, n, true, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 90125
	var base := Color(0.78, 0.66, 0.52)
	# Plank rows run along V; grain streaks run along U (the long axis of each plank).
	var planks := 4
	var plank_h := float(n) / float(planks)
	for y in range(n):
		# Which plank, and a stable per-plank brightness offset so boards differ.
		var plank := int(float(y) / plank_h)
		var plank_tone := (sin(float(plank) * 12.9898) * 0.5 + 0.5) * 0.16 - 0.08
		# Distance to the nearest plank seam (wraps) → a dark groove.
		var into := fmod(float(y), plank_h)
		var seam := minf(into, plank_h - into)
		var seam_dark := clampf(1.0 - seam / 3.0, 0.0, 1.0) * 0.30
		for x in range(n):
			# Long-grain banding: low-frequency sine along U, jittered per row.
			var grain := sin(float(x) * 0.10 + float(y) * 0.6) * 0.05
			grain += sin(float(x) * 0.031 + float(plank) * 2.0) * 0.05
			var noise := (rng.randf() - 0.5) * 0.06
			var v := 1.0 + plank_tone + grain + noise - seam_dark
			var c := Color(base.r * v, base.g * v, base.b * v, 1.0)
			img.set_pixel(x, y, c)
	# A few elliptical knots with darker rings.
	for _i in range(5):
		var kx := rng.randi_range(0, n - 1)
		var ky := rng.randi_range(0, n - 1)
		var kr := rng.randf_range(5.0, 12.0)
		for dy in range(int(-kr), int(kr) + 1):
			for dx in range(int(-kr), int(kr) + 1):
				var d := sqrt(float(dx * dx) + float(dy * dy))
				if d > kr:
					continue
				var px := (kx + dx + n) % n
				var py := (ky + dy + n) % n
				var ring := absf(sin(d * 1.4)) * (1.0 - d / kr)
				var dark := 1.0 - ring * 0.45
				var src := img.get_pixel(px, py)
				img.set_pixel(px, py, Color(src.r * dark, src.g * dark, src.b * dark, 1.0))
	img.generate_mipmaps()
	_wood_tex = ImageTexture.create_from_image(img)
	return _wood_tex
