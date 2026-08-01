# One Map, Four Corners

**Status:** planned. Replace the per-region map swap on the HQ table with a
**single map whose four corners are the regions**, so the game's terrain variety
is visible from the first minute instead of hidden behind the table's swap
arrows until a region's showdown is beaten.

**Why:** regions currently bundle two unrelated jobs — *visual variety*
(`RegionLibrary.look_of` → `world.gd`) and *progression gating*
(`RegionLibrary.unlocked`, sequential showdown chain). Only the first makes the
game feel bigger; the second is what hides it. The complaint that motivated this
is that a player can't tell another region even exists. Making the arrows more
obvious would fix that alone, but not the second half of the problem — the
variety being locked away for hours. Corners fix both.

**The key move:** don't drop the reveal, move it from "region is locked" to
"pins aren't there yet". `RallyLibrary.rally_revealed` (`scripts/rally_library.gd`,
`rally_revealed` / `_completed_in_region`) already drip-feeds pins by completed
count. So the sandy corner is *visible* on day one and its pins arrive on a
schedule — aspirational rather than invisible.

## Already done

- `textures/map_world.jpg` — 848x848 single-world map, four corners
  (NW forest / NE snow / SW arid / SE coast + islands), palette-matched to
  `map_table.jpg`. No drawn borders; terrain alone delineates the regions.
- `tools/gen_map_texture.py` — the generator. `--seed` re-rolls terrain while
  keeping each region in its corner; `CORNERS` sets the influence centres,
  `ISLANDS` seeds the SE archipelago. See [../features/regions.md](../features/regions.md)
  → "Single-world map asset".

**Nothing references the texture yet.** The game still behaves exactly as before.

## Open design questions (resolve before implementing)

### 1. Four corners, but only TWO authored looks — the real scope question

This is the biggest open item and it is **not** a code problem. The map texture
shows four corners, but `RegionLibrary.REGIONS` (`scripts/region_library.gd`)
authors only `home` and `greece`. A snow corner and a coastal corner need their
own driven-world looks, and each look means art:

| `LOOK_KEYS` field | snow corner | coast corner |
| --- | --- | --- |
| `sky_panorama` | overcast/alpine sky | bright maritime sky |
| `grass_texture` | snow / patchy alpine ground | dry coastal grass |
| `gravel_texture` | grit / packed snow | sand-flecked gravel |
| `tree_mix` | conifers (new billboard + sizing profile) | sparse palms / low coastal scrub |
| `tarmac_color`, `road_marking_color` | — | — |
| `grass_particle_color` | — | — |

Greece is the template for how much a region needs (see its entry in
`region_library.gd`). Options:

- **(a) Two corners now, two later.** Site rallies only in the forest + arid
  corners at first; the snow and coast corners are terrain on the map with no
  pins yet. Ships the discoverability win immediately and defers the art. The
  empty corners read as "not here yet", which is exactly the aspirational
  framing this change is going for.
- **(b) Author all four up front.** Bigger, blocked on producing/sourcing
  ~8 textures + 2 sky panoramas + conifer/palm billboards.

**Recommendation: (a).** It decouples the code change from the art, and the
map already communicates that the other corners exist. Decide this first —
it sets the size of everything below.

### 2. The showdown collapse

Today the invariant is **one showdown per region** (`scripts/rally_library.gd`
header comment `:99-100`; asserted in `test_rally_library.gd`), home's
showdown unlocks Greece, and only the final region's showdown fires credits
(`scripts/rally_session.gd:505`, `RegionLibrary.is_final`). With one map that
has to collapse to **one global showdown**. Either:

- `the_showdown` stays the finale and `gr_showdown` ("The Aegean Crown") becomes
  a regular high-tier rally; or
- they merge into a single finale sited in the toughest corner.

**Recommendation:** one finale, everything else a regular rally on one
continuous ladder. Note `RallyLibrary.showdown_unlocked(profile)`
(`scripts/rally_library.gd:765`) is the **pre-region global predicate and is
still present** — currently referenced only by `test_rally_library.gd:754-759`,
i.e. dead production code. This change reinstates it as the live one.

### 3. Does `reveal_after` stay per-region or become global?

`rally_revealed` counts completions **in the rally's own region**
(`_completed_in_region`, `scripts/rally_library.gd:737`). With one map:

- **Per-region (unchanged):** each corner drip-feeds independently. But every
  corner's `reveal_after: 0` rallies are revealed from the start — with today's
  data that means `gr_olive_coast` is visible immediately alongside the home
  starters, so the corners no longer come online in any order.
- **Global:** count all completed rallies, and author one ladder across the
  whole map (e.g. forest 0/0/0/2, arid 3/5, snow 6/8, coast 9/11). Corners come
  online in sequence *while remaining visible throughout* — which is the whole
  point of the change.

**Recommendation: global.** Rename `_completed_in_region` → `_completed_count`
and drop its `region_id` argument.

### 4. Keep the explicit `region` tag on rallies?

**Yes — recommended.** Keep `"region": "<id>"` on each `RallyLibrary.RALLIES`
entry and just move its `map_pos` into the matching corner. Deriving the region
from `map_pos` coordinates would couple look selection to pin geometry and break
silently when a pin is nudged. Keeping the tag also means **`world.gd` needs no
changes at all** — `_current_region_look()` / `_apply_region_look` resolve from
the rally's tag and are entirely unaffected by how the table displays things.

### 5. Corner → rally assignment

13 rallies exist today (9 `home` + 4 `greece`). All need new `map_pos` values in
`textures/map_world.jpg`'s coordinate space. A starting point, to be steered:

- **NW forest** (`map_pos` ~x 0.05-0.45, y 0.05-0.40): the home starters —
  `shakedown`, `front_runners`, `shitbox_cup`, `coastal_sprint`.
- **SW arid** (~x 0.05-0.45, y 0.60-0.95): the Greek roster — `gr_olive_coast`,
  `gr_mountain_pass`, `gr_ancient_ruins`.
- **NE snow** (~x 0.60-0.95, y 0.05-0.40): `rwd_masters`, `rising_sun`,
  `grand_tour`.
- **SE coast** (~x 0.60-0.95, y 0.60-0.95): `american_muscle`, plus the finale.

Sanity-check pin spacing against `cfg.hq_map_plane_size` (4.2 x 4.2,
`scripts/game_config.gd:856`) before committing values — 3-4 pins per corner
should not overlap their name/star boxes.

Note this cuts across question #1: under option (a) only the forest and arid
corners get pins in the first pass.

## Code touchpoints

### `scripts/hq.gd` — delete the swap machinery

- `_viewed_region_index` (`:270`), `_viewed_region_id()` (`:668`),
  `_furthest_unlocked_index()` (`:660`), `_swap_region()` (`:697`),
  `_update_region_arrows()` (`:676`), `_on_arrow_input()` (`:705`),
  `_set_viewed_region_for_test()` (`:712`) — all delete.
- `_build_arrow_label()` (`:840`) / `_set_arrow_label()` (`:848`) — delete.
- `_refresh_map_pins()` (`:631`) — build pins from `RallyLibrary.all()` instead of
  `RegionLibrary.rallies_in(region_id)`; load the map texture once from
  `RegionLibrary.DEFAULT_MAP_IMAGE` (repointed, see below) rather than per-region
  `look_of(...)["map_image"]`; drop the `_update_region_arrows()` call.
- `_build_table_targets()` (`:2245`) — drop the two arrow entries (`:2249-2252`).
- `_activate_table_focus()` (`:2410`) — drop the `"arrow_left"` / `"arrow_right"`
  cases (`:2418-2430`) and the `_focus_nearest_pin` re-seat they trigger.
- `_refresh_meter()` (`:940`) — scope the progress meter to all rallies, not
  `RegionLibrary.rallies_in(_viewed_region_id())`.
- `_ready` (`:564`, `:569`) — stop passing `_on_arrow_input` into `_env.build`;
  delete the `_viewed_region_index = _furthest_unlocked_index()` seed.
- `_prepare_free_roam` (`:2203-2205`) — **leave alone.** It draws a random region
  id for the free-roam look from the full roster; unaffected.

### `scripts/hq_environment.gd` — delete the arrow props

- `arrow_left` / `arrow_right` (`:23-24`), `_build_map_arrow()` (`:369`),
  `_build_arrow_mesh()` (`:399`), the two construction calls (`:361-362`) and the
  `edge` local (`:360`).
- Drop the `on_arrow_input` parameter from `build()` (`:29`) and
  `_build_map_table()` (`:87`, `:315`).
- `map_plane`'s initial texture (`:334`) still loads `map_table.jpg` directly —
  repoint to `map_world.jpg`.

### `scripts/region_library.gd`

- `DEFAULT_MAP_IMAGE` (`:11`) — repoint to `res://textures/map_world.jpg`.
- `map_image` in `LOOK_KEYS` (`:14`) and Greece's `map_image` entry — remove;
  there is one map now.
- `unlocked()` (`:113`) — delete (its only callers are the `hq.gd` arrow code and
  the `showdown_unlocked` guard).
- `is_final()` (`:93`) — delete; see `rally_session.gd` below.
- `showdown_unlocked(region_id, profile)` (`:122`) and
  `rally_showdown_gate_open()` (`:141`) — collapse to the global
  `RallyLibrary.showdown_unlocked(profile)`.
- KEEP `look_of`, `tree_mix`, `spawns_bush_mesh`, `region_for_rally`,
  `rallies_in`, `all`/`by_id`/`index_of`/`id_at`, and the `Registry.Seam`. The
  catalogue keeps its look-override job untouched.

### `scripts/rally_library.gd`

- `_completed_in_region()` (`:737`) → global count (per question #3).
- `rally_revealed()` (`:755`) — showdown branch calls
  `RegionLibrary.rally_showdown_gate_open` (`:757`); repoint to the global
  predicate.
- `showdown_unlocked(profile)` (`:765`) — becomes live production code again.
- The per-region showdown invariant in the header comment (`:99-100`).
- Every entry's `map_pos`, and `reveal_after` re-authored as one ladder.

### `scripts/rally_session.gd`

- `:505` — `is_final_showdown` currently `showdown and RegionLibrary.is_final(region_id)`;
  becomes just `bool(_rally.get("showdown", false))`. Update the `:511-513`
  comment about non-final showdowns unlocking the next region.

### `scripts/reward_system.gd`

- `_unlock_candidates()` (`:235`) reaches `rally_revealed` / the showdown gate
  indirectly — no direct `RegionLibrary` call, so it should need **no change**
  beyond following the predicates above. Verify with `test_reward_system.gd`.

### Dev cheats

- `Save.dev_three_star_all_rallies()` (`scripts/save_manager.gd:917`) and
  `settings_menu.gd._three_star_all_rallies()` (`:689`) still work, but their
  comments and the "all regions unlocked" status string (`:691`) reference region
  unlocking that no longer exists — reword.

## Tests

Per CLAUDE.md, none of these may pin authored values — assert the logic.

- `tests/headless/test_menu_flow.gd` — delete the arrow nav cases
  (`:486-508` right-arrow focus + swap, `:535-542` arrow visibility, `:566-587`
  locked forward arrow). Update `:173` (pin count vs
  `RegionLibrary.rallies_in(hq._viewed_region_id())`) to assert against the
  revealed set of `RallyLibrary.all()`.
- `tests/headless/test_menu_nav.gd` — drop arrow targets from the table nav cases;
  keep the glide + nearest-to-centre selection coverage, which is unaffected.
- `tests/headless/test_region_library.gd` — delete `test_is_final_only_last`,
  `test_first_region_always_unlocked`, `test_unlock_chain_from_prev_showdown`,
  `test_per_region_showdown_gate_is_independent`. Keep the `look_of` /
  `tree_mix` / `spawns_bush_mesh` / grouping cases.
- `tests/headless/test_rally_library.gd` — per-region showdown invariant becomes
  "exactly one showdown globally"; `:754-759` already covers the global
  `showdown_unlocked`.
- `tests/headless/test_reward_system.gd` — re-run the region-aware draw-walk cases
  against the global gate.
- **New:** a rally-roster invariant that every `map_pos` lies in `[0,1]²` and no
  two pins are closer than some small epsilon — catches a corner re-site
  accidentally stacking pins. (Positions are authored data, so assert
  *well-formedness*, never specific coordinates.)

Blast radius is wide (HQ scene construction, rally gating, reward draw), so this
one warrants a **full `./run_tests.sh`** rather than a targeted subset.

## Docs to update in the same piece of work

`features/regions.md` (the swap section and the "not yet wired up" note),
`features/menus.md` (TABLE nav — arrows gone), `features/rally-roster.md`
(`reveal_after` semantics), `features/rally-session.md` +
`features/reward-system.md` (showdown/credits gating), and
`features/save-persistence.md` (derived region unlock disappears).

## What is deliberately NOT changing

- `scripts/world.gd` — `_current_region_look()`, `_apply_region_look`, the
  `tree_mix` foliage split, and the road-paint override all key off the rally's
  `region` tag and are untouched. **All the visual variety is preserved.**
- Free roam's random region draw (`hq.gd:2203-2205`).
- `RegionLibrary`'s `Registry.Seam` test override, and the rule that tests never
  pin shipped region values.

## Known cost

Losing the "a whole new country opened up" beat. The visible-corner approach
recovers most of it — you can see where you're headed — but not all of it. This
also caps how far variety can stretch: green + sandy + alpine + coastal on one
landmass is plausible; a fifth wildly different biome would strain it. That is
recoverable, though — a second map table with the swap arrows could return later
*on top of* corner variety within each map, so this change doesn't foreclose it.
