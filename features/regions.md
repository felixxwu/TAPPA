# Regions

**Source:** `scripts/region_library.gd` (`RegionLibrary`), the `region` tag on
`RallyLibrary.RALLIES` (`scripts/rally_library.gd`), `world.gd._apply_region_look` (and
`_current_region_look`), `scripts/region_stage_pool.gd` (the run's stage draw) and
`HubShell`'s REGION page.

**Tests:** `tests/headless/test_region_library.gd`, `tests/headless/test_rally_library.gd`, `tests/headless/test_headlight_cone.gd`, `tests/headless/test_menu_nav.gd`, `tests/headless/test_hub_shell.gd`

**Adding a region takes TWO edits.** An entry in `RegionLibrary.REGIONS` is inert on
its own — the only thing that ever selects a region is a rally's `region` tag in
`RallyLibrary.RALLIES`. Add the region AND **a new rally** tagged with its id, or you
have shipped a region that renders nowhere while every region test still passes.
`tests/headless/test_region_assets.gd` →
`test_every_region_is_reachable_from_at_least_one_rally` guards this, and its failure
message prints the exact minimal `RALLIES` row to paste (the same template lives in the
comment above `RegionLibrary.REGIONS`). Do **not** satisfy it by re-pointing an existing
rally's `region`: that goes green while silently restyling a stage whose `map_pos` and
authored weather were written for its old corner. Do both edits in the same change —
"ready for a rally to reference later" is a shipped half-feature.

**Do not pick the new rally's `map_pos` by eye.** Every other field in that template is a
literal you can keep; `map_pos` used to be the one whose rule was prose ("in your corner,
`>0.03` from every other pin, within `map_reveal_radius` of one") next to a placeholder
`Vector2(0.5, 0.5)` that is itself illegal — it is HQ. Ask for one instead:

- `RallyLibrary.suggest_map_pos("<region_id>")` returns a legal, currently-free pin
  anchored on an existing rally in that region — deterministic, derived from the live
  roster, so it cannot go stale the way a listed coordinate would. For a brand-new region
  with no rally yet it anchors on HQ (the map centre); pass a neighbouring region's id to
  land the suggestion in the corner you actually want, then re-check it.
- `RallyLibrary.map_pos_is_free(pos)` checks a coordinate you chose yourself.
- `RallyLibrary.MIN_PIN_SEPARATION` is the single source of the `0.03` bound — the
  authoring helpers and `test_map_pins_are_well_formed_and_never_stack` both read it, and
  that test's failure message now prints a suggested legal coordinate to paste.

**A region that is a variant of another inherits, it does not clone.** Author
`look_from` plus only the keys that differ — see
[`look_from` — one-level look inheritance](#look_from--one-level-look-inheritance)
below; `taiga` and `greece_coast` are the worked examples.

**Never invent an asset filename.** Every `res://` path a region authors (sky, grass,
gravel, trees) must be a file that already exists in the repo — list `textures/` and
pick from it; the `-greece`/`-snow` naming convention makes fabricated names look
plausible, and a dangling path ships as an untextured world. Guarded by
`test_region_assets.gd` → `test_every_authored_region_resource_path_resolves`.

A **region is a LOOK plus a WATERLINE** — sky, ground textures, foliage, sea
height — applied to whichever rallies are tagged with it. It is **not a corner
of the map**, even though it started life that way. The game ships six:
`home` (the original green forest/plain world), `home_coast` (that same look
with the sea raised), `greece` (arid), `greece_coast` (arid, sea raised), `snow`
(the alpine NE massif — see [snow-region.md](snow-region.md)) and `taiga` (the NW
boreal corner: home's look with one much taller tree).

**A region is no longer look-only.** `snow` also carries HANDLING: per-surface grip
overrides, a deep-snow block and a frozen waterline. Those live OUTSIDE `LOOK_KEYS`
(exactly as `water_level` does) because they are consumed by
`StageConfig.apply_event_config` at stage setup, not by `world.gd`'s look pass after
generation. Each is a `has_*` / `*_of` pair for the same value-vs-absent reason
`water_level_of` documents, and none is inherited through `look_from`.
Every rally is pinned on the one world map (`textures/map_world.jpg`, 848x848)
at once, and **regions do not unlock in sequence**: there is no "next region"
gate, and **no region-level gate of any kind** —
a region's only job is its LOOK and its `water_level`
(`RegionLibrary.REGIONS`'s header comment states this explicitly). Progression
gating is the LINEAR REGION UNLOCK (decision 12) — see *Progression* below.
`RegionLibrary.is_unlocked` reads `Save.KEY_REGIONS_CLEARED`, and a rally is simply part
of whichever region's pool it is tagged into.

The geometric rule this replaced is worth one line so nobody looks for it: a rally became
enterable once the player's lit map reached its `map_pos` (`rally_revealed` /
`lit_sources`), which was itself a replacement for a roster-wide star total and then a
completed-rally counter. All three are deleted with the map. The
credits/win beat fires once **every** special event is completed
(`RallyLibrary.all_specials_completed`), not tied to any region — see
[rally-roster.md](rally-roster.md).

The map's NW corner is the `taiga` region ("The Taiga") and carries five rallies,
all re-tagged out of `home` — which is what pulls `home` in to the map's centre.

The map's NE snow massif is now the `snow` region ("The Alps") and carries six
rallies. See [snow-region.md](snow-region.md).

## `RegionLibrary` (`scripts/region_library.gd`)

An authored catalogue, parallel to `RallyLibrary`/`CarLibrary`: `const REGIONS:
Array[Dictionary]`. **Array order carries no meaning** — regions don't unlock
in sequence and there's no "final" region, so nothing may depend on a region's
position in the array. Each entry has an `id` + `name`, an optional `water_level`,
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
- `home_coast` ("The Lakes") — the same forest look with the water raised: it
  authors `look_from: "home"` (so it inherits home's `tree_mix` /
  `spawn_bush_mesh` / everything else in `LOOK_KEYS`) plus its own, higher
  `water_level` (`-5.0`). It authors no look keys of its own — the whole point
  of this corner is "home, but wetter."
- `greece` ("Greece", the arid look — the SW/S desert) — `sky_panorama`, `grass_texture`,
  `gravel_texture` (all `res://textures/*`), plus a Greek tree **split**:
  `tree_mix` = 70% `res://textures/tree-greece.webp` (the `region` sizing
  profile) + 30% `res://textures/tree.png` (the `home` profile), and
  `spawn_bush_mesh` = `false`. The mix reads as mostly the large low
  Mediterranean canopy with a few ordinary trees mixed in, and the 3D
  ground-cover bushes are dropped entirely (the arid map has no lush
  undergrowth). Being the one region with no ground cover at all, it is also the
  **stoniest**: it carries the catalogue's highest `rock_density`, and rocks are
  what fill a verge that would otherwise read as bare ([rocks.md](rocks.md)).
  It also overrides `tarmac_color` (a quite-a-bit-brighter,
  sun-bleached asphalt vs. home's darker grey), `road_marking_color` (yellow
  lane paint instead of home's off-white) and `grass_particle_color` (a dry
  olive/tan wheel-dust blade, since home's green particle would read as a
  mismatch on this arid ground). Terrain tints are still **not** overridden —
  Greece inherits the home tints. Its own `water_level` is `-12.0` (the same
  baseline as home — an unrelated corner, not "home but drier").
- `greece_coast` ("The Coast") — the arid shoreline look, worn today by a single
  rally on the SE sea:
  `look_from: "greece"` plus its own, higher `water_level` (`-5.0`), the same
  "same look, sea raised" pattern as `home_coast`.
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

**Where the look is applied depends on the world.** On a STAGE there is exactly one region, so
`world.gd::_apply_region_look` pushes it wholesale (see "How a look is applied" below). In the
**overworld** the player drives across all of them at once, so `Overworld._apply_region_look`
splits the look three ways: the sky cross-fades over TIME, the ground blends SPATIALLY at the
fixed boundary from a rank baked into the terrain, and the foliage/rock keys are read per chunk
as it is scattered. Two of the keys here therefore reach the ground shader twice over: every
region's `terrain_tint` and `tarmac_color` are uploaded together as a rank→look LUT
(`Overworld.region_look_lut`, `_push_region_lut`) so distant ground of ANY region paints in its
own colours, while `grass_texture` still cross-fades between only the two regions nearest the car
(a texture sampler cannot live in a uniform array). Both belong to the deleted overworld;
the split is recorded here because the LUT idea is the reusable half.

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
  `home_coast` / `greece_coast` is "same look, own waterline."

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
`water_level` — `home_coast` and `greece_coast` each author their own
`water_level` directly, rather than inheriting their parent's and needing a
separate override to raise it. If `water_level` were folded into the
inherited block, "same look, higher water" would need an override on top of
an inherited default, for no benefit.

### `look_from` — one-level look inheritance

This is the **authoring idiom for "region X, but different"** — reach for it
before copying a look block. A region may author
`"look_from": "<other_region_id>"` to inherit that
region's `LOOK_KEYS` block wholesale, instead of repeating it. `look_of`
resolves the parent's whitelisted keys first, then overlays the region's own
on top — so the region's own keys win over anything it also inherited.
Resolution is **exactly one level**: a parent's own `look_from` (if it had
one) is not followed, so chains and cycles are structurally impossible.

`home_coast` inherits `home`'s block; `greece_coast` inherits `greece`'s —
each then adds only its own higher `water_level` (handled outside `look_of`,
per above). `taiga` is the other pattern: `look_from: "home"` plus a single
overridden `tree_mix`, i.e. "home with taller trees" in two authored keys
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

Like `RallyLibrary`/`CarLibrary`, `RegionLibrary` sits behind a `Registry.Seam`
(`static var _seam := Registry.Seam.new(REGIONS)`) so tests can
`override_for_test(regions)` a synthetic catalogue and `reset()` after —
**never** pin the shipped `REGIONS` values or Greek asset paths in a test (see
CLAUDE.md's catalogue-testing rule).

### Helper API (all static, catalogue-driven)

- `all()` / `by_id(id)` / `index_of(id)` / `count()` — lookups.
- `region_for_rally(rally_id)` — looks the rally up in `RallyLibrary.all()`,
  returns the owning region dict (`.get("id")` for the id string; `{}` if the
  rally or its region tag is unknown).
- `rallies_in(region_id)` — the `RallyLibrary` entries tagged to this region,
  in author order.
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
`main.tscn`** (the floor's `chunk_material` shader params, the
`WorldEnvironment`'s sky), not in `GameConfig` fields. Merging against a
`GameConfig` baseline that doesn't hold those values wasn't possible; instead
`world.gd` applies overrides selectively, so home's un-overridden scene values
are the baseline by construction.

**One field has since moved to the merged model:** `sky_panorama` now HAS a
`GameConfig` baseline (`default_sky_panorama`) and is applied unconditionally,
because leaving the sky at "whatever the shared scene material currently holds"
leaked the previous stage's sky — see "The sky no longer leaks between stages"
below. Grass and gravel still follow the override-only rule.

## Rallies tagged by region

Every `RallyLibrary.RALLIES` entry carries `"region": "<region_id>"`. See
[rally-roster.md](rally-roster.md) for the roster itself and per-rally
`map_pos` / `special` geometric-reveal semantics.

**Regions are not quadrants, and membership is lopsided.** Pins are positioned by
`tools/fit_map_pins.py`, which optimises the PROGRESSION GRAPH, not the scenery — so
every re-fit slides pins across terrain zones and the geography under them has to be
re-read afterwards (the 2026-08 pass did exactly that: names, `region` tags and
per-event terrain were all re-authored to match the pixels, while the save-key `id`s
stayed put). A region tag says only "this stage wears this look at this waterline",
and the tags follow the terrain, so the split today is **14 `home`, 8 `greece`,
6 `snow`, 5 `taiga`, 4 `home_coast`, 1 `greece_coast`** — the five `taiga` rallies are
the NW cluster, re-tagged out of `home` when that corner was split off (their `id`s
still carry older prefixes, so read `region`, never the id); `greece_coast` is one rally on the SE sea, and
the coastal looks are worn only by the handful of pins genuinely standing on water
(the SE bay at a -4 waterline, the central rivers at -7). Nothing may assume a region
owns a contiguous patch of map, holds a minimum number of rallies, or holds any at
all.

**The old per-region invariant is retired.** Before globally-gated special
events, the rule was "at most one showdown per region, and exactly one wherever
a region holds rallies" (`RegionLibrary.showdown_of` picked that one rally out).
Specials are now gated by the same geometric reveal rule as every other rally
(`RallyLibrary.rally_revealed`), so they have no relationship to a region's
contents: **a region may hold any number of specials, including none.** Today
they are bunched — four sit in `home` and one in `greece`, with neither coastal
region holding any — precisely because nothing in the code cares; it's map
composition, not a gating rule. A region holding zero specials still resolves
its look/waterline normally.

`RallyLibrary.incomplete_rallies_enterable_by` (the anti-soft-lock query used
by the reward system) is no longer region-aware at all: a special is offered as
enterable once `RallyLibrary.rally_revealed` says so — and `rally_revealed` no
longer branches on `is_special` at all: EVERY rally reveals by the SAME
geometric test, its `map_pos` falling inside a lit circle, with no separate
completion count for specials at all. A pure position comparison, with no
region lookup in the path.

Non-special rallies reveal the same geometric way, and it is deliberately
**cross-region**: `RallyLibrary.rally_revealed` compares a rally's `map_pos`
against the lit circles of every completed rally on the WHOLE roster
(`lit_sources`), not just its own region's — the one world map pinned every region's
rallies at once, so "complete a rally in one corner to reveal one in another corner" was
the intended drip-feed, and a reveal scoped to one region would have cut that off at each
corner's border. **All of it is deleted** with the map; the roguelike unlocks whole
regions in a line instead (below).

## Theming the driven world (`world.gd._apply_region_look`)

Called from `_ready` immediately after `env.fog_sky_affect = cfg.fog_sky_affect`
(so it runs after the base environment is built, before the level otherwise
settles):

1. Resolve the driven stage's region — `RunSession.region_id()` when a REGION RUN is
   active, else `"home"`. A challenge stage is rolled from the period hash and authors no
   region, so it wears the plain home look; so does a dev boot of `main.tscn` with no
   session. Cached per world (`_region_look_cache`), since it cannot change mid-stage.

   > This hardcoded `"home"` from the stage-2 demolition until stage 9 — its comment said
   > the region-select system would give it a real answer, and stage 4 built that system
   > without coming back here — so **every region run was driven under the home palette,
   > sky and tree mix**. The HANDLING overrides were never affected: `StageConfig` reads
   > `event["region"]` off the drawn stage dict, which was always correct. Guarded now by
   > `test_world_fielding.gd`.
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

This is the single place the region look reaches the run scene; the rally
already carries its `region`, so no extra plumbing was needed into
`Config.data` or the scene tree.

## The world map is DELETED

There was a single world map texture (`textures/map_world.jpg`,
`RegionLibrary.DEFAULT_MAP_IMAGE`) on the HQ's 3D table, with every rally on the roster
pinned at its own `map_pos` and lit or greyed by a geometric reveal rule. The table, the
pins, the reveal parade and the map image's consumers all went with the diegetic hub
(decision 9).

What replaced it is a flat list: `HubShell`'s REGION page, showing every region in
AUTHORED order (`RegionLibrary.ordered()`), each marked cleared or named with its gate
([hub-shell.md](hub-shell.md)). **Regions unlock linearly now** (decision 12's
progression), which is a different rule from the map's geometry entirely — see below.

`map_pos` survives on every rally and is still authored, because the pin-fitting tool
(`tools/fit_map_pins.py`) and its solved positions are expensive to reproduce and a future
map screen would want them. Nothing reads it today.

## The snow corner (filled in)

The NE alpine corner was deliberately deferred when the four-corner map shipped — the map
asset was generated with all four visual corners baked in up front so terrain variety read
from the first minute, while the snow corner's content waited. It is now authored as the
`snow` region, and nothing in `RegionLibrary`, `RallyLibrary` or the HQ table had to
change to accept it: a new `REGIONS` entry with rallies simply started appearing as pins,
under the same geometric reveal rule as every other rally.

The one thing it DID add is the handling axis described above — the first time a region
influenced how a stage drives rather than only how it looks. See
[snow-region.md](snow-region.md).

## Progression: linear region unlock

- **Regions unlock in AUTHORED order.** Each `REGIONS` entry carries an `order` field;
  order 0 is always open and every other region is gated on the one before it appearing in
  `Save.KEY_REGIONS_CLEARED`. `RegionLibrary.order_of` / `ordered` / `is_unlocked` /
  `gate_for` are the whole API, and the REGION page prints the gate on a locked row rather
  than hiding it.
- **Array position carries no meaning** — that table's header says so explicitly. Read the
  `order` field; never the index.
- **A cleared region stays open and repeatable** (decision 12's grind valve), which is why
  `KEY_REGIONS_CLEARED` is a de-duplicated set of ids while
  `LifetimeStats.REGIONS_CLEARED_TOTAL` counts every completed run including repeats.
  Money scales with the region's order (decision 31), so grinding an early region pays
  worse per unit time than progressing — that is what stops "farm region 1 forever"
  without taking the valve away.

**What this replaced, all deleted:** the geometric reveal rule (`rally_revealed`,
`lit_sources`, comparing a rally's `map_pos` against the lit circles of every completed
rally), `all_specials_completed` and the global-completion credits beat, the per-region
showdown gates (`showdown_unlocked`, `all_showdowns_completed`, `showdown_of`,
`rally_showdown_gate_open`), and the star-total gates before them (`total_stars`,
`special_gate_open`, `stars_required`) plus the completion-count ladder that briefly
replaced those. `RegionLibrary` has no gating API left beyond the linear unlock above; its
other job is the LOOK (`look_of` / `water_level_of` / `surface_grip_of` / `deep_snow_of` /
`frozen_water_of` / `tree_mix` / `rock_density`).

## Tests

`tests/headless/test_region_library.gd` — grouping/derivation logic against a
**synthetic** region/rally set installed via `RegionLibrary.override_for_test`
(never the shipped Greek roster or textures): `region_for_rally`/`rallies_in`
round-trip, `look_of`'s override-vs-omit and
`look_from` inheritance behaviour, and `has_water_level`/`water_level_of`
with synthetic values. The `region` tag on every rally is asserted in
`tests/headless/test_rally_library.gd`. The linear unlock and its display (every region
listed in authored order, a locked row shown with its gate and unfocusable) are covered in
`tests/headless/test_hub_shell.gd`; the region-run draw that reads the tag is in
`tests/headless/test_region_stage_pool.gd`. That a driven stage wears its own region's
look is `tests/headless/test_world_fielding.gd`.
