# Forced Induction (Turbo & Supercharger)

**Sources:** `scripts/engine.gd` (`EngineSim` — turbo shaft sim),
`scripts/game_config.gd` (`turbo_*` / `supercharger_enabled` fields),
`scripts/engine_library.gd` (`EngineLibrary.apply` — stock wiring),
`scripts/upgrade_library.gd` (`turbo_small` / `turbo_large` upgrades,
`effective_meta`), `scripts/engine_audio_synth.gd` /
`scripts/engine_audio.gd` (whistle / BOV / anti-lag / whine audio).

Turbo and supercharger are both properties of the **engine**, not the car —
same pattern as the torque curve and gearbox (see
[engine-and-transmission.md](engine-and-transmission.md)). A turbo can arrive
two ways: baked into a stock `EngineLibrary` entry, or bolted on later via the
`turbo_small` / `turbo_large` upgrade items. A supercharger is **always**
stock — it is never an upgrade.

## Config fields (`game_config.gd`, `@export_group("Engine & Transmission")`)

| Field | Meaning |
|-------|---------|
| `turbo_enabled` | Whether the turbo sim runs at all. `false` (NA) skips `_step_turbo`'s physics entirely — zero cost, byte-identical to the pre-turbo behaviour. |
| `turbo_inertia` | Rotational inertia (kg·m²) of the turbo shaft — the physical source of lag. Bigger = spools slower. |
| `turbo_omega_ref` | Shaft speed (rad/s) at which boost saturates at 1.0. Bigger turbos need a higher value (come on later/higher). |
| `turbo_boost_gain` | Torque multiplier at full boost: `delivered = na_torque * (1 + boost * turbo_boost_gain)`. 0 = no gain (NA). |
| `turbo_drive_gain` | Couples exhaust flow (∝ throttle × rpm) into shaft drive torque. |
| `turbo_drag_coef` | Bearing/aero drag on the shaft (∝ ω²) — sets steady-state speed for a given flow and the off-throttle bleed rate. |
| `turbo_antilag` | Anti-lag switch: keeps the shaft spinning off-throttle + triggers exhaust bangs. |
| `turbo_antilag_drive` | Residual exhaust drive injected off-throttle when anti-lag is on. |
| `supercharger_enabled` | Belt-driven supercharger flag — audio-only (see below). |
| `engine_turbo_whistle_gain` / `engine_turbo_bov_gain` / `engine_turbo_antilag_bang_gain` / `engine_supercharger_whine_gain` | Independent audio mix levels for the four forced-induction sound layers (−1..1; negative = phase-inverted). |
| `engine_turbo_whistle_freq_min` / `engine_turbo_whistle_freq_max` / `engine_turbo_whistle_q` / `engine_turbo_air_mix` | Spool-whistle character: band-pass sweep range (Hz), resonance (airy↔tonal), and broadband air-rush blend. |

All of these are written by `EngineLibrary.apply()` (stock, from a catalog
entry's optional keys, defaulting to OFF/zero when absent — see
[engine-and-transmission.md](engine-and-transmission.md)) or by the
`install_turbo` upgrade effect (`UpgradeLibrary.apply`, below) — never edited
directly on a live `Car`.

## The turbo shaft sim (`EngineSim._step_turbo`, `scripts/engine.gd`)

Called once per `EngineSim.step()` substep, **before** crank torque is built,
so the boost multiplier reflects the current substep:

```gdscript
func _step_turbo(cfg: GameConfig, h: float, throttle_in: float) -> void:
    bov_event = false
    if not cfg.turbo_enabled:
        omega_turbo = 0.0; boost = 0.0; antilag_active = false
        _prev_throttle = throttle_in
        return
    var drive := turbo_exhaust_drive(rpm(), throttle_in, cfg.turbo_drive_gain, cfg.turbo_antilag, cfg.turbo_antilag_drive)
    omega_turbo = maxf(omega_turbo + turbo_shaft_accel(drive, omega_turbo, cfg.turbo_drag_coef, cfg.turbo_inertia) * h, 0.0)
    boost = boost_fraction(omega_turbo, cfg.turbo_omega_ref)
    if _prev_throttle > 0.1 and throttle_in <= 0.05 and boost > BOV_BOOST_THRESHOLD:
        bov_event = true
    antilag_active = cfg.turbo_antilag and throttle_in <= 0.05 and boost > 0.05
    _prev_throttle = throttle_in
```

Three pure, unit-testable helper functions (static, so the maths is testable
without an `EngineSim` instance):

- **`turbo_exhaust_drive(rpm, throttle, drive_gain, antilag, antilag_drive)`**
  — exhaust energy available to spin the shaft: `drive_gain * throttle * rpm`,
  floored at `antilag_drive` when anti-lag is active (so the shaft never fully
  spools down off-throttle).
- **`turbo_shaft_accel(exhaust_drive, omega_turbo, drag_coef, inertia)`** —
  `(exhaust_drive − drag_coef·ω²) / inertia`. This is a real (if simplified)
  turbine model: exhaust flow drives the shaft, bearing/aero drag grows with
  the square of speed, and inertia sets how fast it can respond.
- **`boost_fraction(omega_turbo, omega_ref)`** — `clamp((ω/ω_ref)², 0, 1)`:
  centrifugal-compressor pressure rises with the square of shaft speed,
  saturating at the turbo's design ceiling.

`step()` then multiplies the throttle torque term by `(1 + boost *
turbo_boost_gain)`:

```gdscript
crank += throttle * cfg.peak_torque * cfg.global_torque_scale * _torque_fraction(rpm()) * (1.0 + boost * cfg.turbo_boost_gain)
```

**Lag, boost threshold, mid-range surge, and off-throttle bleed-down are all
emergent** from this one integrator — there is no separate "lag" or "surge"
constant. A small `turbo_inertia` spools almost instantly (low lag); a large
one takes real revs/seconds to build drive against its own ω²-drag before
boost climbs; lifting off throttle drops `turbo_exhaust_drive` to (near) zero
and the shaft decays under drag alone, so boost fades on its own.

`omega_turbo` and `boost` are reset to 0 in `EngineSim.reset()`, and are
inert (stay 0) whenever `cfg.turbo_enabled` is false — an NA engine pays no
runtime cost beyond the one `if` check at the top of `_step_turbo`.

## Anti-lag

Anti-lag (`cfg.turbo_antilag` + `cfg.turbo_antilag_drive`) is modelled as a
**drive floor**, not a special-cased torque hack: `turbo_exhaust_drive` clamps
its result up to `turbo_antilag_drive` whenever anti-lag is on, so the shaft
keeps spinning even at zero throttle. `antilag_active` is set true whenever
anti-lag is enabled, the driver has lifted off (`throttle_in <= 0.05`), and
there's still meaningful boost (`boost > 0.05`) — this flag drives the
anti-lag bang audio layer, not any extra torque or a penalty; there is no
fuel-cost, wear, or reliability consequence modelled.

## Blow-off valve (BOV)

`bov_event` fires for exactly one substep when the throttle is snapped shut
(`_prev_throttle > 0.1` → `throttle_in <= 0.05`) while boost is above
`EngineSim.BOV_BOOST_THRESHOLD` (0.3) — lifting off hard while boosted vents
the dump valve. It's a pure edge-trigger flag read once by the audio bridge
(below); it has no effect on the physics.

## Upgrade tiers (`UpgradeLibrary`, `scripts/upgrade_library.gd`)

Two non-consumable `"engine"`-slot items replace the old flat `engine_stage1`
/ `engine_stage2` power upgrades:

```gdscript
{
    "id": "turbo_small", "name": "Small Turbo", "slot": "engine", "tier": 1, "consumable": false,
    "effect": {"install_turbo": {
        "turbo_boost_gain": 0.35, "turbo_inertia": 6.0e-3, "turbo_omega_ref": 10000.0,
        "turbo_drive_gain": 0.03, "turbo_drag_coef": 1.0e-6,
        "engine_turbo_whistle_gain": 0.3, "engine_turbo_bov_gain": 0.4,
    }},
},
{
    "id": "turbo_large", "name": "Big Turbo", "slot": "engine", "tier": 3, "consumable": false,
    "effect": {"install_turbo": {
        "turbo_boost_gain": 0.8, "turbo_inertia": 2.0e-2, "turbo_omega_ref": 14000.0,
        "turbo_drive_gain": 0.028, "turbo_drag_coef": 1.0e-6,
        "engine_turbo_whistle_gain": 0.5, "engine_turbo_bov_gain": 0.6,
    }},
},
```

(These exact numbers are authored balance placeholders — see
[configuration.md](configuration.md)'s tuning philosophy; do not pin them in
tests.)

`UpgradeLibrary.apply()` handles the shared `"install_turbo"` effect key
generically: it sets `cfg.turbo_enabled = true`, then copies every key/value
in the effect's nested dict straight onto `cfg` with `cfg.set(tkey, val)` —
so a turbo upgrade is just "turn the sim on and stamp these turbo_* fields",
the same mechanism whether it's the small or big tier (or a future one):

```gdscript
"install_turbo":
    cfg.turbo_enabled = true
    for tkey in (val as Dictionary):
        cfg.set(tkey, (val as Dictionary)[tkey])
```

Only one `"engine"`-slot part can be fitted+enabled at a time
(`UpgradeLibrary.SLOTS`), so a car can't stack `turbo_small` and
`turbo_large` — installing one replaces the other in that slot.

### Rated at peak boost (`effective_meta`)

`UpgradeLibrary.effective_meta(owned_car, meta)` computes the car's displayed
stats (HP / power-to-weight, used for both the garage screen and
`RallyLibrary.is_eligible` banding). It resolves a `boost_gain` — starting
from the current engine's stock `turbo_boost_gain`, then overridden by an
installed `install_turbo` upgrade's `turbo_boost_gain` if one is fitted+
enabled — and applies it as:

```gdscript
out["peak_torque"] = float(out.get("peak_torque", 0.0)) * (1.0 + boost_gain)
```

i.e. the displayed/eligibility torque is rated **at full (peak) boost**, the
same multiplier the sim itself applies at `boost == 1.0`. This runs before
the engine-detune scaling, so a boosted-but-detuned car's rating reflects
both.

## Supercharger

A supercharger is **intrinsic to the engine, never an upgrade** — there is no
`UPGRADES` entry for it and no install effect. `cfg.supercharger_enabled` is
set only by `EngineLibrary.apply()` from a stock catalog entry's
`supercharger_enabled` key. It carries **no physics**: a supercharged
engine's forced-induction power gain is already baked into its authored
`peak_torque` figure (real superchargers are always-on, so there's no boost
curve or lag to simulate — the engine simply makes its published torque).
`supercharger_enabled` exists purely to drive the belt-driven whine audio
layer (below); it does not touch `EngineSim` at all.

## Audio (`scripts/engine_audio_synth.gd`, bridged by `scripts/engine_audio.gd`)

Four independently-gained layers on top of the base cylinder voice, all
opt-in via their own gain field (zero gain = silent, byte-identical to a car
without forced induction):

- **Spool whistle** — **resonant band-pass-filtered noise**, not a pure tone
  (a real turbo is air rushing through the compressor). White noise runs through
  a TPT/Cytomic state-variable band-pass whose centre frequency sweeps from
  `engine_turbo_whistle_freq_min` to `engine_turbo_whistle_freq_max` with
  `turbo_spin` (`= omega_turbo / turbo_omega_ref`); `engine_turbo_whistle_q` sets
  how tonal-vs-airy it is, and `engine_turbo_air_mix` blends in a broadband
  air-rush layer. Amplitude tracks `boost` and `engine_turbo_whistle_gain`; only
  audible while `boost > 0`. Filter coefficients are recomputed once per audio
  buffer (boost/spin are constant across it), so the per-sample cost is just the
  SVF recurrence — no per-sample transcendental.
- **Blow-off burst** — a transient decaying noise burst, edge-triggered on
  `bov_event` (a throttle lift while boosted, OR the start of a gear shift — the
  driver lifts to change gear — even with the throttle held), scaled by
  `engine_turbo_bov_gain` × the boost level at the lift (loudest at full boost).
- **Anti-lag bang** — its own independent decaying burst, retriggered on an
  interval while `antilag_active` stays true, scaled by
  `engine_turbo_antilag_bang_gain`.
- **Supercharger whine** — a wavetable tone (a supercharger genuinely *is* a
  mechanical belt-driven tone, unlike the turbo), pitch tracking engine rpm
  directly (belt-driven), always on (not gated on boost) while
  `supercharger_enabled` is true, scaled by `engine_supercharger_whine_gain`.

`EngineAudioSynth.fill()` takes four sim→synth signals as trailing,
defaulted params: `boost`, `turbo_spin`, `bov_event`, `antilag_active`.
`engine_audio.gd._process` computes `turbo_spin` from
`engine.omega_turbo / Config.data.turbo_omega_ref` (guarded against a zero
`turbo_omega_ref`) and passes `engine.boost`, `engine.bov_event`, and
`engine.antilag_active` straight through from the live `EngineSim`. See
[engine-audio.md](engine-audio.md) for the full synthesis chain (wavetables,
soft clipper, DC blocker) these layers ride on.

## Stock wiring

`porsche_30_flat6` ("3.0 turbo flat-6", the 930 Turbo-derived engine) carries
`turbo_enabled: true` plus `turbo_boost_gain` / `turbo_inertia` / whistle and
BOV gains in `EngineLibrary.ENGINES`, so the feature is reachable on a stock
car without any upgrade — see `scripts/engine_library.gd`.

## Save-compat note

Old save profiles (`OwnedCar.installed_upgrades`) may still list the removed
`engine_stage1` / `engine_stage2` ids from before the turbo tiers replaced
them. `UpgradeLibrary.by_id()` returns `{}` for an unknown id, and every
reader (`enabled_upgrades`, `UpgradeLibrary.apply`, `effective_meta`) treats
a missing `"effect"` key as `{}` and iterates zero entries — so a save
carrying a stale id becomes silently inert (no crash, no effect) rather than
erroring or granting a phantom stat. It stays listed in the save but never
does anything; there's no migration step.

## Tests

`tests/headless/test_turbo.gd` (pure shaft maths — `boost_fraction`,
`turbo_exhaust_drive`, `turbo_shaft_accel`, `_step_turbo` sequencing:
spool-up-with-throttle / bleed-down-off-throttle / anti-lag drive floor / BOV
edge trigger — with synthetic configs, no catalogue dependency),
`tests/headless/test_engine.gd` (NA regression — a `turbo_enabled == false`
config behaves exactly as before), `tests/headless/test_engine_audio.gd`
(whistle energy rising with boost, a BOV event adding a transient burst, a
supercharger whine only when enabled), `tests/headless/test_engine_library.gd`
/ `tests/headless/test_upgrade_library.gd` (catalog entries load, `apply()`
writes the fields, `install_turbo` sets `turbo_enabled` + stamps the effect
dict, `effective_meta` rates at peak boost).

## Related config

`turbo_enabled`, `turbo_inertia`, `turbo_omega_ref`, `turbo_boost_gain`,
`turbo_drive_gain`, `turbo_drag_coef`, `turbo_antilag`, `turbo_antilag_drive`,
`supercharger_enabled`, `engine_turbo_whistle_gain`, `engine_turbo_bov_gain`,
`engine_turbo_antilag_bang_gain`, `engine_supercharger_whine_gain`. See
[configuration.md](configuration.md), [engine-and-transmission.md](engine-and-transmission.md),
[engine-audio.md](engine-audio.md), and [upgrade-catalogue.md](upgrade-catalogue.md).
