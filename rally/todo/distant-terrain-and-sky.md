# Distant Terrain + Skybox Spec — view distance & a real sky

> Status: **NOT STARTED — planning brief.** Brainstormed; nothing built. This is
> the implementation brief, referencing the code as it exists on this branch so
> it can be picked up later. Follow the project's config-first convention
> (`CLAUDE.md`): every new tunable goes in `GameConfig` (`scripts/game_config.gd`
> + `config/game_config.tres`), never hardcoded in scripts/scenes. Update the
> relevant `features/*.md` docs and add/adjust tests in the same piece of work.
>
> **Why these are one spec:** they form a single dependency chain. The fog is
> currently *load-bearing* — it hides the edge of the finite terrain — so a
> skybox is invisible until the terrain edge is pushed out. You cannot ship the
> sky without first extending view distance.
>
> **Relationship to `todo/performance-optimisations.md`:** that spec already owns
> the **billboard → opaque-low-poly-mesh** swap (its item 2 "Alternative
> direction" + the open action item "Create low-poly 3D models of the trees and
> foliage"). This spec does NOT duplicate that work — it **depends** on it and
> adds the *auto-LOD / far tier* on top. Do the mesh swap there first.

## Goal

Replace the "dense fog hides a 75 m terrain cliff" trick with real distance:
coarse LOD terrain rings give a horizon, fog is demoted to thin aerial haze, and
a simple **skybox** shows above the hills. Vegetation gets a distance LOD so the
newly-visible far foliage doesn't blow the mobile-web budget.

## Context / current state (measured from the code)

- **Renderer:** GL Compatibility (`project.godot`:159–161,
  `rendering_method.mobile="gl_compatibility"`, `force_vertex_shading=true`),
  internal viewport 480×360, all materials `unshaded`. Target: **mobile web**.
- **Terrain** (`scripts/terrain_manager.gd`): `CHUNK_M = 50`, `CELL_M = 1.0`,
  `SAMPLES = 51`, **`RADIUS = 1` → a 3×3 ring** = only ~75 m of ground from the
  car to the near edge of the outer chunk (~105 m to the far corner). `height_at`
  is pure noise (infinite in theory); only the ring is built, on worker threads,
  throttled to `MAX_INTEGRATIONS_PER_FRAME = 1`. (NB: some `features/*.md` still
  say "5×5" — the code is 3×3; fix when touching them.)
- **Fog** (`main.tscn`:16–21 env, re-applied at runtime in `scripts/world.gd`:30–33):
  `fog_enabled`, `fog_density` (code default `0.02` in `game_config.gd`:350, but
  the **active `config/game_config.tres`:35 sets `0.03`**), and crucially
  `fog_light_color = background_color` (`world.gd`:33) — fog color and background
  are locked together so the world dissolves seamlessly into the flat backdrop.
  `background_mode = 1` (BG_COLOR, a flat colour — `background_color` default
  `Color(0.35, 0.3, 0.45)`, `game_config.gd`:351). **No sky today.**
- **Foliage** (`scripts/billboard_field.gd`, `scripts/tree_scatter.gd`,
  `shaders/billboard.gdshader`): trees + bushes are alpha-scissor **cutout
  billboards**, each a single `MultiMesh` (one draw call), scattered once per
  track. Culled in-shader past `tree_render_distance_m` (`game_config.gd`:472,
  **80 m**) with a `tree_render_fade_m` (`:474`, 15 m) Bayer dither dissolve —
  the ~80 m cut is deliberately matched to the ~75 m terrain edge.
- **Post-process** (`shaders/ps1_post_process.gdshader`): full-screen quantize to
  **5-bit/channel + 4×4 Bayer dither**. It samples the *whole* screen, so a sky
  is stylised for free — but fine photographic detail is **crushed**.
- **HQ** builds its own `Environment` in code (`scripts/hq.gd`:116–120, also
  `BG_COLOR` off `background_color`) — any sky change must be applied there too.

## Dependency ordering (do them in this order)

1. **Terrain LOD rings** (§1) — pushes the edge out. *Prerequisite for the sky
   paying off.*
2. **Fog demotion** (§3) — only safe once §1 exists.
3. **Skybox** (§4) — only visible once fog is pulled back.
4. **Vegetation LOD** (§2) — depends on the billboard→opaque-mesh swap in
   `todo/performance-optimisations.md`. Independent of the sky, but the moment
   §1 extends view distance, the far foliage budget is what §2 protects. Can land
   before or after the sky.

The **billboard→opaque-low-poly-model swap** (perf spec) is itself a prerequisite
for §2 and a standalone mobile win — it can ship first, at the current 80 m cut,
with zero LOD work.

---

## 1. LOD terrain rings (distant coarse terrain)

**Problem:** the 3×3 ring ends at ~75 m, so fog must be opaque by then. To show a
sky we need terrain that continues to a far horizon without exploding the vertex
budget (a naive `RADIUS` bump is quadratic: `(2R+1)²` → 9/25/49 chunks, ~5k tris
each ≈ 45k/125k/245k tris).

**Approach — keep the detailed near ring, add a coarse far ring/backdrop.** Two
candidate shapes, in increasing generality:

- **(Recommended first) Static coarse backdrop ring.** A single large low-poly
  ring/dome built **once** from the same noise at coarse resolution (e.g. 4–8 m
  cells), far out, **no collision**, never reconciled per-frame. Gives a horizon
  silhouette for the sky to sit behind at a fraction of the cost and machinery.
- **(General, more code) True LOD rings.** Parametrise `compute_chunk_data` /
  chunk size by ring: an outer ring of bigger, coarser chunks around the detailed
  3×3. More faithful (it tracks the real noise as you move) but turns
  `CHUNK_M`/`CELL_M`/`SAMPLES` into per-ring values and interacts with the
  worker-thread queue + `MAX_INTEGRATIONS_PER_FRAME`.

Either way the coarse terrain reuses `height_at` / `_sample_height` and bakes the
same vertex light (`_bake_light`) so it matches the near ring's look at the seam.

**New config (`GameConfig` → `World`/`Terrain` group):** distant-ring radius,
coarse cell size, and the new far-edge distance. Keep collision on the near ring
only.

**Perf note:** measure with the `P` overlay (render-gpu / `integrations_total`)
before committing to (2) over (1). Cross-ref `todo/performance-optimisations.md`
§5 (terrain-collision advice) — do **not** add collision to the coarse ring.

## 2. Vegetation auto-LOD (depends on the model swap)

**Depends on:** `todo/performance-optimisations.md` item 2 "Alternative direction"
— **swap cutout billboards for opaque low-poly `.glb` meshes** (+ the open action
item to author the models). Rationale confirmed for this target: on tile-based
mobile-web GPUs, alpha-scissor `discard` **breaks early-Z and stacks overdraw**,
so opaque low-poly meshes are the better near representation. (Earlier "keep
billboards as the far LOD" idea is **withdrawn** — an alpha-test impostor pays the
same discard penalty and shimmers at small sizes; the far tier should be
**opaque**.)

**This spec adds the LOD tier on top of opaque meshes:**

- Lean on Godot 4's **importer-generated mesh LOD** (opaque decimation by screen
  size — set on the `.glb` import) so distant instances drop to a low LOD
  automatically. No hand-authored impostor.
- Use `visibility_range_begin/end` + fade for the final cull, repurposing the
  existing **`tree_render_fade_m`** dither-dissolve concept as a model→LOD/cull
  crossfade (was foliage→nothing).
- `MultiMesh` stays **one draw call** per foliage type; cost is vertex throughput,
  which auto-LOD shrinks at distance. Note: Godot doesn't auto-LOD a MultiMesh
  per-instance — the concrete shape is **near + far MultiMeshes partitioned by
  distance** (or per-field `visibility_range`).
- Raise **`tree_render_distance_m`** (currently 80 m, matched to the old edge)
  in step with §1's new view distance — this is the knob that decides whether
  distant trees appear at all. Bare coarse hills + sky also reads fine for the
  stylised look, so extending foliage distance is optional, not required.

Only an **opaque** impostor/atlas is worth considering if foliage is ever pushed
to very long range (hundreds of m) at huge counts — out of scope here.

## 3. Fog demotion (reduce, don't remove)

Once §1 pushes the edge out:

- Pull `fog_density` (`game_config.tres`:35) **down** so the sky is visible; keep
  a thin haze at the *new* far boundary (the coarse ring's edge) so that edge is
  still hidden — fog goes from "opaque wall at 75 m" to "aerial haze in the deep
  distance."
- **Keep some fog for mood** (the purple is atmosphere, not just edge-hiding).
- Keep `fog_light_color = background_color` (`world.gd`:33) and **match the sky's
  horizon to `background_color`** (§4) so the seam where distant terrain meets sky
  stays invisible.

## 4. Skybox (simple, real-looking)

Switch `Environment.background_mode` to **Sky** and assign a `Sky` resource, in
**both** `main.tscn` (the env sub-resource) and `scripts/hq.gd`:116–120. Drive the
sky's horizon colour from `cfg.background_color` in `world.gd` (mirroring the
existing `fog_light_color` line) so fog and horizon track together.

Two material options:

- **`ProceduralSkyMaterial`** — built-in sky/horizon/ground gradient. No assets,
  trivially **per-rally tintable**, and the horizon colour can be matched to
  `background_color` exactly. Cheapest, most PS1-friendly. Good default.
- **`PanoramaSkyMaterial`** (a real photographic equirectangular sky) — the
  "actually looks like a sky" option. Use a **CC0** source (Poly Haven). Caveats
  specific to this game:
  - The **post-process quantizes to 5-bit + dithers**, so a photoreal 4K HDRI is
    wasted — pick a **simple** sky (clear blue + a few soft cloud masses) and
    **downscale to LDR** (~2K equirect JPG). **No HDR needed** — the scene is
    `unshaded`, so the sky contributes no IBL/reflections.
  - LDR + downscaled is also what the **mobile-web** size/memory budget wants.
  - You lose the procedural sky's easy **horizon match** and **per-rally tint**:
    mitigate by keeping the thin horizon fog to blend the photo's horizon, and/or
    tinting via the sky material's energy/colour (or a small sky shader).

**Recommendation:** ship `ProceduralSkyMaterial` first (cheap, tintable, perfect
horizon match); evaluate a downscaled CC0 panorama as a second pass — a quick
**5-bit+dither preview** of any candidate image should gate that decision (a
photo may or may not survive the filter better than a clean gradient).

## Config knobs (new — all in `GameConfig`)

- Terrain: distant-ring radius, coarse cell size, far-edge distance (§1).
- Fog: reuse `fog_density` / `background_color`; consider a separate
  `fog_sky_affect` exposure if the sky needs to read clearly above the haze.
- Sky: material choice + horizon colour source (default = `background_color`);
  optional per-rally tint hook.
- Foliage: reuse `tree_render_distance_m` / `tree_render_fade_m`; raise in step
  with §1.

## Tests

- `tests/headless/test_render_smoke.gd` — extend: env uses a `Sky` background
  (mode), the sky horizon is driven from `background_color`, fog density is the
  reduced value; assert the coarse terrain ring builds (count) and carries baked
  light. (Headless has no GPU, so assert *setup*, not pixels — consistent with
  the existing render-smoke approach and the "no pixel golden" note in
  `features/rendering.md`.)
- `tests/headless/test_terrain.gd` — coarse-ring height/seam continuity vs the
  detailed ring (shared `height_at`), and that the coarse ring has no collision.
- Vegetation LOD: assert near/far partition by distance against a camera position
  (mirrors the cull test proposed in `todo/performance-optimisations.md` item 2).

## Docs to update (same piece of work)

- `features/rendering.md` — sky + fog-demotion + post-process-stylises-sky.
- `features/terrain.md` — the LOD ring(s); also fix any stale "5×5" → 3×3 + ring.
- `features/trees.md` — the model swap + auto-LOD far tier (cross-ref perf spec).
- `features/README.md` — index any new doc sections.

## Open questions (for Felix)

1. **Sky look:** flat procedural gradient (most PS1) vs a real CC0 panorama? And
   if panorama: clear blue / partly cloudy / sunset / overcast?
2. **Per-rally variety:** one fixed sky, or sky horizon riding the existing
   per-rally `background_color`?
3. **Distant-terrain shape:** static coarse backdrop ring (§1 recommended) vs
   full per-ring LOD chunks (more general, more code)?
4. **Far foliage:** show distant trees (raise `tree_render_distance_m` + the LOD
   tier) or keep foliage near and let bare coarse hills meet the sky?
