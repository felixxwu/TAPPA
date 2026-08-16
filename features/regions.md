# Regions

**Source:** `scripts/region_library.gd` (`RegionLibrary`), the `region` tag on
`RallyLibrary.RALLIES` (`scripts/rally_library.gd`), `world.gd._apply_region_look`
(and `_current_region_look`), and `hq.gd` (`_refresh_map_pins`, `_make_pin`).

A **region is a LOOK plus a WATERLINE** — sky, ground textures, foliage, sea
height — applied to whichever rallies are tagged with it. It is **not a corner
of the map**, even though it started life that way. The game ships five:
`home` (the original green forest/plain world), `home_coast` (that same look
with the sea raised), `greece` (arid), `greece_coast` (arid, sea raised) and `snow`
(the alpine NE massif — see [snow-region.md](snow-region.md)).

**A region is no longer look-only.** `snow` also carries HANDLING: per-surface grip
overrides, a deep-snow block and a frozen waterline. Those live OUTSIDE `LOOK_KEYS`
(exactly as `water_level` does) because they are consumed by
`RallySession.apply_event_config` at stage setup, not by `world.gd`'s look pass after
generation. Each is a `has_*` / `*_of` pair for the same value-vs-absent reason
`water_level_of` documents, and none is inherited through `look_from`.
Every rally is pinned on the one world map (`textures/map_world.jpg`, 848x848)
at once, and **regions do not unlock in sequence**: there is no "next region"
gate, and **no region-level gate of any kind** —
a region's only job is its LOOK and its `water_level`
(`RegionLibrary.REGIONS`'s header comment states this explicitly). Progression
gating now lives entirely in `RallyLibrary`, and it is **geometric, not a
counter**: a rally — ordinary or special, no distinction — becomes enterable
once the player's lit map reaches its `map_pos` (`RallyLibrary.rally_revealed`
/ `lit_sources`, one predicate for every rally — see
[map-exploration.md](map-exploration.md)). Specials used to gate on the
roster-wide STAR TOTAL, then on a global completed-rally counter
(`completions_required`); both were retired because a counter's unlocks had no
visible relationship to the rally just won, whereas a pin's position does. The
credits/win beat fires once **every** special event is completed
(`RallyLibrary.all_specials_completed`), not tied to any region — see
[rally-roster.md](rally-roster.md).

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
  the north, centre and east of the map. Authors its **foliage split
  explicitly** (`tree_mix` = 100% `res://textures/tree.png` at the home
  profile, `spawn_bush_mesh` = `true`) so the split is config-driven
  everywhere; every OTHER look field is left at the scene/`GameConfig`
  baseline, so the home world still looks byte-identical to before regions
  existed. Its `water_level` is the original baseline (`-12.0`).
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
  undergrowth). It also overrides `tarmac_color` (a quite-a-bit-brighter,
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
  `tree_mix` of two CC0 photographic conifers. `road_marking_color` is
  deliberately OMITTED rather than set to white — buried lane paint, not fresh
  paint. It is also the ONLY region carrying handling blocks
  (`surface_grip` / `deep_snow` / `frozen_water`); see
  [snow-region.md](snow-region.md).

Note on ids: `home` and `greece` were **not renamed** when the map went from
two swapped regions to four map corners, because `"home"` in particular is a
load-bearing literal hardcoded in `world.gd._current_region_look()` as the
default/challenge/fallback region id. Never rename it without also fixing that
call site (and auditing for other hardcoded `"home"` checks).

`LOOK_KEYS` is the whitelist of override fields a region may carry:
`sky_panorama`, `grass_texture`, `gravel_texture`, `tree_mix`,
`bush_billboard`, `spawn_bush_mesh`, `background_color`, `terrain_tint`,
`terrain_layers`, `tarmac_color`, `road_marking_color`,
`grass_particle_color`, `grass_particle_square`. `bush_billboard`/`terrain_tint`/`terrain_layers` are
reserved slots — schema support exists, nothing authors them yet.

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

A region may author `"look_from": "<other_region_id>"` to inherit that
region's `LOOK_KEYS` block wholesale, instead of repeating it. `look_of`
resolves the parent's whitelisted keys first, then overlays the region's own
on top — so the region's own keys win over anything it also inherited.
Resolution is **exactly one level**: a parent's own `look_from` (if it had
one) is not followed, so chains and cycles are structurally impossible.

`home_coast` inherits `home`'s block; `greece_coast` inherits `greece`'s —
each then adds only its own higher `water_level` (handled outside `look_of`,
per above).

`look_from` is itself deliberately **NOT** a `LOOK_KEYS` entry — if it were,
it would leak into the dict `world.gd` consumes as a real override field
(there being no `look_from` handling on the world-gd side, it would just sit
there inert at best, or collide with a real key at worst). It is read
directly off the region dict as plumbing, never through the whitelist.

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
and the tags follow the terrain, so the split today is **19 `home`, 8 `greece`,
6 `snow`, 4 `home_coast`, 1 `greece_coast`** — `greece_coast` is one rally on the SE sea, and
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
(`lit_sources`), not just its own region's. The one world map pins every
region's rallies at once, so "complete a rally in one corner to reveal one in
another corner" is the intended drip-feed — a reveal scoped to one region
would have cut that off at each corner's border. See
[map-exploration.md](map-exploration.md) (the reveal rule itself) and
[menus.md](menus.md) (the grey "coming up" pin).

## Theming the driven world (`world.gd._apply_region_look`)

Called from `_ready` immediately after `env.fog_sky_affect = cfg.fog_sky_affect`
(so it runs after the base environment is built, before the level otherwise
settles):

1. Resolve the driven rally's region — `region_id = "home"` if no
   `RallySession` is active, else
   `RegionLibrary.region_for_rally(RallySession.rally_id()).id`. Free roam has no
   session but picks a random location: when a free-roam car is set
   (`free_roam_instance_id >= 0` OR `free_roam_model_id != ""`) and
   `RallySession.free_roam_region_id` is set (`hq._prepare_free_roam` draws a
   uniform random id from the full `RegionLibrary.all()` roster — every
   authored corner, no unlock gating to worry about since there is none), that
   id is used. This resolution lives in `world.gd._current_region_look()`,
   shared by `_apply_region_look` (materials/sky/fog) and the foliage spawn
   (below).
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

## One world map, no table swap (`hq.gd`)

There is a single world map texture, `textures/map_world.jpg`
(`RegionLibrary.DEFAULT_MAP_IMAGE`), loaded once by `hq.gd._refresh_map_pins`
and never swapped. Every rally on the whole roster — every region — gets a
pin on it at the same time, positioned by its own `map_pos` (normalised 0..1,
solved by `tools/fit_map_pins.py` against the progression graph — not confined
to any region's patch of the image). `_make_pin` builds every
pin's marker, readout label and hit targets the same way regardless of
region; the only per-pin state is:

- **locked** (`not RallyLibrary.rally_revealed(rally, Save.profile)`) — the
  rally's `map_pos` doesn't yet fall inside any lit circle (one geometric
  predicate for every rally, special or not — see
  [map-exploration.md](map-exploration.md)). A locked pin renders grey,
  carries no hit spheres (can't be clicked/entered), and drops its readout box
  entirely — except a locked SPECIAL, which keeps a full-opacity non-pickable
  teaser naming what it unlocks (`hq._build_special_teaser_label`). Either way
  it's a "coming up" hint, not a hidden pin: locked rallies are still pinned
  and visible; they are simply not enterable yet.
- earned stars / eligible-car state, same as always (`RallyFlag.build`).

The table also carries **one non-rally target**: the **present box** that
trades stars for a car (`hq._make_present_pin`, at `hq.PRESENT_MAP_POS`). It
belongs to no region and needs none — it is deliberately parked near the
map's CENTRE rather than in any corner, so it reads as a facility rather than
another corner's content. See [menus.md](menus.md) → TABLE and
[star-economy.md](star-economy.md).

None of the old per-region table state exists any more: there is no
`_viewed_region_index`, no `_swap_region`, no `_furthest_unlocked_index`, and
`hq_environment.gd` builds no arrow props (no `arrow_left`/`arrow_right`,
no "CHANGE MAP" labels, no `_on_arrow_input`) — the whole diegetic
region-swap mechanism described in older versions of this doc is deleted.
Camera glide + nearest-to-centre selection (`_pan_table_step`,
`_select_target_under_center`) is unchanged and now simply operates over the
one map's full pin set instead of a per-region subset — see
[menus.md](menus.md) → TABLE for the pan/select/enter flow, which this section
no longer needs to distinguish from a "swap" mode.

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

## Progression: no sequence, no region gating, geometrically-gated specials

- **No unlock sequence.** There is no derived-or-stored "region unlocked"
  concept any more — every authored region is reachable from the start.
  `RegionLibrary.unlocked` no longer exists; do not reintroduce it.
- **No region gating at all.** Regions used to gate their own showdown
  (`RegionLibrary.showdown_unlocked` scoped per region) and the credits fired
  once every region's showdown was won (`all_showdowns_completed`). Both of
  those, plus `showdown_of` and `rally_showdown_gate_open`, are **deleted** —
  `RegionLibrary` no longer has any gating API. A region's only remaining job
  is `look_of` / `water_level_of`.
- **Geometrically-gated specials.** `hq.gd` and `reward_system.gd` read
  `RallyLibrary.rally_revealed`, which compares a special's `map_pos` against
  the lit circles of every completed rally on the roster, exactly like any
  ordinary rally — no region lookup anywhere in the path, and no completion
  counter or star total either: `total_stars` / `max_total_stars` /
  `special_gate_open` / `stars_required` / `stars_needed` are **deleted**, and
  so is the completion-count ladder that briefly replaced them
  (`completions_required` / `completions_needed`). Stars are now a spent
  balance, and a gate reading a balance would close behind a player who had
  already passed it — see [star-economy.md](star-economy.md).
- **Global-completion credits.** `rally_session.gd` emits `RallySession.game_won`
  (renamed from `showdown_won`) when `RallyLibrary.all_specials_completed(profile)`
  is true — every special on the roster completed, regardless of which region
  it sits in. Region ORDER carries no meaning; there is no "final region." A
  special win that still leaves another special outstanding just completes
  like any other rally: it records completion/best-placement and pays the
  placement's **stars** into the ledger (specials pay them too now — they used
  to pay nothing, which made the prestige events the least rewarding on the
  map). No rally hands over a car any more; cars are bought with those stars at
  the map's present box. See [star-economy.md](star-economy.md),
  [rally-session.md](rally-session.md),
  [reward-system.md](reward-system.md) and [rally-roster.md](rally-roster.md).

## Tests

`tests/headless/test_region_library.gd` — grouping/derivation logic against a
**synthetic** region/rally set installed via `RegionLibrary.override_for_test`
(never the shipped Greek roster or textures): `region_for_rally`/`rallies_in`
round-trip, `look_of`'s override-vs-omit and
`look_from` inheritance behaviour, and `has_water_level`/`water_level_of`
with synthetic values. The geometric reveal rule (`rally_revealed`,
`lit_sources`) and `all_specials_completed`, plus the `region` tag
on every rally, are asserted in `tests/headless/test_rally_library.gd`. The
map's pin set (every region's rallies pinned at once, locked pins
non-pickable, keyboard + gamepad reachable) is covered in the HQ nav tests
(`tests/headless/test_menu_nav.gd` / the nav cases in `test_menu_flow.gd`). The
reward system's region-aware draw-walk is covered in `test_reward_system.gd`.
