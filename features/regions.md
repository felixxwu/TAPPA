# Regions

**Source:** `scripts/region_library.gd` (`RegionLibrary`), worn in free roam by the biome rings
(`FreeRoamSettings.ring_regions`, `scripts/free_roam/biome_director.gd`, `TerrainStreamer`'s
per-ring materials and foliage) and on the dev stage by `world.gd._apply_region_look`.

**Tests:** `tests/headless/test_region_library.gd`, `tests/headless/test_region_assets.gd`, `tests/headless/test_free_roam_biomes.gd`

In free roam each **biome ring** of the island wears a region: its look, its handling and the
loot / weather of that ring ([free-roam.md](free-roam.md) → *Biomes*). Region unlock gating,
region pages and region runs are deleted.

**Adding a region:** an entry in `RegionLibrary.REGIONS`, a place in `ring_regions` for free
roam to wear it, and — because the dev stage and its tests still draw from it — an 8×3 stage
grid keyed with its id in `scripts/region_stage_library.gd`
(`test_region_assets.gd` → `test_every_region_has_authored_stages` guards that).

**A region that is a variant of another inherits, it does not clone.** Author
`look_from` plus only the keys that differ — see
[`look_from` — one-level look inheritance](#look_from--one-level-look-inheritance)
below; `taiga` and `home_coast` are the worked examples.

**Never invent an asset filename.** Every `res://` path a region authors (sky, grass,
gravel, trees) must be a file that already exists in the repo — list `textures/` and
pick from it; the `-greece`/`-snow` naming convention makes fabricated names look
plausible, and a dangling path ships as an untextured world. Guarded by
`test_region_assets.gd` → `test_every_authored_region_resource_path_resolves`.

A **region is a LOOK plus a WATERLINE**, plus optional HANDLING. The game ships five (`RegionLibrary.ordered()` lists them in authored `order`; free roam's
rings wear the ones named in `FreeRoamSettings.ring_regions`, spawn outward): `home` ("The
Green", the original green forest/plain world), `greece` ("The Dunes", arid), `taiga` ("The
Taiga", home's look with one much taller tree), `home_coast` ("The Lakes", the same forest
look with the sea raised MUCH higher than every other region, so the lakes read as unmistakably
flooded) and `snow` ("The Alps" — see [snow-region.md](snow-region.md)).

**A region is not look-only.** `snow` also carries HANDLING: per-surface grip overrides, a
deep-snow block and a frozen waterline. Those live OUTSIDE `LOOK_KEYS` (exactly as
`water_level` does) because they are consumed as handling — by `BiomeDirector.apply_handling`
in free roam and `StageConfig.apply_event_config` on the dev stage — not by the look pass.
Each is a `has_*` / `*_of` pair for the same value-vs-absent reason `water_level_of`
documents, and none is inherited through `look_from`.

## `RegionLibrary` (`scripts/region_library.gd`)

An authored catalogue, parallel to `CarLibrary`: `const REGIONS:
Array[Dictionary]`. **Array order carries no meaning** — each entry's `order` field is what
`ordered()` sorts by. Each entry has an `id` + `name`, an optional `water_level`,
optional look-override keys (a missing key inherits the scene/`GameConfig`
baseline), and an optional `look_from` (see below). Ships today:

- `home` — the original world: the green pine forest and open plain that cover
  the centre and east of the map. Authors its **foliage split
  explicitly** (`tree_mix` = 100% `res://textures/tree.png` at the home
  profile, `spawn_bush_mesh` = `true`) so the split is config-driven
  everywhere; every OTHER look field is left at the scene/`GameConfig`
  baseline. Its `water_level` is the original baseline (`-12.0`).

  Its one species carries `size_scale` `Vector2(1.25, 1.25)` — the forest 25%
  bigger than the profile card, so **9.375 x 9.375 m**. Note this is the reason
  home is no longer byte-identical to the pre-regions world, which it was for a
  long time and which several older comments still claim. The scale lives on the
  species rather than on `GameConfig.tree_size_m` because that profile is shared
  with Greece's 30% of ordinary trees, both Alps conifers and the taiga spire,
  all of which are tuned against its current value; raising the profile would
  scale all four. See [trees.md](trees.md).
- `greece` ("The Dunes", the arid look — the SW/S desert) — `sky_panorama`, `grass_texture`,
  `gravel_texture` (all `res://textures/*`), plus a Greek tree **split**:
  `tree_mix` = 70% `res://textures/tree-greece.webp` (the `region` sizing
  profile) + 30% `res://textures/tree.png` (the `home` profile), and
  `spawn_bush_mesh` = `false`. The mix reads as mostly the large low
  Mediterranean canopy with a few ordinary trees mixed in, and the 3D
  ground-cover bushes are dropped entirely (the arid map has no lush
  undergrowth). Being the one region with no ground cover at all, it is also the
  **stoniest**: it carries the catalogue's highest `rock_density`, and rocks are
  what fill a verge that would otherwise read as bare ([rocks.md](rocks.md)).
  It also overrides `tarmac_color` (a dark, warm asphalt — its roads are
  tarmac in free roam), `road_marking_color` (yellow
  lane paint instead of home's off-white) and `grass_particle_color` (a dry
  olive/tan wheel-dust blade, since home's green particle would read as a
  mismatch on this arid ground). Terrain tints are still **not** overridden —
  Greece inherits the home tints. Its own `water_level` is `-12.0` (the same
  baseline as home — an unrelated corner, not "home but drier").
- `home_coast` ("The Lakes") — the same forest look with the water raised: it
  authors `look_from: "home"` (so it inherits home's `tree_mix` /
  `spawn_bush_mesh` / everything else in `LOOK_KEYS`) plus its own,
  **much higher** `water_level` (`3.0`, against every other region's `-12.0`
  baseline — clearly above ground level, not merely "a bit wetter"). It authors
  no look keys of its own — the whole point of this corner is "home, but
  flooded."
- `snow` ("The Alps", the NE alpine massif) — `sky_panorama`, `grass_texture`
  (snow), `gravel_texture` (packed snow), a lightened `tarmac_color` (a dusting
  over asphalt, not a different material), a white `grass_particle_color` (the
  home green would read as grass blades flung off a snowfield),
  `spawn_bush_mesh` = `false` (nothing grows through snow) and a 60/40
  `tree_mix` of two CC0 photographic conifers. It carries the catalogue's
  **lowest** `rock_density` for the same reason the bushes are gone — deep snow
  buries loose stone — but deliberately not `0.0`: the boulders too big to cover
  still belong in the Alps ([rocks.md](rocks.md)). `road_marking_color` is
  deliberately OMITTED rather than set to white — buried lane paint, not fresh
  paint. It is also the ONLY region carrying handling blocks
  (`surface_grip` / `deep_snow` / `frozen_water`); see
  [snow-region.md](snow-region.md).
- `taiga` ("The Taiga", the NW boreal corner) — the THINNEST entry in the
  catalogue, and deliberately so. It authors `look_from: "home"`, its own
  `water_level` (`-12.0`, the same baseline) and **one** look key: `tree_mix`.
  Sky, gravel, tarmac, lane paint, terrain tints, grass and 3D ground cover are
  all home's, untouched. The whole region is one swapped tree.

  That tree is `textures/tree-taiga.webp` at 100%, on the `home` sizing profile,
  with `size_scale` `Vector2(0.90, 3.0)` — **6.75 x 22.5 m**, against the home
  broadleaf's 7.5 x 7.5 and the Alps' ~12.9 m conifers. The x is not a free
  choice: the cutout's natural w/h is 0.30, and the profile card is square, so
  `x = 0.30 * y` is what draws it at its own proportions instead of stretched
  (the same rule the snow species document). The y is the design — at three
  times the height of the forest either side of it, the silhouette alone
  carries the region, which is what lets every other look key stay inherited.

  `spawn_bush_mesh` is inherited (`true`) rather than dropped, unlike Greece and
  the Alps: a bare-trunked spire leaves a lot of open ground, and real taiga has
  a low shrub mat under the canopy.

  See [trees.md](trees.md) for the billboard and `tools/gen_taiga_tree.py` for
  how the cutout is made (same CC0 pack as the Alps, already cached in-repo).

Note on ids: `home` and `greece` were **not renamed** when the map went from
two swapped regions to four map corners, because `"home"` in particular is a
load-bearing literal hardcoded in `world.gd._current_region_look()` as the
default/challenge/fallback region id. Never rename it without also fixing that
call site (and auditing for other hardcoded `"home"` checks).

`LOOK_KEYS` is the whitelist of override fields a region may carry:
`sky_panorama`, `grass_texture`, `gravel_texture`, `tree_mix`,
`bush_billboard`, `spawn_bush_mesh`, `background_color`, `terrain_tint`,
`terrain_layers`, `tarmac_color`, `road_marking_color`,
`grass_particle_color`, `grass_particle_square`, `rock_density`.
`bush_billboard`/`terrain_tint`/`terrain_layers` are
reserved slots — schema support exists, nothing authors them yet.

`rock_density` is the odd one out: every other key changes what a region LOOKS like,
while this one changes how MUCH of something it has. It multiplies
`GameConfig.rock_groups_per_turn` and defaults to `1.0`, so a region that authors nothing
still gets rocks. Greece is stoniest, the Alps sparsest, everything else the middle;
rock models, colours and hitboxes are shared across all regions, so density is the only
thing that varies. See [rocks.md](rocks.md).

**Where the look is applied depends on the world.** On the dev stage there is exactly one
region, so `world.gd::_apply_region_look` pushes it wholesale (see "Theming the dev stage"
below). In free roam the player crosses rings, so `TerrainStreamer` builds per-ring ground
materials and reads the foliage/rock keys per chunk as it scatters, and `BiomeDirector` fades the
sky and applies the handling of the ring the car is in ([free-roam.md](free-roam.md)).

Three further keys a region may carry — `surface_grip`, `deep_snow` and `frozen_water` —
are deliberately NOT in this whitelist, for the same pipeline-ordering reason as
`water_level`; see the handling note at the top and [snow-region.md](snow-region.md).

Two fields a region can author are **deliberately excluded** from `LOOK_KEYS`,
for two different reasons:

- **`map_image`** — there is now one world map (`textures/map_world.jpg`,
  `RegionLibrary.DEFAULT_MAP_IMAGE`) shared by every region, so a region no
  longer owns a map texture of its own. (Before the four-corner map, `greece`
  authored its own `map_image` and the HQ table swapped textures per viewed
  region — that machinery is gone; see "One world map, no table swap" below.)
- **`water_level`** — handled as its own field (`water_level_of` /
  `has_water_level`, not `look_of`), because the look is applied to the
  driven world *after* track generation, whereas the waterline is needed *by*
  track generation (`TrackGenParams.resolve_water_level` runs before the world
  exists to theme). Folding it into `look_of`'s override-dict would put it a
  step too late in the pipeline. This is also why `look_from` inheritance
  explicitly does NOT extend to `water_level` (see below) — the whole point of
  `home_coast` is "same look, own (much higher) waterline."

### Checkpoint spacing (`rest_stop_spacing_of`)

`"rest_stop_spacing_m"` is the metres of free-roam road between checkpoints in the ring
wearing this region (`RoadSites.rest_spacing_at`). A region without it uses
`FreeRoamSettings.rest_stop_spacing_m`. Not inherited through `look_from`.

### Road surface (`has_tarmac_roads`)

`"road_surface": "tarmac"` makes a region's free-roam roads paved (default `"gravel"`). Like
`water_level`, it is not inherited through `look_from`. Free roam reads it per ring
(`RoadTerrain.tarmac_weight`, see [free-roam.md](free-roam.md) → "Biomes").

### Region waterline (`water_level_of` / `has_water_level`)

Each region may author its own `water_level` in metres. Resolution order —
implemented in `TrackGenParams.resolve_water_level(event, base)` — is: **the
event's own `water_level` (if the caller seated one) → the event's region's
`water_level_of` (if `has_water_level` is true) → the `base` GameConfig
baseline** passed in by the caller.

`water_level_of(region_id)` returns `0.0` for a region that authors no
waterline (including an unknown id) — **`0.0` is not a sentinel meaning
"unset,"** it is a real waterline that would be wrong to apply. Every caller
MUST gate on `has_water_level(region_id)` before trusting the return value;
never call `water_level_of` and treat a `0.0` result as "no override." This is
the same trap a `null`-less language always has for "value vs. absent" — the
API is split into two functions specifically so callers can't skip the check
by accident.

`look_from` inheritance (below) deliberately does **not** extend to
`water_level` — `home_coast` authors its own `water_level` directly, rather
than inheriting home's and needing a separate override to raise it. If
`water_level` were folded into the inherited block, "same look, much higher
water" would need an override on top of an inherited default, for no benefit.

### `look_from` — one-level look inheritance

This is the **authoring idiom for "region X, but different"** — reach for it
before copying a look block. A region may author
`"look_from": "<other_region_id>"` to inherit that
region's `LOOK_KEYS` block wholesale, instead of repeating it. `look_of`
resolves the parent's whitelisted keys first, then overlays the region's own
on top — so the region's own keys win over anything it also inherited.
Resolution is **exactly one level**: a parent's own `look_from` (if it had
one) is not followed, so chains and cycles are structurally impossible.

`home_coast` inherits `home`'s block wholesale and adds only its own, much
higher `water_level` (handled outside `look_of`, per above). `taiga` is the
other pattern: `look_from: "home"` plus a single overridden `tree_mix`, i.e.
"home with taller trees" in two authored keys
instead of a duplicated block.

`look_from` is itself deliberately **NOT** a `LOOK_KEYS` entry — if it were,
it would leak into the dict `world.gd` consumes as a real override field
(there being no `look_from` handling on the world-gd side, it would just sit
there inert at best, or collide with a real key at worst). It is read
directly off the region dict, never through the whitelist — an exclusion from
`LOOK_KEYS` is a note about the resolution order, not a hint that authors
should avoid the field.

`tree_mix` and `spawn_bush_mesh` need no special handling in this scheme —
both take the *already-resolved* look dict as their argument (see below), so
whether a value came from the region itself or was inherited via `look_from`
is transparent to them by the time they're called.

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

Like `CarLibrary`, `RegionLibrary` sits behind a `Registry.Seam`
(`static var _seam := Registry.Seam.new(REGIONS)`) so tests can
`override_for_test(regions)` a synthetic catalogue and `reset()` after —
**never** pin the shipped `REGIONS` values or Greek asset paths in a test (see
CLAUDE.md's catalogue-testing rule).

### Helper API (all static, catalogue-driven)

- `all()` / `by_id(id)` / `index_of(id)` / `count()` / `ordered()` — lookups.
- `look_of(region_id)` — returns **only the keys the region (and, via
  `look_from`, its parent) actually overrides** (filtered through
  `LOOK_KEYS`), not a fully-merged dict against the `GameConfig`/scene
  baseline. `home` returns just its foliage keys (`tree_mix` +
  `spawn_bush_mesh`), which resolve to the unchanged home look; every
  non-foliage field is still absent, so sky/ground stay at the scene
  baseline. Callers (`world.gd`) check `.has(key)` per field and only touch
  what's present, leaving everything else at its existing scene/`GameConfig`
  value.

**Deviation from the original design doc:** the spec described a
`resolve_look(region_id)` that *merges* each field with an explicit
`GameConfig` baseline. The shipped code is `look_of`, which returns
override-only keys — because the grass/gravel/sky **baselines live in
the scene** (the floor's `chunk_material` shader params, the
`WorldEnvironment`'s sky), not in `GameConfig` fields. Merging against a
`GameConfig` baseline that doesn't hold those values wasn't possible; instead
`world.gd` applies overrides selectively, so home's un-overridden scene values
are the baseline by construction.

**One field has since moved to the merged model:** `sky_panorama` now HAS a
`GameConfig` baseline (`default_sky_panorama`) and is applied unconditionally,
because leaving the sky at "whatever the shared scene material currently holds"
leaked the previous stage's sky — see "The sky no longer leaks between stages"
below. Grass and gravel still follow the override-only rule.

## Theming the dev stage (`world.gd._apply_region_look`)

Called from `_ready` immediately after `env.fog_sky_affect = cfg.fog_sky_affect`
(so it runs after the base environment is built, before the level otherwise
settles):

1. Resolve the driven stage's region. The dev stage always wears `"home"` (cached per world in
   `_region_look_cache`); the free-roam ring look is `BiomeDirector`'s job.
2. `var look := RegionLibrary.look_of(region_id)`; if empty (home, or an
   unrecognised id), return — no-op, leaving `main.tscn`'s baseline untouched.
3. Apply only the keys present:
   - `grass_texture` → `$Floor.chunk_material.set_shader_parameter("albedo_texture", ...)`.
   - `gravel_texture` → the same material's `"road_texture"` parameter.
   - `sky_panorama` → `$WorldEnvironment.environment.sky.sky_material.panorama`
     (cast to `PanoramaSkyMaterial`). **This one is the exception to "apply only
     the keys present": it is assigned unconditionally, falling back to
     `GameConfig.default_sky_panorama` when the region names none** — see below.
   - `background_color` → `env.background_color` **and** `env.fog_light_color`.
   - `terrain_tint` / `terrain_layers` — reserved; no region ships them yet, so
     there's no application code for them beyond a comment marking the hook.
   - `tarmac_color` is applied **not** here but a few lines later in `_ready`,
     where the floor's flat tarmac fill is set from `GameConfig` — that call now
     reads `_current_region_look().get("tarmac_color", cfg.tarmac_color)`, so a
     region override wins and home/free-roam fall back to the config value. (It
     lives there rather than in `_apply_region_look` because that shader param is
     already driven from `cfg` at that point; folding it into the region look
     would just be clobbered by the later `cfg` write.)
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

### The sky no longer leaks between stages

`sky_panorama` used to be applied like every other key — `if look.has(...)` — and
that was a **bug**. The `PanoramaSkyMaterial` hanging off `main.tscn`'s
`WorldEnvironment` is a **shared sub-resource with no `resource_local_to_scene`**, so
it is the same object for every instantiation of the scene in the process; and
`home` / `home_coast` author no `sky_panorama` at all. Drive a Greece or snow stage,
then a home stage, and the home stage skipped the assign — leaving Greece's or the
Alps' sky overhead, permanently, for the rest of the session.

The fix, in `world.gd._apply_region_look`, is to assign **always**:
`look.get("sky_panorama", Config.data.default_sky_panorama)`, loaded onto the
material (an empty path is still skipped). Every stage boot therefore seeds a clean
sky exactly once, which is the same idempotence `albedo_color` and `tarmac_color`
already get — and the same class of bug as the compounding road tint documented in
[weather.md](weather.md) → "Look", with the same shape of fix: **re-seed a clean
baseline every stage boot rather than conditionally overriding a shared resource.**
Any future look key that writes to a shared `main.tscn` sub-resource needs the same
treatment.

`GameConfig.default_sky_panorama` holds that baseline (the open-field sky
`main.tscn` was authored with), so home's "un-overridden scene value" is now an
explicit config value rather than whatever the material happened to be carrying. The
weather look runs **after** this and may override the sky again — night does, and
only night — so the ordering is: default → region → condition, re-derived from
scratch on every stage. See [weather.md](weather.md) → "Look" and
[rendering.md](rendering.md) → "Skybox". Guarded by
`tests/headless/test_headlight_cone.gd` →
`test_there_is_a_default_sky_for_regions_that_name_none`.
5. Road paint is region-aware in `world.gd._build_persistent_managers` (also NOT
   `_apply_region_look`, since the paint mesh is built at track generation, not
   with the materials): before calling `_road_markings.build`, it takes
   `cfg.road_marking_params()` and, if `_current_region_look()` carries a
   `road_marking_color`, replaces the params' `"color"` with it — so Greece paints
   yellow lane lines while home keeps the config off-white.
6. Waterline theming happens earlier still, at track *generation* rather than
   at `_ready` scene-theming time — see `TrackGenParams.resolve_water_level`
   under "Region waterline" above, not this list.

This is the single place the region look reaches the dev stage.

## Tests

`tests/headless/test_region_library.gd` — `look_of`'s override-vs-omit and `look_from`
inheritance against a **synthetic** region set installed via `RegionLibrary.override_for_test`,
`has_water_level` / `water_level_of`, the `tree_mix` / `spawns_bush_mesh` defaults, plus one
shipped-roster contract test — `test_lakes_region_has_a_higher_water_level_than_every_other_region`
— that asserts the RELATIONSHIP `home_coast` is designed around, never the numbers.
`tests/headless/test_region_assets.gd` — every authored `res://` path resolves.
`tests/headless/test_free_roam_biomes.gd` — rings wearing regions in free roam.
