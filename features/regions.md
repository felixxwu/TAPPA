# Regions

**Source:** `scripts/region_library.gd` (`RegionLibrary`).

**Tests:** `tests/headless/test_region_library.gd`, `tests/headless/test_region_assets.gd`,
`tests/headless/test_region_docs.gd` (every region id below must appear in this file).

A region is an authored **look** (sky, ground textures, tree species, particle colours).
Regions came from the procedural island's biome
rings, which were deleted in the Hafren-only cleanup of November 2026 (in git history). The
Hafren level is one authored place, so today almost all of the table is unread: see
"What the live game reads" below before building on any of it. The level's snow is its own
biome map, not this table ([snow-region.md](snow-region.md)).

The game ships five: `home` (the original green forest), `greece` (arid: its own sky, grass,
gravel and a Mediterranean tree), `taiga` (home's look with a much taller spruce),
`home_coast` (home's look) and `snow` (snow ground, sky and conifers).

## What the live game reads

Exactly one call: `level_view.gd` → `LevelView._add_effects` resolves
`RegionLibrary.look_of("home")` and hands that look to the car's driving effects:

- `wheel_particles.gd` → `WheelParticles.apply_region_look` reads `grass_particle_color` and
  `grass_particle_square` (the off-road debris colour and shape).
- `dust_puffs.gd` → `DustPuffs.apply_region_look` reads `dust_color` (the gravel dust colour).

`home` authors none of those three keys, so both fall back to their `GameConfig` defaults.
After boot, `LevelView._timed_physics_process` calls `DustPuffs.apply_region_look` every
physics tick with a synthetic `{"dust_color": ...}` look (`LevelView.snow_dust`, lightened by
the snow under the car), not a region's.

Snow handling does not read a region either: `LevelView.set_snow` reads the `snow_*`
`GameConfig` fields directly and blends them by `LevelStreamer.snow_at`.

Hafren's sky, fog and ground come from the level scene and the bake, its trees from
`LevelTrees` (species set per level in the editor, see [level-editor.md](level-editor.md)),
and its weather from `LevelWeather` ([weather.md](weather.md)). None of those read a region.

## `RegionLibrary` (`scripts/region_library.gd`)

An authored catalogue, `const REGIONS: Array[Dictionary]`, behind a `Registry.Seam` like
`CarLibrary`, so tests install a synthetic set with `override_for_test(regions)` and `reset()`
after. Never pin the shipped regions' values or asset paths in a test (see CLAUDE.md).

An entry has an `id`, optional look keys (a missing key means "keep the baseline") and an
optional `look_from`.

- **`LOOK_KEYS`** is the whitelist `look_of` returns: `sky_panorama`, `grass_texture`,
  `gravel_texture`, `tree_mix`, `bush_billboard`, `spawn_bush_mesh`, `background_color`,
  `terrain_tint`, `grass_particle_color`, `grass_particle_square`, `dust_color`.
- **`look_from`** is the authoring idiom for "region X, but different": author
  `"look_from": "<other id>"` plus only the keys that differ (`taiga`, `home_coast`). `look_of`
  resolves the parent's keys, then overlays the region's own. Exactly one level deep, so
  chains and cycles cannot happen. `look_from` is not a look key and never appears in the
  result.
- **Never invent an asset filename.** Every `res://` path a region authors must exist; a
  dangling one loads as null. Guarded by `test_region_assets.gd` →
  `test_every_authored_region_resource_path_resolves`.
- **`"home"` is load-bearing**: `LevelView._add_effects` asks for it by id. Do not rename it.

### Helper API (all static)

- `all()` / `by_id(id)` / `index_of(id)`: lookups.
- `look_of(region_id)`: only the `LOOK_KEYS` the region (and its `look_from` parent) authors,
  not a dict merged against the baseline. Callers check each key and keep their own default
  when it is absent.
- `tree_mix(look)`: the look's `tree_mix`, or `DEFAULT_TREE_MIX` (one home `tree.png`) when
  it has none. Each species is `{texture, profile, weight}` plus an optional `size_scale`.
- `spawns_bush_mesh(look)`: the `spawn_bush_mesh` flag, default `true`.

## Adding a region

1. Add a row to `RegionLibrary.REGIONS` (list `textures/` and use real files).
2. Mention its id in backticks in the list near the top of this file and update the count;
   `test_region_docs.gd` fails otherwise.

Nothing on Hafren will show it until something live reads it.
