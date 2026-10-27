# Opens a processed scan for a look by eye, the game body with the full scan parked beside it: blender <work>/body/car_body.blend --python open.py
import bpy
for o in bpy.data.objects:
    if 'usd_to_aligned' in o:   # the scan
        o.hide_set(False); o.location.x = 3.0
def frame():
    for area in bpy.context.screen.areas:
        if area.type == 'VIEW_3D':
            area.spaces.active.shading.type = 'MATERIAL'
            with bpy.context.temp_override(area=area, region=area.regions[-1]):
                bpy.ops.object.select_all(action='SELECT')
                bpy.ops.view3d.view_selected()
bpy.app.timers.register(frame, first_interval=1.0)
