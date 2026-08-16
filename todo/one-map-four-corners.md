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

## The snow corner — DONE

Shipped as the `snow` region ("The Alps"): six rallies in the NE massif, a snow look,
per-surface grip overrides, deep snow, frozen lakes and a snowfall condition. Two part
unlocks (Race Tires, Sequential Gearbox) moved there so the corner is worth working
toward. See [../features/snow-region.md](../features/snow-region.md) and
`docs/superpowers/specs/2026-08-16-snow-region-design.md`.

Note for anyone reading an older copy of this file: its guidance here referred to
`RegionLibrary.all_showdowns_completed`, `showdown_unlocked`, `showdown_of` and an
"empty-corner guard". **All of those were deleted** when region gating was retired —
regions gate nothing now, and the credits fire on `RallyLibrary.all_specials_completed`.
Adding the region needed none of that machinery.

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
