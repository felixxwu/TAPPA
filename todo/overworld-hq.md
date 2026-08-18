# Overworld HQ — what's left

**The feature has SHIPPED**, behind `GameConfig.overworld_enabled` (authored `false`). Reach it
from Settings → Dev → "Enter the Overworld HQ".

[../features/overworld.md](../features/overworld.md) is the living doc — read that for how it
works. The design record, including every place the design turned out to be wrong, is
`docs/superpowers/specs/2026-08-17-overworld-hq-design.md`. This file is only what is still open.

## Needs a decision with it on screen

These are all "drive it and see", not analysis:

- **Is 4 km right?** `GameConfig.overworld_size_m`. 38 rallies average ~450 m apart at this
  scale, which may read as a diorama rather than a country. Cost scales with the square, and it
  is in the cache key, so a change means a full re-warm.
- **`overworld_load_radius` and `overworld_chunk_build_budget` are provisional.** A 21×21 window
  is ~441 spawned chunks — on the order of 2,600 `MeshInstance3D` plus 441 heightfield shapes.
  That budget was reasoned about, **never measured**. Measure it and size both knobs from the
  measurement; `TerrainManager.cache_size_mb()` and the `terrain stream-on-miss:` log are the
  hooks (the latter firing at all means the window or the store is undersupplied).
- **First-launch precompute wall-clock.** 6,400 chunks behind a loading screen. Measured and
  printed, never asserted. If it is intolerable, `overworld_size_m` is the lever.
- **Does the spinning icon card read well?** It is a double-sided quad, so it goes edge-on twice
  per turn. Alternatives: billboard it and spin in-plane, or give it thickness.
- **What happens past the coast.** The taper handles the visible border, but nothing stops a
  determined player driving out to sea indefinitely — beyond the map the cache has no chunks and
  heights fall back to noise. Either extend the taper to a hard floor and let the sea answer it,
  or respawn on shore after a distance.

## Unimplemented beats

- **The reveal parade has no overworld equivalent.** `RallySession.return_to_map` is *dropped*
  with a log on overworld boot. The natural version is a flourish on the newly-lit zones as the
  player arrives, which is nicer than the table's parade and is the reason it was not faked.
- **The present box has no overworld equivalent.** `pending_car_reveal_instance_id` is likewise
  dropped. The prize car is already GRANTED before this point, so nothing is lost but the
  presentation.
- **Region look snaps** on crossing instead of cross-fading. A real blend needs a custom sky
  shader mixing two panoramas by weight — note the `PanoramaSkyMaterial` is a shared
  sub-resource with no `resource_local_to_scene`, which is why `_apply_region_look` assigns it
  unconditionally.
- **No HUD.** A stage HUD has nothing to read out here, but a compass/minimap is the wayfinding
  answer (see below) and would live in the same place.

## Known limitations worth not rediscovering

- **Threading is unsafe, not merely unused.** Chunk building reads shared `_vc*` scratch fields
  on the `TerrainManager`, so a worker-thread build corrupts them **on every platform** — not
  just single-threaded web. Give each worker its own scratch before attempting it. The per-frame
  build budget is what carries the load today.
- **The disk cache is off on web and headless.** `user://` on web is IndexedDB, shares its quota
  with `profile.json`, and there is no quota detection anywhere; ~83 MB is too much to risk
  starving the save. `GameConfig.overworld_cache_active_for(web, touch)` is the resolution point.
- **The baked per-vertex light is computed from the UNTAPERED field**, so the beach shades as
  inland noise would. Shading only — collision, the mesh and `height_at` all agree. Documented in
  `terrain_manager.gd` where the taper is applied.
- **Coarse (`stride > 1`) chunk builds are untapered.** Unreachable today because `chunk_class`
  returns full-res for every chunk in bounded mode, so pruning is inert in an open world where
  the player can reach anywhere.

## Wayfinding is the biggest gameplay gap

The spec calls this a slice-2 requirement and it is only *partly* met: zones are enumerable
(`OverworldZones.zones()` / `zone_for`), and markers make a zone legible once you can see it —
but in a 16 km² world with a 640 m lit radius there is still nothing that tells the player which
way to go. The map table's pin labels, star readouts and `_focus_hardest_incomplete` entry steer
have no counterpart. A compass to revealed zones, or a minimap, is the missing piece.

## Testing

Covered by `test_overworld.gd`, `test_overworld_zones.gd`, `test_overworld_cache.gd`,
`test_overworld_terrain.gd`, plus additions to `test_smoke.gd`, `test_music_library.gd` and
`test_music_director.gd`.

**`overworld.tscn` has a cheap path and any new test must use it** —
`Overworld.load_mode = Overworld.LoadMode.CHEAP` before instancing (AUTO already resolves to
CHEAP under `--headless`). Full generation over 16 km² would blow the suite's ~5 minute budget on
its own. Restore the static afterwards.

Not covered, and why: the ghost-car cap and "exactly one frozen ghost" need a real `car.tscn`
instantiation (the expensive path the spec itself calls unaffordable); the fog push-back veil is
defined by tunables and needs real physics frames; the taper's magnitudes, the dwell duration and
every other tunable are deliberately unpinned per `CLAUDE.md`.
