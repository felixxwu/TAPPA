class_name RegionBanner
extends CanvasLayer
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_biomes.gd — extend in the same change.
# Driving into a biome ring for the first time in this world: the region's name in the same band
# across the screen as "Checkpoint reached" (CheckpointBanner.build_band). "First time" is
# WorldSession's max_ring high-water mark, so it persists with the save. A region reached while the
# checkpoint band is up waits for it, so the two never stack.

var checkpoint_banner: CheckpointBanner

var _band: Control
var _pending := ""


func _init() -> void:
	layer = 7
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_showing_banner() -> bool:
	return _band != null


# The display name of the region ring `r` wears.
static func name_for(s: FreeRoamSettings, r: int) -> String:
	var region := BiomeDirector.region_of(s, r)
	return String(RegionLibrary.by_id(region).get("name", region))


# Queue the band for `region_name`; it shows as soon as the checkpoint band is out of the way.
func announce(region_name: String) -> void:
	_pending = region_name
	_try_show()


func _process(_delta: float) -> void:
	if _pending != "":
		_try_show()


func _try_show() -> void:
	if checkpoint_banner != null and checkpoint_banner.is_showing_banner():
		return
	var text := _pending
	_pending = ""
	if _band != null:
		_band.queue_free()
	_band = CheckpointBanner.build_band(text)
	add_child(_band)
	_band.modulate.a = 0.0
	var tween := _band.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_band, "modulate:a", 1.0, Config.data.free_roam.banner_fade_s)
	tween.tween_interval(Config.data.free_roam.banner_hold_s)
	tween.tween_property(_band, "modulate:a", 0.0, Config.data.free_roam.banner_fade_s)
	tween.tween_callback(_banner_done)


func _banner_done() -> void:
	if _band != null:
		_band.queue_free()
		_band = null
