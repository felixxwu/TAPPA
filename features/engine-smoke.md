# Engine Smoke

**Source:** `scripts/engine_smoke.gd` (`EngineSmoke`, `extends CpuParticlePool`).

**Tests:** `tests/headless/test_engine_smoke.gd`

Grey smoke that puffs from the bonnet each time a **damaged engine misfires** — a
visual companion to the [damage misfire](damage.md) fuel cut. Since the misfire only
fires below `damage_misfire_health_threshold`, a healthy car emits no smoke for free
(no cuts → no puffs), and the smoke naturally thickens as damage worsens (more cuts).

## How it works

`EngineSmoke` is a hand-rolled **CPU particle pool** drawn through **one MultiMesh**
of billboarded quads — the same cheap pattern as [`WheelParticles`](wheel-dust.md)
(the `gl_compatibility` renderer has no GPU-particle physics), but with its **own
small pool** (`engine_smoke_max`, default 48), separate from the wheel dust. One draw
call, a fixed instance count, a **ring buffer** that recycles the oldest slot so cost
is hard-capped. The ring-buffer machinery (parallel `_pos`/`_vel`/`_life` arrays, the
`_next` cursor, `_clear()`, `warm_up()`/`clear_warm_up()`, `_emit_slot()`, and the
`live_count()`/`max_particles()` readouts) is shared with the wheel dust via the
common `CpuParticlePool` base — see [wheel dust → shared pool base](wheel-dust.md).
`EngineSmoke` supplies its own `STRIDE` (16, for TRANSFORM_3D + COLOR), the
grow/fade slot writer (`_write_slot`), an extra `_max_life` array for the fade
fraction, and its misfire emission.

Like the wheel dust, it exposes `warm_up(pos)` / `clear_warm_up()` so
`world.gd._generate_track` can compile its shader variant behind the loading
overlay instead of hitching on the first misfire — see
[wheel-dust.md → Shader warm-up](wheel-dust.md).

- **Trigger — a puff per cut.** `EngineSim` keeps a monotonic `misfire_count`,
  incremented on each *misfire* cut onset (not the rev limiter). Each physics tick
  `EngineSmoke` reads the count and puffs one burst (`engine_smoke_per_cut`
  particles) for every new cut since last tick, capped at
  `engine_smoke_max_puffs_per_tick` bursts/frame so a rapid run of cuts can't flood
  the pool. Using the counter delta (not an edge-detected bool) means no cut is
  missed regardless of frame/substep timing.
- **Emit point.** The car's `engine_smoke_local` — a car-local point pinned to where
  the engine actually sits. Its longitudinal (Z) component is derived from the car's
  `engine_pos` (the normalised front-fraction, `1.0` = fully front / −Z, `0.0` = fully
  rear / +Z) mapped onto the wheelbase exactly like the centre of mass
  (`car.gd:_set_center_of_mass`): `z = wheelbase × (0.5 − engine_pos)`. So a rear-engine
  911 (`engine_pos ~0.1`) puffs from the tail, a front-engine car from the nose. The
  lateral/height come from the global `GameConfig.engine_smoke_offset` (its X/Y); its Z
  is only the baseline fallback for a car that doesn't expose `engine_smoke_local`.
  `car.gd` recomputes `engine_smoke_local` per spec in `_apply_physics_spec`. The emit
  point is transformed by the car's `global_transform`, so smoke rises from the engine
  for any car.
- **Motion / look.** Each particle rises (`engine_smoke_rise_mps` plus a little
  random `engine_smoke_scatter_mps`), **grows** over its life (uniform scale written
  into the MultiMesh basis diagonal, up to `engine_smoke_growth`×), and **fades** to
  nothing (per-instance alpha via MultiMesh instance colours + a transparent unshaded
  billboard, `engine_smoke_color`). Longer lifetime than the dust
  (`engine_smoke_lifetime_s`, ~1.5 s) and few particles, so it reads as lazy engine
  smoke rather than a spray. The GPU upload is a **single** `multimesh.buffer`
  assignment per tick, only when something moved or spawned.

## Wiring (in-event)

Created + wired by `world.gd` (reused across event regenerations). `setup(car)` syncs the
last-seen misfire count to the engine's counter so a fresh engine doesn't puff a spurious
backlog.

## Config knobs (`GameConfig`, *Engine Smoke* group)

`engine_smoke_enabled`, `engine_smoke_max`, `engine_smoke_per_cut`,
`engine_smoke_max_puffs_per_tick`, `engine_smoke_color`, `engine_smoke_size_m`,
`engine_smoke_growth`, `engine_smoke_lifetime_s`, `engine_smoke_rise_mps`,
`engine_smoke_scatter_mps`, `engine_smoke_offset`. Placeholder values pending playtest — the mechanism is
fixed, the values are not.

## Tests

`tests/headless/test_engine_smoke.gd` (a misfire puffs one burst, the puff emits from
the car's `engine_smoke_local` — rear-engine +Z vs front-engine −Z, no new cut emits
nothing more, the per-tick burst cap holds, `live_count` never exceeds the pool cap,
smoke expires after its lifetime, disabled emits nothing — driven against a stub car
exposing `misfire_count`). The `misfire_count` itself is covered in
`test_engine_logic.gd` (advances only on cuts, never while healthy).
