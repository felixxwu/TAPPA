extends SubViewportContainer
# PS1 post-process host (see features/rendering.md). The 3D world stays in the
# main scene tree (so every node path, physics body, and camera is untouched),
# but it's RENDERED through the child SubViewport: the viewport shares the main
# World3D (own_world_3d = false) and carries a mirror camera synced every frame
# to whichever gameplay camera is current. This container draws the viewport
# texture through the dither shader (its material), which avoids the
# hint_screen_texture backbuffer copy the old full-screen ColorRect forced —
# a render-pass break + mid-frame GPU submit per frame on the GL backend.
#
# While this scene is in the tree, 3D rendering on the ROOT viewport is
# disabled (the world would otherwise render twice); restored on exit so the
# HQ scene renders normally. Cameras stay current on the root viewport, which
# keeps positional audio and get_camera_3d() working — disable_3d only skips
# the render pass.

@onready var _view_camera: Camera3D = $View/ViewCamera

func _enter_tree() -> void:
	get_viewport().disable_3d = true

func _exit_tree() -> void:
	get_viewport().disable_3d = false

func _process(_delta: float) -> void:
	var src := get_viewport().get_camera_3d()
	if src == null:
		return
	_view_camera.global_transform = src.global_transform
	_view_camera.fov = src.fov
	_view_camera.near = src.near
	_view_camera.far = src.far
