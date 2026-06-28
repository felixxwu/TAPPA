extends SceneTree
# Offscreen model-iteration harness for the HQ map-table flag pins (RallyFlag).
# Renders the marker in all five rally states onto a slab of the real map texture
# (a 3/4 "hero" angle to judge the model + the steep near-top-down angle the
# in-game table camera uses), then boots the real HQ with a seeded spread of
# medals to eyeball the flags in-context. Outputs land in tools/render_out/.
#
#   xvfb-run -a godot --path rally --rendering-driver opengl3 \
#       --script tools/render_flags.gd
#
# Pure tooling — not shipped in the game.

const OUT_DIR := "res://tools/render_out"
const RES := Vector2i(1400, 800)
const RallyFlagScript := preload("res://scripts/rally_flag.gd")


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	await _render_states()
	await _render_in_context()
	quit()


# All five states on a map slab, from a hero angle and the steep table angle.
func _render_states() -> void:
	var svp := SubViewport.new()
	svp.size = RES
	svp.own_world_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(svp)

	var world := Node3D.new()
	svp.add_child(world)
	_add_garage_light(world)

	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(4.2, 4.2)
	plane.mesh = pm
	var mm := StandardMaterial3D.new()
	mm.albedo_texture = load("res://textures/map_table.jpg")
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plane.mesh.material = mm
	world.add_child(plane)

	# One flag per state, left → right: locked, 0, 1, 2, 3 stars.
	var states := [[true, 0], [false, 0], [false, 1], [false, 2], [false, 3]]
	for i in states.size():
		var locked: bool = states[i][0]
		var stars: int = states[i][1]
		var flag: Node3D = RallyFlagScript.build(locked, stars)
		flag.position = Vector3((i - 2) * 0.58, 0.0, 0.0)
		world.add_child(flag)
		var lbl := Label3D.new()
		lbl.text = "LOCKED" if locked else "%d star" % stars
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.font_size = 48
		lbl.pixel_size = 0.0016
		lbl.modulate = Color(0.05, 0.05, 0.05)
		lbl.position = flag.position + Vector3(0.0, -0.08, 0.18)
		world.add_child(lbl)

	var cam := Camera3D.new()
	cam.fov = 52.0
	world.add_child(cam)

	cam.look_at_from_position(Vector3(0.0, 1.05, 2.6), Vector3(0.0, 0.16, 0.0), Vector3.UP)
	await _settle()
	_save(svp, "flags_hero.png")

	cam.look_at_from_position(Vector3(0.0, 2.55, 1.35), Vector3(0.0, 0.05, -0.05), Vector3.UP)
	await _settle()
	_save(svp, "flags_table.png")

	svp.queue_free()


# The real HQ table with a few rallies finished, so the pins show varied medals.
func _render_in_context() -> void:
	for _i in 4:  # let the Save autoload finish loading its profile
		await process_frame
	var save := get_root().get_node("Save")
	save.complete_rally("shakedown", 60000, 1)        # P1 → 3 stars (gold)
	save.complete_rally("coastal_sprint", 90000, 2)   # P2 → 2 stars (silver)
	save.complete_rally("rwd_masters", 95000, 3)      # P3 → 1 star  (bronze)

	var svp := SubViewport.new()
	svp.size = Vector2i(1400, 900)
	svp.own_world_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(svp)

	var hq: Node3D = load("res://hq.tscn").instantiate()
	svp.add_child(hq)
	for _i in 40:
		await process_frame
	hq._go_to(hq.View.TABLE, true)
	for _i in 20:
		await process_frame
	_save(svp, "hq_table_flags.png")


func _add_garage_light(world: Node3D) -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.68)
	e.ambient_light_energy = 1.0
	env.environment = e
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(40.0), 0.0)
	sun.light_energy = 1.1
	world.add_child(sun)


func _settle() -> void:
	for _i in 12:
		await process_frame


func _save(svp: SubViewport, file_name: String) -> void:
	var img := svp.get_texture().get_image()
	var path := "%s/%s" % [OUT_DIR, file_name]
	var err := img.save_png(path)
	print("[flag-render] ", path, "  ", img.get_size(), "  err=", err)
