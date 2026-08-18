class_name OverworldMarker
extends Node3D
# The floating, slowly rotating sign above one overworld zone — the life-size version of the
# map table's pin marker (docs/superpowers/specs/2026-08-17-overworld-hq-design.md, slice 2,
# "Zone markers"). Its job is to say, from a distance and with no text, WHAT KIND of rally is
# parked here:
#
#   ordinary rally  -> a flag        (RallyFlag.build, as hq._make_pin already uses)
#   car unlock      -> the car       (a CarProp of RallyLibrary.prize_car_id, as the table's
#                                     _attach_prize_car_marker builds, plus a full-size
#                                     rotating ghost of it standing on the ground)
#   part unlock     -> THE PART'S OWN ICON (UpgradeIcons.texture of the unlocked upgrade's
#                                     slot) — a deliberate divergence from the table, which
#                                     stands a generic trophy for parts
#   capability      -> THE CAPABILITY'S ICON (engine swapping is the only one — the engine
#                                     glyph). Same card treatment as a part, because to the
#                                     player it is the same kind of promise: something the
#                                     GARAGE gains. Without it a capability rally fell through
#                                     to the generic trophy and the map could not say what the
#                                     one rally that unlocks the garage's best mechanic gives.
#   special         -> a trophy      (RallyTrophy.build) — the fallback for a special whose
#                                     prize has no picture, NOT a prize in itself
#
# ICONS FACE THE PLAYER. They used to rotate slowly and continuously; that was superseded —
# stars and icons are information, and information you have to wait for the far side of is worse
# than information that looks at you. The 2D part card and the star layer billboard in their
# MATERIAL (free, no CPU); the 3D tokens (flag, trophy) are yawed by the manager, which holds the
# active camera. The parked GHOST CARS still turn: a showroom turntable carries no information.
#
# The marker owns its visuals and NOTHING else: it does not face or spin itself
# (`overworld_zones.gd` drives every marker's yaw from one place — 38 zones must not mean 38
# `_process` callbacks)
# and it does not decide whether it should exist (the manager's draw-distance and ghost-car
# budget do that). It is built to be POOLED: `configure` re-dresses an existing marker for a
# different rally, and the expensive car body is handed in by the manager's cache rather than
# spawned here.

enum Kind {FLAG, CAR, PART, CAPABILITY, TROPHY}

# Marker proportions, in metres. Shape constants, not balance: how big the sign is so it is
# legible at the draw distance. The FLOAT HEIGHT is the authored tunable
# (`overworld_marker_height_m`), and `overworld_marker_spin_deg_s` is now the GHOST CAR's
# turntable rate — the icons face the player instead of turning (see `face_camera`).
const ICON_SIZE_M := 4.0
# RallyFlag / RallyTrophy are authored at map-token scale (RallyFlag.POLE_HEIGHT is 0.30 m),
# so a life-size marker scales them up to ICON_SIZE_M rather than re-authoring the art.
const TOKEN_HEIGHT_M := 0.30

# --- The STAR LAYER ---------------------------------------------------------------------
# A second layer above the icon showing how many of a rally's stars the player holds. All
# SHAPE constants, like the two above — not balance. The one thing that IS authored lives in
# GameConfig already (`overworld_marker_height_m`), and this layer is derived FROM it rather
# than adding an unrelated height of its own, so retuning the float height moves both.
const STAR_HEIGHT_M := 1.1          # world height of one star in the row
const STAR_LAYER_GAP_M := 0.9       # clear air between the top of the icon and the row
# Rasterisation radius for one star, in px. Only the texture's resolution — the world size is
# STAR_HEIGHT_M. Matches StarRow's own default `star_radius` so the drawn star has the same
# proportions as every medal row in the UI.
const STAR_PX := 11.0
# Gap between stars in the composed row, as a fraction of a star's width.
const STAR_GAP_FRACTION := 0.28

var rally: Dictionary = {}
var rally_id := ""
var kind := Kind.FLAG

# The single node everything spins with. Kept separate from `self` so the manager can spin the
# marker without touching its float height or position.
var _spinner: Node3D = null
# The ghost body's spinner (a car-unlock zone only). Separate from the icon's so the ghost can
# be granted and revoked by the budget without rebuilding the icon.
var _ghost_spinner: Node3D = null
var _icon: Node3D = null
# The star row: ONE billboarded quad, built once and re-textured on every `configure`. Not
# rebuilt per rally, because a marker is POOLED and re-dressed — and because the row is always
# the full `RallyLibrary.MAX_STARS_PER_RALLY` wide (earned filled, the rest empty), so its size
# never changes and there is nothing to re-measure.
var _stars: MeshInstance3D = null
var _stars_mat: StandardMaterial3D = null
# What the row currently shows, for the headless tests: filled count and slot count.
var _stars_shown := 0
var _stars_total := 0

# ONE composed row texture per (earned, total) pair for the whole game — at most
# MAX_STARS_PER_RALLY + 1 of them. Static because every marker showing "1 of 3" wants the same
# bytes, and markers are re-dressed constantly.
static var _row_textures: Dictionary = {}


func _init() -> void:
	_spinner = Node3D.new()
	_spinner.name = "IconSpinner"
	add_child(_spinner)
	_ghost_spinner = Node3D.new()
	_ghost_spinner.name = "GhostSpinner"
	add_child(_ghost_spinner)


# Dress this marker for `p_rally`. Safe to call on a marker pulled out of the pool: the old
# icon is freed and the ghost released back to the caller-owned cache first.
#
# `locked` / `stars` / `has_eligible_car` are passed straight through to RallyFlag.build /
# RallyTrophy.build so the marker wears the same state colours the table's pins do.
func configure(p_rally: Dictionary, locked: bool, stars: int, has_eligible_car: bool) -> void:
	rally = p_rally
	rally_id = String(p_rally.get("id", ""))
	kind = kind_of(p_rally)
	release_ghost()
	if _icon != null:
		_icon.queue_free()
		_icon = null
	_icon = _build_icon(kind, locked, stars, has_eligible_car)
	if _icon != null:
		_spinner.add_child(_icon)
	_apply_stars(stars, locked)
	apply_height()


# Which of the four markers this rally wears. Static and pure, so a test can assert the
# trichotomy (a prize-car rally reads CAR, a part-unlock rally reads PART, ...) with no scene.
#
# Order matters: a car prize wins over everything (it is the most specific promise), then a
# recognisable part, then a CAPABILITY, then a special's trophy, then the ordinary flag. The
# trophy sits BELOW all three prizes on purpose — it is what a special falls back to when its
# prize has no picture, never something a rally earns by being flagged special.
static func kind_of(p_rally: Dictionary) -> Kind:
	if RallyLibrary.prize_car_id(p_rally) != "":
		return Kind.CAR
	if part_slot_of(p_rally) != "":
		return Kind.PART
	if capability_slot_of(p_rally) != "":
		return Kind.CAPABILITY
	if RallyLibrary.is_special(p_rally):
		return Kind.TROPHY
	return Kind.FLAG


# The upgrade SLOT whose icon this rally should wear, or "" if it unlocks nothing.
#
# UpgradeIcons.texture is keyed by SLOT, while the catalogue records the gate the other way
# round (`UpgradeLibrary.unlocked_by_rally` maps upgrade -> rally), so the lookup is the
# reverse walk — which the catalogue already exposes as `UpgradeLibrary.unlocked_by(rally_id)`
# (and `RallyLibrary.prize_part_id` on top of it). Reused rather than re-walked here so this
# marker can never disagree with the pin, the podium line or the reveal banner about what a
# rally unlocks.
#
# Returning "" (rather than letting UpgradeIcons hand back its _FALLBACK) is the load-bearing
# bit: an unmapped rally must fall back to the FLAG. UpgradeIcons' fallback is the TUNE
# wrench, so leaning on it would make every rally that unlocks nothing read as a tuning
# event — the one wrong answer, since that is most of the roster.
static func part_slot_of(p_rally: Dictionary) -> String:
	var item := UpgradeLibrary.unlocked_by(String(p_rally.get("id", "")))
	if item.is_empty():
		return ""
	return String(item.get("slot", ""))


# The upgrade-icon SLOT a CAPABILITY-awarding rally wears, or "" — the view-layer half of
# `RallyLibrary.prize_capability_id`, which answers WHAT is awarded without knowing what it looks
# like (RallyLibrary must not reach UpgradeOptions: the two would become mutually dependent).
#
# Engine swapping wears the ENGINE glyph, which the icon set already ships for the upgrades grid's
# engine tile — so this needs no new art, and the map, the grid and the swap row all show the
# player the same picture for the same mechanic.
static func capability_slot_of(p_rally: Dictionary) -> String:
	match RallyLibrary.prize_capability_id(p_rally):
		RallyLibrary.CAPABILITY_ENGINE_SWAP:
			return UpgradeOptions.SLOT_ENGINE
		_:
			return ""


# The 2D icon a CAPABILITY marker draws, or null when the rally awards none. Unlike
# `part_texture` this can never hit UpgradeIcons' wrench fallback, because the slot it resolves is
# one this file names itself rather than one the catalogue authored.
static func capability_texture(p_rally: Dictionary) -> Texture2D:
	var slot := capability_slot_of(p_rally)
	if slot == "":
		return null
	return UpgradeIcons.texture(slot)


# The 2D icon a PART marker draws, or null if there is none — see part_slot_of. A slot the
# icon set has no art for still resolves (UpgradeIcons._FALLBACK), because a newly authored
# part must show SOMETHING; only "unlocks nothing" returns null.
static func part_texture(p_rally: Dictionary) -> Texture2D:
	var slot := part_slot_of(p_rally)
	if slot == "":
		return null
	return UpgradeIcons.texture(slot)


# Float the marker at the live `overworld_marker_height_m`. Read from Config every call rather
# than captured at build time, so a retune is visible without rebuilding the markers.
func apply_height() -> void:
	var h: float = Config.data.overworld_marker_height_m
	_spinner.position = Vector3(0.0, h, 0.0)
	if _stars != null:
		# A SECOND LAYER, stacked above the icon rather than beside it, so a zone reads as one
		# sign with a score over it instead of two markers competing. Derived from the same
		# authored float height plus the icon's own size, so both move together on a retune.
		_stars.position = Vector3(0.0,
			h + ICON_SIZE_M + STAR_LAYER_GAP_M + STAR_HEIGHT_M * 0.5, 0.0)


# Turn the ICON to face the camera. `yaw` is computed per marker by the manager (which holds
# the active camera) rather than here — the "no marker has a `_process`" rule is deliberate, and
# 38 markers must not mean 38 callbacks.
#
# YAW ONLY, deliberately. The icons are 3D tokens (a flag on a pole, a trophy), so tilting them
# toward a camera looking down from a rise would read as wonky rather than as facing the player;
# turning about Y keeps them standing up. Same axis the star layer's material billboard uses, so
# the two layers always agree.
func face_camera(yaw: float) -> void:
	_spinner.rotation.y = yaw


# Advance the GHOST CAR's rotation. Still the manager's ONE shared angle: a parked prize car
# turning on the spot is a showroom turntable, which is what the player asked for, and unlike an
# icon it carries no information to read — so it keeps spinning while the icons face front.
#
# Only written when a ghost is actually held: this used to write `rotation.y` on every marker in
# the set whether or not it had a body to turn.
func apply_spin(yaw: float) -> void:
	if _ghost_spinner.get_child_count() > 0:
		_ghost_spinner.rotation.y = yaw


# --- The star layer --------------------------------------------------------------------


## How many stars the row is currently showing as EARNED, and how many SLOTS it has. The
## headless seam: a test asserts the row agrees with what `configure` was handed without
## pinning a star count or the denominator (both are balance values).
func stars_shown() -> int:
	return _stars_shown


func star_slots() -> int:
	return _stars_total


## Is the star layer on screen? False for a rally the player has not revealed.
func stars_visible() -> bool:
	return _stars != null and _stars.visible


# Re-dress the row. `earned` is clamped into 0..MAX_STARS_PER_RALLY, so a marker configured with
# a nonsense count can never draw more stars than a rally has to give.
#
# HIDDEN FOR AN UNREVEALED RALLY (`locked` — the manager passes `not zone.revealed()`, the same
# predicate that gates the pins, the light tube, the roadblocks and the map's roads). Stars on a
# rally the player has not found would leak exactly what the fog exists to withhold: that there
# is content there and how far through it they are. Note the gate is REVEAL, not eligibility — a
# revealed rally you own no car for still shows its stars, because that is a garage problem, not
# a progression one.
func _apply_stars(earned: int, locked: bool) -> void:
	var total: int = maxi(RallyLibrary.MAX_STARS_PER_RALLY, 0)
	_stars_total = total
	_stars_shown = clampi(earned, 0, total)
	if _stars == null:
		_build_star_layer()
	if _stars == null:
		return
	_stars.visible = not locked and total > 0
	if not _stars.visible:
		return
	var tex := star_row_texture(_stars_shown, total)
	_stars_mat.albedo_texture = tex
	# The row is always `total` slots wide, so this only ever runs the once in practice — but a
	# retune of MAX_STARS_PER_RALLY must not leave a stretched quad behind.
	var aspect := 1.0
	if tex != null and tex.get_height() > 0:
		aspect = float(tex.get_width()) / float(tex.get_height())
	(_stars.mesh as QuadMesh).size = Vector2(STAR_HEIGHT_M * aspect, STAR_HEIGHT_M)


# One quad, BILLBOARDED BY THE MATERIAL — no `_process`, no per-frame CPU, and correct at any
# camera angle. `BILLBOARD_FIXED_Y` (yaw only) rather than full billboarding: a row of stars that
# tips toward a camera looking down from a hill reads as wonky, and yaw-only keeps it level and
# legible. `billboard_keep_scale` because the quad is sized in metres and must not be rescaled by
# the billboard basis.
func _build_star_layer() -> void:
	_stars_mat = StandardMaterial3D.new()
	_stars_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_stars_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_stars_mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	_stars_mat.billboard_keep_scale = true
	_stars_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_stars_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var quad := QuadMesh.new()
	quad.size = Vector2(STAR_HEIGHT_M, STAR_HEIGHT_M)
	_stars = MeshInstance3D.new()
	_stars.name = "StarRow"
	_stars.mesh = quad
	_stars.material_override = _stars_mat
	_stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# NOT under `_spinner`: the icon is turned by the manager and the row must not inherit that
	# rotation on top of its own billboard.
	add_child(_stars)


## The composed row image for `earned` of `total`, cached for the session.
##
## Built by BLENDING StarRow's own star texture — `StarRow.texture` rasterises the shared
## `_star_points` geometry, which is exactly why that geometry is static: an icon star, a medal-row
## star and this world-space star cannot drift apart. Nothing here authors a second star shape.
##
## FILL vs FILL, not fill vs outline: at 16 px on the horizon an outline disappears, so an earned
## star is bright gold and an empty one is a dark, OPAQUE olive — a value contrast that survives
## the distance. (`UITheme.MUTED` ships at 55% alpha for panel use, which washes out entirely
## against sky; StarRow already has `unearned_color` for exactly this class of surface.)
static func star_row_texture(earned: int, total: int) -> Texture2D:
	var key := "%d/%d" % [earned, total]
	if _row_textures.has(key):
		return _row_textures[key]
	if total <= 0:
		return null
	var filled := StarRow.texture(STAR_PX, UITheme.GOLD).get_image()
	var empty := StarRow.texture(STAR_PX, star_empty_color()).get_image()
	var w := filled.get_width()
	var h := filled.get_height()
	var gap: int = maxi(1, roundi(float(w) * STAR_GAP_FRACTION))
	var img := Image.create(total * w + maxi(total - 1, 0) * gap, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for i in total:
		var src := filled if i < earned else empty
		img.blend_rect(src, Rect2i(0, 0, w, h), Vector2i(i * (w + gap), 0))
	var tex := ImageTexture.create_from_image(img)
	_row_textures[key] = tex
	return tex


## The empty-slot colour: the palette's MUTED olive, darkened and made OPAQUE. Exposed so the
## texture builder and any test can name the same colour without a second literal.
static func star_empty_color() -> Color:
	return Color(UITheme.MUTED.r * 0.45, UITheme.MUTED.g * 0.45, UITheme.MUTED.b * 0.45, 1.0)


# --- Ghost car -------------------------------------------------------------------------
#
# The BODY is not built here. Car props are expensive enough that the HQ caches them
# (`hq._prize_car_props`), so the manager owns one cache keyed by model id and re-parents the
# body onto whichever marker currently holds a ghost budget slot. This marker only parents it
# under the spinner and hands it back.


# Adopt a cached ghost body. `body` must already be a frozen, translucent CarProp (built by
# the manager) — this only re-parents it.
#
# The body's OWN local transform is left alone. It is not decoration: the manager seats the
# body at `settled_ride_height()` above its parent's origin (car.tscn's body origin is well
# above the wheel contact plane), and the marker's origin is the zone's ground point — so
# resetting to Transform3D.IDENTITY here buried the car up to its arches. The facing is
# re-applied per zone by the manager after adoption, since one cached body is shared by every
# zone that unlocks that model.
func adopt_ghost(body: Node3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	release_ghost()
	if body.get_parent() != null:
		body.get_parent().remove_child(body)
	_ghost_spinner.add_child(body)


# Detach the ghost body WITHOUT freeing it — it belongs to the manager's cache, and freeing it
# here is exactly the bug `hq._detach_prize_car_props` exists to avoid (a queue_free'd pin
# taking the cached prop down with it).
func release_ghost() -> Node3D:
	for child in _ghost_spinner.get_children():
		var node := child as Node3D
		_ghost_spinner.remove_child(child)
		return node
	return null


func has_ghost() -> bool:
	return _ghost_spinner.get_child_count() > 0


# --- Icon construction -------------------------------------------------------------------


func _build_icon(p_kind: Kind, locked: bool, stars: int, has_eligible_car: bool) -> Node3D:
	match p_kind:
		Kind.CAPABILITY:
			var cap_tex := capability_texture(rally)
			if cap_tex != null:
				return _icon_quad(cap_tex, locked)
			# Unreachable via kind_of (CAPABILITY implies a slot, and every slot resolves to at
			# least the wrench), but a marker configured directly must stand something.
			return _scaled_token(RallyTrophy.build(locked, stars, has_eligible_car))
		Kind.PART:
			var tex := part_texture(rally)
			if tex != null:
				return _icon_quad(tex, locked)
			# Unreachable via kind_of (PART implies a slot), but a marker configured directly
			# must still stand something rather than nothing.
			return _scaled_token(RallyFlag.build(locked, stars, has_eligible_car))
		Kind.TROPHY:
			return _scaled_token(RallyTrophy.build(locked, stars, has_eligible_car))
		Kind.CAR:
			# The car IS the icon, and it is the ghost body on the ground — no floating sign,
			# so the zone does not read as two competing markers. A car with no resolvable
			# model (a synthetic roster) falls through to the flag, as hq._make_pin does.
			if CarLibrary.index_of(RallyLibrary.prize_car_id(rally)) >= 0:
				return null
			return _scaled_token(RallyFlag.build(locked, stars, has_eligible_car))
		_:
			return _scaled_token(RallyFlag.build(locked, stars, has_eligible_car))


# Blow a map-token-scale mesh marker up to life size and sit it on the spinner's origin.
func _scaled_token(token: Node3D) -> Node3D:
	var s := ICON_SIZE_M / TOKEN_HEIGHT_M
	token.scale = Vector3(s, s, s)
	return token


# A part icon is a 2D texture, so it renders as a DOUBLE-SIDED UNSHADED QUAD rotating about Y
# — it reads as a slowly spinning card. It goes edge-on and near-vanishes twice per turn;
# per the spec that is accepted (the flag and trophy are meshes and have no such problem).
# The alternatives if it looks wrong in motion are a billboard spinning in-plane, or giving
# the quad thickness.
#
# The icons are white monochrome strokes meant to be tinted by the caller (see
# upgrade_icons.gd), so the tint carries the locked state the flag encodes in its pennant.
func _icon_quad(tex: Texture2D, locked: bool) -> Node3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(ICON_SIZE_M, ICON_SIZE_M)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED       # double-sided: readable from behind
	# BILLBOARDED, yaw only — the same treatment the star layer gets, and it also retires this
	# card's documented wart: as a spinning quad it went edge-on and near-vanished twice per turn.
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = tex
	mat.albedo_color = UITheme.MUTED if locked else UITheme.INK
	# Nearest filtering, matching the rest of the game's PS1 look.
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var mi := MeshInstance3D.new()
	mi.name = "PartIcon"
	mi.mesh = quad
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Centre the card on the spinner so it turns about its own middle, not its bottom edge.
	mi.position = Vector3(0.0, ICON_SIZE_M * 0.5, 0.0)
	return mi
