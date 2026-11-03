class_name PhotoModeHost
extends Node
# Docs: features/camera.md — update in the same change as this file.
# Tests: tests/headless/test_photo_mode.gd, tests/headless/test_free_roam_shell.gd — extend in the same change.
# Gives a scene with a PauseMenu its photo mode: answers the menu's request with a free-fly camera
# over the frozen world, clears the screen for the shot, and puts everything back on the way out.

# How far the camera may fly from where it started, in metres. 0 means no limit.
var max_range_m := 0.0

var _camera: PhotoModeCamera
var _controls: PhotoModeControls
var _hidden_layers: Array[CanvasLayer] = []


static func attach(scene: Node, max_range := 0.0) -> PhotoModeHost:
	var host := scene.get_node_or_null("PhotoModeHost") as PhotoModeHost
	if host == null:  # a stage regeneration runs its setup again
		host = PhotoModeHost.new()
		host.name = "PhotoModeHost"
		scene.add_child(host)
		(scene.get_node("PauseMenu") as PauseMenu).photo_mode_requested.connect(host.open)
	host.max_range_m = max_range
	return host


func open() -> void:
	if is_instance_valid(_camera):
		return
	_camera = PhotoModeCamera.new()
	_camera.name = "PhotoModeCamera"
	_camera.max_range_m = max_range_m
	_camera.exited.connect(_close)
	get_parent().add_child(_camera)
	_camera.enter(get_viewport().get_camera_3d())
	_set_chrome(false)
	# MobileControls is hidden with the rest and a phone has no Esc key, so without these a touch
	# player would be stuck flying with no way out.
	if Platform.is_touch():
		_controls = PhotoModeControls.new()
		_controls.name = "PhotoModeControls"
		get_parent().add_child(_controls)
		_controls.setup(_camera)


func _close() -> void:
	if is_instance_valid(_controls):
		get_parent().remove_child(_controls)
		_controls.queue_free()
	_controls = null
	if is_instance_valid(_camera):
		# Detached first, so a photo mode reopened this frame doesn't collide with the dying node's name.
		get_parent().remove_child(_camera)
		_camera.queue_free()
	_camera = null
	_set_chrome(true)
	var cameras := get_parent().get_node_or_null("CameraManager") as CameraManager
	if cameras != null:
		cameras.activate_current()
	(get_parent().get_node("PauseMenu") as PauseMenu).return_from_photo_mode()


# Hides every on-screen layer the scene is showing, and brings back only those. PostProcess mirrors
# the camera into the viewport that renders the world, so it must keep running while paused, or the
# photo camera would move with nothing on screen changing.
func _set_chrome(on: bool) -> void:
	if on:
		for layer in _hidden_layers:
			if is_instance_valid(layer):
				layer.visible = true
		_hidden_layers.clear()
	else:
		for child in get_parent().get_children():
			if child is CanvasLayer and child.visible and not child is PauseMenu:
				child.visible = false
				_hidden_layers.append(child)
	var post := get_parent().get_node_or_null("PostProcess")
	if post != null:
		post.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_ALWAYS
