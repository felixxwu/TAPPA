# Tree render distance — design

## Goal

Stop trees rendering far beyond the generated terrain. Trees should dissolve
out over a short band and be fully gone past a configurable render distance that
roughly matches the chunk generation distance (3×3 ring of 50 m chunks ≈ 75 m).

## Approach

Trees are one `MultiMesh` drawn by `shaders/billboard.gdshader`. The render-
distance cut is done entirely in that shader — no per-frame CPU and it tracks
the camera automatically. To preserve the opaque alpha-scissor pipeline (real
alpha blending would reintroduce billboard transparency-sorting issues), the
fade is a **dithered dissolve**: fragments drop out in a screen-door pattern as a
tree approaches the cutoff, matching the project's existing PS1 dither look.

## Components

### `shaders/billboard.gdshader`

Add two uniforms:

```glsl
uniform float render_distance = 80.0;
uniform float fade_band = 15.0;
```

The vertex stage already computes the camera world position
(`INV_VIEW_MATRIX[3].xyz`) and the per-instance origin (`MODEL_MATRIX[3].xyz`).
Pass the camera→tree distance to the fragment stage as a varying:

```glsl
varying float v_cam_dist;
// in vertex(), after computing `origin`:
v_cam_dist = distance(INV_VIEW_MATRIX[3].xyz, origin);
```

In the fragment stage, compute a fade factor (1 up close, 0 at the cutoff) and
discard via a screen-space 4×4 Bayer dither threshold:

```glsl
float fade = clamp((render_distance - v_cam_dist) / max(fade_band, 0.001), 0.0, 1.0);
float threshold = bayer4x4(FRAGCOORD.xy);   // in [0,1)
if (tex.a < alpha_scissor || fade <= threshold) {
    discard;
}
```

`bayer4x4` is a small inline helper indexing a 4×4 ordered-dither matrix by
`int(FRAGCOORD.xy) % 4`. At `fade >= 1` no fragments are dithered out; as `fade`
drops toward 0 more are discarded; past `render_distance` (`fade == 0`) the whole
tree is gone.

### `scripts/tree_field.gd`

`build()` gains two parameters and sets the shader params on the billboard
material:

```
func build(positions, floor, size, collision_radius, collision_height,
        render_distance: float, render_fade: float) -> void
```

After creating `mat`:

```gdscript
mat.set_shader_parameter("render_distance", render_distance)
mat.set_shader_parameter("fade_band", render_fade)
```

### `scripts/world.gd`

Pass the two knobs into `field.build(...)`.

## Configuration — new knobs in the `Trees` group

| Knob | Type | Meaning | Default |
|------|------|---------|---------|
| `tree_render_distance_m` | float | distance past which trees are fully culled | 80.0 |
| `tree_render_fade_m` | float | width of the dissolve band before the cutoff | 15.0 |

Default 80 m roughly matches the loaded terrain: `RADIUS=1`, `CHUNK_M=50` →
~75 m from the car (≈105 m at ring corners).

## Tests — `tests/headless/test_smoke.gd`

Extend the TreeField test: after `build`, the QuadMesh material carries the two
shader params:

```gdscript
var smat := field.multimesh.mesh.surface_get_material(0) as ShaderMaterial
assert_eq(smat.get_shader_parameter("render_distance"), 80.0)
assert_eq(smat.get_shader_parameter("fade_band"), 15.0)
```

The existing `test_shaders_load_with_code` already covers the shader compiling
(it includes `billboard.gdshader`). The visual dissolve itself is not
unit-testable.

## Docs

Update `features/trees.md`: note the shader-side dithered render-distance cull
and the two new knobs.
