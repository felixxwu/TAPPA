# Tree Render Distance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dissolve trees out over a short band and fully cull them past a configurable render distance (~chunk distance), entirely in the billboard shader.

**Architecture:** `billboard.gdshader` gains `render_distance` + `fade_band` uniforms; the vertex stage passes camera→tree distance to the fragment stage, which applies a 4×4 Bayer dithered dissolve (screen-door) so the opaque alpha-scissor pipeline is preserved. `TreeField.build` sets the two params from new `GameConfig` knobs.

**Tech Stack:** Godot 4 GL-compat spatial shader, GDScript, GUT tests. Existing: `shaders/billboard.gdshader`, `scripts/tree_field.gd`, `GameConfig`/`config/game_config.tres`, `scripts/world.gd`.

## Global Constraints

- This project is NOT under git — do NOT run git commands. "Commit" steps are no-ops; skip them.
- Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (override `$GODOT`).
- Run tests with `./run_tests.sh --fast <name>` / `./run_tests.sh`, ALWAYS `run_in_background: true`; never block. Never start a run while another `gut_cmdln` run is active.
- All tunables live in `config/game_config.tres` — never hardcode them in scripts.
- Default `tree_render_distance_m = 80.0`, `tree_render_fade_m = 15.0` (≈ the `RADIUS=1`, `CHUNK_M=50` → ~75 m chunk ring).
- Update `features/trees.md` in the same work.

---

### Task 1: Shader render-distance dissolve + knobs + wiring

**Files:**
- Modify: `shaders/billboard.gdshader`
- Modify: `scripts/tree_field.gd` (`build` sets the two shader params)
- Modify: `scripts/game_config.gd` (two knobs in the `Trees` group)
- Modify: `config/game_config.tres`
- Modify: `scripts/world.gd` (pass the knobs)
- Modify: `tests/headless/test_smoke.gd` (assert the material params)

**Interfaces:**
- Consumes: `GameConfig.tree_render_distance_m: float`, `GameConfig.tree_render_fade_m: float`.
- Produces: `TreeField.build(positions: PackedVector2Array, floor: TerrainManager, size: Vector2, collision_radius: float, collision_height: float, render_distance: float, render_fade: float) -> void`. The billboard material gets shader params `render_distance` and `fade_band`.

- [ ] **Step 1: Update the failing smoke test**

In `tests/headless/test_smoke.gd`, update the `field.build(...)` call inside `test_tree_field_builds_one_instance_per_position` to pass the two new args, and add the material-param assertions. The build call becomes:

```gdscript
	field.build(positions, floor, Vector2(4, 6), 0.5, 4.0, 80.0, 15.0)
```

Add, at the end of that same test:

```gdscript
	# Render distance is wired into the billboard material as shader params.
	var smat := field.multimesh.mesh.surface_get_material(0) as ShaderMaterial
	assert_not_null(smat, "quad has a ShaderMaterial")
	assert_eq(smat.get_shader_parameter("render_distance"), 80.0, "render_distance param set")
	assert_eq(smat.get_shader_parameter("fade_band"), 15.0, "fade_band param set")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./run_tests.sh --fast smoke` (background). Expected: FAIL — `build()` takes 5 args / params null.

- [ ] **Step 3: Add the shader uniforms + dithered dissolve**

Replace the full contents of `shaders/billboard.gdshader` with:

```glsl
// Cylindrical billboard: each instanced quad yaws to face the camera but stays
// upright (world Y up). Alpha-scissor cutout for crisp edges, no blend sorting.
// Past render_distance the tree is fully culled; over the fade_band before it,
// fragments dissolve out via a screen-door dither (keeps the opaque pipeline).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
uniform float render_distance = 80.0;
uniform float fade_band = 15.0;

varying float v_cam_dist;

// 4x4 ordered (Bayer) dither threshold in [0,1), indexed by screen pixel.
float bayer4x4(vec2 frag) {
	int x = int(mod(frag.x, 4.0));
	int y = int(mod(frag.y, 4.0));
	int index = x + y * 4;
	float m[16] = {
		0.0,  8.0,  2.0,  10.0,
		12.0, 4.0,  14.0, 6.0,
		3.0,  11.0, 1.0,  9.0,
		15.0, 7.0,  13.0, 5.0
	};
	return m[index] / 16.0;
}

void vertex() {
	// Per-instance world origin (column 3 of the model matrix).
	vec3 origin = MODEL_MATRIX[3].xyz;
	v_cam_dist = distance(INV_VIEW_MATRIX[3].xyz, origin);
	// Direction from the instance to the camera, flattened to the XZ plane.
	vec3 to_cam = (INV_VIEW_MATRIX[3].xyz - origin);
	to_cam.y = 0.0;
	to_cam = normalize(to_cam);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 right = normalize(cross(up, to_cam));
	// Preserve the instance's authored scale (quad is built 1x1, scaled by MODEL).
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	vec3 world_pos = origin + right * (VERTEX.x * sx) + up * (VERTEX.y * sy);
	// Rewrite to clip space directly; the default MODELVIEW path is bypassed.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
}

void fragment() {
	vec4 tex = texture(albedo, UV);
	// 1 up close, 0 at the cutoff; dither out fragments as it drops.
	float fade = clamp((render_distance - v_cam_dist) / max(fade_band, 0.001), 0.0, 1.0);
	if (tex.a < alpha_scissor || fade <= bayer4x4(FRAGCOORD.xy)) {
		discard;
	}
	ALBEDO = tex.rgb;
}
```

- [ ] **Step 4: Set the two params in `TreeField.build`**

In `scripts/tree_field.gd`, change the `build` signature and set the params on `mat`.

Signature:

```gdscript
func build(positions: PackedVector2Array, floor: TerrainManager, size: Vector2,
		collision_radius: float, collision_height: float,
		render_distance: float, render_fade: float) -> void:
```

Right after the existing `mat.set_shader_parameter("albedo", TREE_TEXTURE)` line, add:

```gdscript
	mat.set_shader_parameter("render_distance", render_distance)
	mat.set_shader_parameter("fade_band", render_fade)
```

- [ ] **Step 5: Add the config knobs**

In `scripts/game_config.gd`, immediately after the `tree_collision_height_m` export in the `Trees` group, add:

```gdscript
## Distance (m) past which trees are fully culled. Defaults near the loaded
## terrain extent (RADIUS=1, CHUNK_M=50 -> ~75 m).
@export_range(10.0, 500.0) var tree_render_distance_m := 80.0
## Width (m) of the dithered dissolve band just before the render cutoff.
@export_range(0.0, 100.0) var tree_render_fade_m := 15.0
```

- [ ] **Step 6: Set the knobs in the resource**

In `config/game_config.tres`, add inside the `[resource]` block (alongside the other `tree_*` lines):

```
tree_render_distance_m = 80.0
tree_render_fade_m = 15.0
```

- [ ] **Step 7: Pass the knobs from `world.gd`**

In `scripts/world.gd._generate_track`, update the `field.build(...)` call to:

```gdscript
	field.build(trees, $Floor as TerrainManager, cfg.tree_size_m,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m,
		cfg.tree_render_distance_m, cfg.tree_render_fade_m)
```

- [ ] **Step 8: Run the smoke subset to verify it passes**

Run: `./run_tests.sh --fast smoke` (background). Expected: PASS, no SCRIPT ERROR / Parse Error (this also confirms the shader compiles, since the material loads it and `test_shaders_load_with_code` checks it).

- [ ] **Step 9: Commit** — skip (project not under git).

---

### Task 2: Documentation

**Files:**
- Modify: `features/trees.md`

- [ ] **Step 1: Add a render-distance note**

In `features/trees.md`, in the "Rendering (`TreeField`)" section, append:

```markdown
Trees are culled by distance in the shader: past `tree_render_distance_m` they
are fully discarded, and over the `tree_render_fade_m` band just before that they
dissolve out via a 4×4 Bayer screen-door dither (keeping the opaque alpha-scissor
pipeline — no transparency sorting). The default ~80 m roughly matches the loaded
terrain (`RADIUS=1`, `CHUNK_M=50` → ~75 m). The cut tracks the camera with no
per-frame CPU.
```

- [ ] **Step 2: Add the knobs to the Configuration section**

In `features/trees.md`, extend the `Trees` group knob list to include
`tree_render_distance_m` (cull distance) and `tree_render_fade_m` (dissolve band).

- [ ] **Step 3: Commit** — skip.

---

### Task 3: Final verification

- [ ] **Step 1: Run the full suite**

Run: `./run_tests.sh` (background, `run_in_background: true`). Wait for the completion notification.
Expected: ALL tests pass, no `SCRIPT ERROR` / `Parse Error` / `Failed to load script`. If anything fails, treat the new code as the prime suspect (per CLAUDE.md) and fix it — do not weaken assertions.
