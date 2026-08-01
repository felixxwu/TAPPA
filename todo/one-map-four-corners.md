# One Map, Four Corners — remaining work

**The main change has SHIPPED.** The HQ map table is one world map
(`textures/map_world.jpg`) with every rally pinned on it at once, the per-region
swap arrows are gone, and `RegionLibrary.REGIONS` authors four corner regions
(`home`, `home_coast`, `greece`, `greece_coast`) that own both their look and
their waterline. See [../features/regions.md](../features/regions.md) and
[../features/rally-roster.md](../features/rally-roster.md) for how it actually
works — those are the living docs now, and this file is only what's still open.

What's left is the **snow corner**, which was deferred from the start because it
is the one look that can't be produced by re-mixing existing art.

## Follow-up: the snow corner

Snow is the one look the game genuinely doesn't have — unlike "coastal", it can't
be produced by re-mixing what's authored, because nothing in the roster reads as
frozen. Deliberately deferred so the map change wasn't blocked on art.

**The corner already exists on the shipped map**; it just holds no pins. The NE is
reserved for it and nothing has to be displaced. So the follow-up is purely:
author the look, then site rallies there and give them `reveal_after` slots on the
ladder. No map regeneration and no `map_pos` churn for existing rallies — which is
the main reason deferring it was cheap.

The map's NE corner was also given a proper alpine massif (large ridgelines, snow
on the crests, rock scoured off the steep faces) — see `tools/gen_map_texture.py`
→ `alpine_gate` / `ridged_big`. So the terrain is already there to sell a snow
region; only the *driven-world* look is missing.

### What authoring it involves

It slots in as a **fifth region** in `RegionLibrary.REGIONS` alongside the four
that exist. Greece's entry is the template for how much a region needs:

| `LOOK_KEYS` field | snow region |
| --- | --- |
| `sky_panorama` | overcast / alpine sky |
| `grass_texture` | snow / patchy alpine ground |
| `gravel_texture` | grit / packed snow |
| `tree_mix` | conifers — a new billboard, and a sizing `profile` (see `DEFAULT_TREE_MIX`) |
| `terrain_tint`, `background_color` | cooler cast |

Because a region owns its waterline as well as its look, the snow region also
multiplies against that axis — an alpine-lake corner comes free once the look
exists, via a `look_from` child with a higher `water_level` (the same trick
`home_coast` uses).

### Things to get right when it's picked up

- **It gains its own showdown**, taking the count from four to five. Nothing
  special is needed for the ending: `RegionLibrary.all_showdowns_completed` counts
  every region, so adding one simply raises the bar. Note this makes an
  already-finished save read as unfinished again — correct for a content update,
  but don't mistake it for a regression.
- **Until it has rallies, the empty-corner guard is what protects it.**
  `RegionLibrary.showdown_unlocked` rejects a region that authors no non-showdown
  rallies; without that, an empty corner's showdown would read as unlocked
  immediately, because the "all rallies completed" loop passes vacuously over zero
  rallies. That guard exists *for* this deferral — don't remove it when adding the
  region, and keep its test.
- **Grip is a bigger question than the textures.** Snow implies a surface that
  drives differently, but `surface_mix` is authored per event and `LOOK_KEYS` is
  look-only, so a genuinely icy region would be the first case where a region wants
  to influence *handling*, not just appearance. Worth scoping deliberately rather
  than smuggling in.
- **Rally placement.** Pins must sit on land, on region-appropriate terrain, inside
  roughly `[0.045, 0.955]` on both axes (the map plane is 4.2 x 4.2, so the extremes
  crowd the table rim), and no closer together than the existing roster's ~0.05
  spacing. `features/rally-roster.md` documents the rules and the verification
  approach.

## Also outstanding: catalogue fields for richer rally classes

Surfaced while authoring the 28-rally roster, and following the standing rule in
`features/rally-roster.md` (**when a rally wants to group cars by a property the
catalogue doesn't record, add the property to the definitions — never approximate
it with a proxy that happens to correlate**):

- **`aspiration`** (NA / turbo / supercharged) on `EngineLibrary.ENGINES` — would
  unlock "naturally aspirated only" style classes. It belongs on the engine, not
  the car, so an engine swap changes eligibility (the same reasoning that put
  `displacement_l` there).
- **`era` / `decade`** on `CarLibrary.CARS` — would unlock period events. A body
  property, so it belongs on the car.
- **A genuine kei event isn't viable yet**: `car_type: "kei"` currently picks out a
  single car, so `hc_lakeside_kei` is authored as a Japanese national class
  instead. It becomes viable once the roster carries more kei entries.

Each new restriction field needs **two** text surfaces, and it's easy to add only
the first: a branch in `RallyLibrary.ineligibility_reason` (why a specific car was
rejected) *and* an entry in `hq.gd._restriction_text` (how the restriction itself
reads in the detail panel). A field missing from the second is silently absent from
the rally's description.

Use `./report_eligibility.sh` when authoring — it reports eligible cars per rally
through the real `RallyLibrary.is_eligible` predicate. Target 2-3 eligible cars per
rally, with ~2 acceptable and a hard floor of ≥1.
