extends Node
# Scene-run cache generator (NOT a --script SceneTree: Config and the other
# autoloads only exist in a scene run) — mirrors generate_track_cache.gd exactly.
# Writes res://data/menu_showcase_cache.res. Invoked by cache_menu_showcase.sh; see
# MenuShowcaseCache's header for the whole scheme.


func _ready() -> void:
	var showcase: MenuShowcase = (preload("res://menu_showcase.tscn") as PackedScene).instantiate()
	# MUST be set before add_child() — _ready() (which would otherwise auto-build
	# and race the explicit build_and_capture() call below) fires the instant the
	# node enters the tree.
	showcase.skip_auto_build = true
	add_child(showcase)

	print("menu showcase cache: building live ...")
	var cache := await showcase.build_and_capture()

	if not DirAccess.dir_exists_absolute("res://data"):
		DirAccess.make_dir_recursive_absolute("res://data")
	var err := ResourceSaver.save(cache, MenuShowcaseCache.CACHE_PATH)
	if err != OK:
		push_error("menu showcase cache: failed to save %s (err %d)" % [MenuShowcaseCache.CACHE_PATH, err])
		get_tree().quit(1)
		return
	print("menu showcase cache: wrote %s — %d segments, %d tree points, %d bush points"
		% [MenuShowcaseCache.CACHE_PATH, cache.segment_chunk_data.size(),
			cache.tree_points.size(), cache.bush_points.size()])
	get_tree().quit(0)
