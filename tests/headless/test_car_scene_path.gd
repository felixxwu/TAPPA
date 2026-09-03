extends GutTest
# Guards the single-source-of-truth seam for the car scene path: `Scenes.CAR`
# (scripts/scenes.gd) is meant to be the ONE place that spells "res://car.tscn" in
# production code, the same way Scenes.HUB/MAIN/PODIUM/STANDINGS are the
# one place for the other scene paths. It used to be hardcoded at seven sites under
# three different local names (CAR_SCENE / CAR_SCENE_PATH / WRECK_CAR_SCENE) — this
# is a source-scan lint (same style as test_features_docs.gd) so a future hardcode
# doesn't quietly reintroduce an eighth.
#
# One site only: scripts/scenes.gd owns the literal and every other script derives from
# `Scenes.CAR` (or `Scenes.car_scene()` where a PackedScene is wanted — `preload()` cannot
# take a const reference, so the three former preload sites use the cached accessor).
#
# tools/bake_car_silhouettes.gd deliberately keeps its own literal and is NOT scanned here:
# it runs via `-s` and is compiled before the SceneTree and autoloads exist, so referencing
# `Scenes` there fails to compile (scenes.gd transitively pulls in the Config autoload).

const SCRIPTS_DIR := "res://scripts"
const LITERAL := "res://car.tscn"
const DEFINING_FILE := "res://scripts/scenes.gd"
const MAX_ALLOWED_LITERAL_SITES := 1  # scripts/scenes.gd, the definition — and nothing else


func _gd_files(dir_path: String) -> Array:
	var out := []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for name in dir.get_files():
		if name.ends_with(".gd"):
			out.append(dir_path.path_join(name))
	return out


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func test_car_scene_literal_is_confined_to_scenes_gd() -> void:
	var offenders := []
	for path in _gd_files(SCRIPTS_DIR):
		if _read(path).find(LITERAL) != -1:
			offenders.append(path)

	assert_true(offenders.has(DEFINING_FILE),
		"expected %s to define the %s literal (Scenes.CAR) but it doesn't" % [DEFINING_FILE, LITERAL])
	assert_lte(offenders.size(), MAX_ALLOWED_LITERAL_SITES,
		"%s literal leaked into scripts/ beyond the allowed sites: %s — route new sites through Scenes.CAR / Scenes.car_scene() instead of hardcoding the path" % [LITERAL, offenders])
