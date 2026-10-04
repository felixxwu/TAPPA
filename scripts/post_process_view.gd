class_name PostProcessView
extends SubViewportContainer
# PS1 post-process host (see features/rendering.md). Packaged as
# post_process.tscn and instanced by every 3D scene (main.tscn's stage and the
# hub's MenuShowcase), so both render through the exact same pipeline. The 3D world stays in the
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

func _ready() -> void:
	# The single writer of the dither grid + colour grade, so no two hosts can
	# grade the game differently.
	Config.data.apply_post_process(material as ShaderMaterial)
	# SPIKE (throwaway): object-ID outline pass.
	var spike := preload("res://scripts/spike_id_pass.gd").new()
	add_child(spike)
	spike.setup.call_deferred(self, $View, _view_camera)

func _enter_tree() -> void:
	get_viewport().disable_3d = true

func _exit_tree() -> void:
	get_viewport().disable_3d = false

func _process(_delta: float) -> void:
	mirror_camera(_view_camera, get_viewport().get_camera_3d())

# Copy what a mirror camera needs from the active gameplay camera (shared with the
# outline pass's ID camera so the two can't drift).
static func mirror_camera(dst: Camera3D, src: Camera3D) -> void:
	if src == null:
		return
	dst.global_transform = src.global_transform
	dst.fov = src.fov
	dst.near = src.near
	dst.far = src.far
