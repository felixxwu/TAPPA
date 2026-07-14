# Regions

**Source:** `scripts/region_library.gd` (`RegionLibrary`), the `region` tag on
`RallyLibrary.RALLIES` (`scripts/rally_library.gd`), `world.gd._apply_region_look`,
`hq.gd` (`_viewed_region_index` / `_swap_region` / `_furthest_unlocked_index`)
+ `hq_environment.gd` (the diegetic table arrows), and the region-aware showdown
gating in `rally_session.gd` / `reward_system.gd`.

A **region** groups rallies under a shared look (satellite map image, sky,
ground textures) and a shared finale. The game ships with **2 regions** —
`home` (the original world) and `greece` — and regions **unlock in sequence**:
finishing a region's own Showdown unlocks the next one. Only the **final**
region's Showdown is the win/credits beat; every other region's Showdown just
completes normally.

## `RegionLibrary` (`scripts/region_library.gd`)

An authored catalogue, parallel to `RallyLibrary`/`CarLibrary`: `const REGIONS:
Array[Dictionary]`, ordered by **unlock sequence** (array index = unlock
order). Each entry has an `id` + `name` plus **optional** look-override keys —
a missing key inherits the scene/`GameConfig` baseline, so `home` (index 0)
authors **no** overrides and the home world stays byte-identical to before
regions existed. Ships today:

- `home` — authors its **foliage split explicitly** (`tree_mix` = 100%
  `res://textures/tree.png` at the home profile, `spawn_bush_mesh` = `true`) so
  the split is config-driven everywhere; every OTHER look field is left at the
  scene/`GameConfig` baseline, so the home world still looks byte-identical.
- `greece` — `map_image`, `sky_panorama`, `grass_texture`, `gravel_texture`
  (all `res://textures/*`), plus a Greek tree **split**: `tree_mix` = 70%
  `res://textures/tree-greece.webp` (the `region` sizing profile) + 30%
  `res://textures/tree.png` (the `home` profile), and `spawn_bush_mesh` =
  `false`. The mix reads as mostly the large low Mediterranean canopy with a few
  ordinary trees mixed in, and the 3D ground-cover bushes are dropped entirely
  (the arid map has no lush undergrowth). Terrain tints are still **not**
  overridden — Greece inherits the home tints.

`LOOK_KEYS` is the whitelist of override fields a region may carry:
`map_image`, `sky_panorama`, `grass_texture`, `gravel_texture`,
`tree_mix`, `bush_billboard`, `spawn_bush_mesh`, `background_color`,
`terrain_tint`, `terrain_layers`. `bush_billboard`/`terrain_tint`/
`terrain_layers` are reserved slots — schema support exists, nothing authors
them yet. `tree_mix` and `spawn_bush_mesh` are live (home + Greece).

### Tree species split (`tree_mix`)

`tree_mix` is a weighted list of billboard tree **species** — each entry is
`{"texture": <res path>, "profile": "home" | "region", "weight": <float>}`.
`world.gd` splits the scattered tree positions across the species by weight
(`TreeScatter.partition_by_weight`) and spawns **one `BillboardField` per
species**, so a stage can be a mix (Greece: 70/30). The `profile` selects the
`GameConfig` sizing/jitter block that species renders at — `"home"` →
`tree_size_m` et al., `"region"` → `region_tree_billboard_size_m` et al. — so
the mixed-in home tree.png keeps its smaller home size while Greece's own tree
uses the tall canopy size. **All balance values stay in `GameConfig`**; the
region only authors WHICH texture, WHICH profile, and the WEIGHT. Helpers:
`RegionLibrary.tree_mix(look)` returns the authored mix or
`DEFAULT_TREE_MIX` (single home tree at 100%) when a region authors none (free
roam / unknown id); `RegionLibrary.spawns_bush_mesh(look)` returns the
`spawn_bush_mesh` flag, defaulting `true`. The partition is deterministic per
`track_seed` (hashed off each point's grid cell), so felling-restore keeps a
tree its species, and multiple `BillboardField`s replay-reset fine (`world.gd`
walks every foliage child for `reset_fallen`).

Like `RallyLibrary`/`CarLibrary`, `RegionLibrary` sits behind a `Registry.Seam`
(`static var _seam := Registry.Seam.new(REGIONS)`) so tests can
`override_for_test(regions)` a synthetic catalogue and `reset()` after —
**never** pin the shipped `REGIONS` values or Greek asset paths in a test (see
CLAUDE.md's catalogue-testing rule).

### Helper API (all static, catalogue-driven)

- `all()` / `by_id(id)` / `index_of(id)` / `count()` — lookups.
- `is_final(region_id)` — true only for the last entry in `REGIONS`.
- `region_for_rally(rally_id)` — looks the rally up in `RallyLibrary.all()`,
  returns the owning region dict (`.get("id")` for the id string; `{}` if the
  rally or its region tag is unknown).
- `rallies_in(region_id)` — the `RallyLibrary` entries tagged to this region,
  in author order.
- `showdown_of(region_id)` — that region's single `showdown == true` rally.
- `unlocked(region_id, profile)` — **derived, no new Save field**: region 0 is
  always unlocked; region *k* is unlocked iff region *(k−1)*'s showdown rally
  is `completed` in `profile.rallies`.
- `showdown_unlocked(region_id, profile)` — true iff every **non-showdown**
  rally in this region is completed in `profile`. **Note the guard beyond the
  design spec:** it first checks `unlocked(region_id, profile)` and returns
  `false` immediately if the region itself isn't reachable yet — otherwise a
  region with no completed rallies (because none are authored, or the region
  is simply unreached) would vacuously read as "showdown unlocked."
- `look_of(region_id)` — returns **only the keys the region actually
  overrides** (filtered through `LOOK_KEYS`), not a fully-merged dict against
  the `GameConfig`/scene baseline. `home` returns just its foliage keys
  (`tree_mix` + `spawn_bush_mesh`), which resolve to the unchanged home look;
  every non-foliage field is still absent, so map/sky/ground stay at the scene
  baseline. Callers (`world.gd`, `hq.gd`) check `.has(key)` per field and only
  touch what's present, leaving everything else at its existing scene/`GameConfig`
  value.

**Deviation from the design doc:** the spec described a `resolve_look(region_id)`
that *merges* each field with an explicit `GameConfig` baseline. The shipped
code is `look_of`, which returns override-only keys — because the grass/gravel/
sky **baselines live in `main.tscn`** (the floor's `chunk_material` shader
params, the `WorldEnvironment`'s sky), not in `GameConfig` fields. Merging
against a `GameConfig` baseline that doesn't hold those values wasn't possible;
instead `world.gd` applies overrides selectively, so home's un-overridden scene
values are the baseline by construction.

## Rallies tagged by region

Every `RallyLibrary.RALLIES` entry now carries `"region": "<region_id>"`. The
9 original rallies are `"home"`; a fresh Greek roster adds 4 more (3 regular +
1 showdown): `gr_olive_coast`, `gr_mountain_pass`, `gr_ancient_ruins` (regular,
difficulty 2/3/3), and `gr_showdown` ("The Aegean Crown", difficulty 4,
`showdown: true`). See `scripts/rally_library.gd` lines ~184-224.

**Invariant:** "exactly one showdown globally" → **"exactly one showdown per
region"** (`scripts/rally_library.gd` header comment, ~line 80-82;
`test_rally_library.gd` asserts the per-region form). Home keeps `the_showdown`
as its region's finale; Greece has its own `gr_showdown`.

`RallyLibrary.incomplete_rallies_enterable_by` (the anti-soft-lock query used
by the reward system) is region-aware: a rally's showdown is only offered as
enterable once `RegionLibrary.showdown_unlocked(rally.region, profile)` is
true for **that rally's own region** (`scripts/rally_library.gd` ~line 653-663).

## Theming the driven world (`world.gd._apply_region_look`)

Called from `_ready` immediately after `env.fog_sky_affect = cfg.fog_sky_affect`
(so it runs after the base environment is built, before the level otherwise
settles):

1. Resolve the driven rally's region — `region_id = "home"` if no
   `RallySession` is active, else
   `RegionLibrary.region_for_rally(RallySession.rally_id()).id`. Free roam has no
   session but picks a random location: when `free_roam_instance_id >= 0` and
   `RallySession.free_roam_region_id` is set (`hq._prepare_free_roam` rolls
   home/Greece), that id is used. This resolution
   lives in `world.gd._current_region_look()`, shared by `_apply_region_look`
   (materials/sky/fog) and the foliage spawn (below).
2. `var look := RegionLibrary.look_of(region_id)`; if empty (home, or an
   unrecognised id), return — no-op, leaving `main.tscn`'s baseline untouched.
3. Apply only the keys present:
   - `grass_texture` → `$Floor.chunk_material.set_shader_parameter("albedo_texture", ...)`.
   - `gravel_texture` → the same material's `"road_texture"` parameter.
   - `sky_panorama` → `$WorldEnvironment.environment.sky.sky_material.panorama`
     (cast to `PanoramaSkyMaterial`).
   - `background_color` → `env.background_color` **and** `env.fog_light_color`.
   - `terrain_tint` / `terrain_layers` — reserved; no region ships them yet, so
     there's no application code for them beyond a comment marking the hook.
4. Foliage is region-aware in `world.gd`'s stage-generation (NOT
   `_apply_region_look`, which only touches materials/sky/fog): it reads the
   same `_current_region_look()` before scattering.
   - `tree_mix` → `world.gd` splits the scattered points by weight
     (`TreeScatter.partition_by_weight`) and calls `Foliage.spawn_trees(...)`
     once per species, passing that species' `texture` and a
     `use_region_profile` flag (from its `profile`). Trees are always opaque
     billboards; an unauthored region falls back to the default single
     `textures/tree.png` home tree. See the `tree_mix` section above +
     [trees.md](trees.md).
   - `spawn_bush_mesh` → when false, `world.gd` skips the entire bush pass
     (no `Foliage.spawn_bushes`, no `BushField` interaction node); defaults true.
   - `bush_billboard` is still a reserved slot — nothing authors it yet.

This is the single place the region look reaches the run scene; the rally
already carries its `region`, so no extra plumbing was needed into
`Config.data` or the scene tree.

## HQ table — diegetic region swap (`hq.gd` + `hq_environment.gd`)

`HQEnvironment` (`scripts/hq_environment.gd`) builds two pickable props on the
map table alongside the `MapTable` model: `arrow_left` / `arrow_right`
(`Area3D`, `input_ray_pickable`) — small procedural meshes on the table's side
edges, wired back to `hq.gd`'s click handlers the same way the map pins are.

`hq.gd` tracks `_viewed_region_index` (which region's map/pins the table is
currently showing), separate from `_table_focus_index` (the currently-selected
target — see the Nav section below):

- **Entry default:** entering the TABLE view seeds
  `_viewed_region_index = _furthest_unlocked_index()` — the player always lands
  on the furthest region they've unlocked, not necessarily `home`.
- **`_furthest_unlocked_index()`** — walks `RegionLibrary.all()` and returns
  the highest index whose `RegionLibrary.unlocked(id, Save.profile)` is true.
- **`_swap_region(step)`** — `target = clampi(_viewed_region_index + step, 0,
  _furthest_unlocked_index())`; a no-op if `target == _viewed_region_index`
  (already at an edge). This is the "disable navigation past the furthest
  unlocked region" choice from the design doc's open question — arrows simply
  stop working past the edge, no dimmed/locked preview of an unreached region.
- **On swap**, the table view rebuilds around `_viewed_region_id()`:
  - re-textures `map_plane` to `RegionLibrary.look_of(region_id).get("map_image",
    "res://textures/map_table.jpg")` (home's fallback is the original map
    texture, since `look_of("home")` authors no `map_image`);
  - rebuilds pins from `RegionLibrary.rallies_in(region_id)` only — **not**
    the flat `RallyLibrary.all()` — so a viewed region only ever shows its own
    pins;
  - re-seats selection via `_select_target_under_center()` (the target nearest
    the view centre in the new pin set);
  - the showdown-lock check (`RegionLibrary.showdown_unlocked(region_id,
    Save.profile)`) and the progress meter are both scoped to the **viewed**
    region, not the whole game.
- **Test hook:** `_set_viewed_region_for_test(i)` jumps the table straight to
  an index (bypassing the arrow clamp) and refreshes pins, for tests that need
  to inspect a specific region's pins without walking the swap sequence.

### Nav — camera glide + nearest-to-centre selection (`View.TABLE`)

The table has no discrete pin cursor. **Up/down/left/right glide the camera
smoothly over the map** and selection tracks whatever sits under the view
centre — a reticle over the map, not a jump between pins. The map-swap arrows
are just two more targets, selected the same way when they're nearest the
centre (so gliding to the map's right edge selects `arrow_right`).

- **Glide:** `hq.gd._process` polls the held `menu_up`/`menu_down`/`menu_left`/
  `menu_right` actions each frame (only in `View.TABLE`, detail panel closed)
  and calls `_pan_table_step(dir2, hq_table_pan_glide · delta)`, which slides
  `_table_pan` in the screen-direction (clamped to the map extents), snaps the
  camera (`_move_camera_to(..., true)`), then re-selects.
- **Selection:** `_select_target_under_center()` seats `_table_focus_index` on
  whichever `_table_targets()` entry (pin or arrow) is nearest `_table_center_pos()`
  — the look point offset by the live `_table_pan`, i.e. where the camera's
  centre ray meets the map. Drag-pan (`_pan_table`) and table entry
  (`_enter_table` / `_refresh_map_pins`) re-select through the same call, so
  pointer, keyboard, and gamepad all agree.
- **Select / back:** `menu_select` → `_activate_table_focus()` opens the
  selected pin's rally detail, or (on an arrow) calls `_swap_region(±1)` and
  re-seats via `_focus_nearest_pin`. A locked forward arrow's swap is inert.
- The diegetic arrow *props* remain pointer-clickable via `_on_arrow_input`
  (fires on release), reaching the same `_swap_region` calls.

This reuses the existing keyboard + gamepad action names (already bound to
arrows/WASD/D-pad/stick), so no new input actions were needed.

See [menus.md](menus.md) → TABLE for how this sits alongside the drag-to-pan
and pin-detail flow.

## Progression: sequential unlock, per-region showdown, final-region credits

- **Unlock is derived, not stored.** There is no new `Save`/profile field for
  "region unlocked" — `RegionLibrary.unlocked(region_id, profile)` recomputes
  it every call from the previous region's showdown-rally completion flag
  already in `profile.rallies`. See [save-persistence.md](save-persistence.md).
- **Per-region showdown gating.** Both `hq.gd` (locking the showdown pin on the
  table) and `reward_system.gd` (the still-locked-showdown draw-walk,
  `_unlock_candidates`) call `RegionLibrary.showdown_unlocked(region_id,
  profile)` scoped to a specific region, rather than the old single global
  `RallyLibrary.showdown_unlocked`.
- **Final-region credits.** `rally_session.gd`'s `_resolve_results` emits
  `showdown_won()` — the win/credits beat — **only** when
  `RegionLibrary.is_final(region_id)` for the just-won showdown's region
  (`scripts/rally_session.gd` ~line 418-422). A non-final region's showdown win
  (e.g. home's `the_showdown`) instead just completes like any other rally:
  it records completion/best-placement and pays the normal `RewardSystem.draw_car`
  reward, and its completion is what makes `RegionLibrary.unlocked("greece",
  profile)` flip true on the next check. See [rally-session.md](rally-session.md)
  and [reward-system.md](reward-system.md).

## Tests

`tests/headless/test_region_library.gd` — grouping/derivation logic against a
**synthetic** region/rally set installed via `RegionLibrary.override_for_test`
(never the shipped Greek roster or textures): `region_for_rally`/`rallies_in`
round-trip, `unlocked` across a chain of 3+ synthetic regions, per-region
`showdown_unlocked` (including the "region not yet reached" guard), `is_final`,
and `look_of`'s override-vs-omit behaviour with synthetic values. The
per-region showdown invariant and the `region` tag on every rally are asserted
in `tests/headless/test_rally_library.gd`. The table's region swap (viewed
region clamped to furthest unlocked, pins rebuilt to that region only,
keyboard + gamepad reachable) is covered in the HQ nav tests
(`tests/headless/test_menu_nav.gd` / the nav cases in `test_menu_flow.gd`). The
reward system's region-aware draw-walk is covered in `test_reward_system.gd`.
