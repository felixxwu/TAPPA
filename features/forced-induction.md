# Forced Induction (Turbo & Supercharger)

**Sources:** `scripts/engine.gd` (`EngineSim` — turbo shaft sim +
`supercharger_boost_fraction` / `supercharger_parasitic`),
`scripts/game_config.gd` (`turbo_*` / `supercharger_*` fields),
`scripts/engine_library.gd` (`EngineLibrary.apply` — stock wiring),
`scripts/boost_library.gd` (the `turbo` / `supercharger` parts),
`scripts/upgrade_library.gd` (the `install_turbo` / `install_supercharger` effect rows,
`effective_meta`), `scripts/engine_audio_synth.gd` /
`scripts/engine_audio.gd` (whistle / BOV / anti-lag / whine audio).

**Tests:** `tests/headless/test_turbo.gd`, `tests/headless/test_engine.gd`, `tests/headless/test_engine_audio.gd`, `tests/headless/test_engine_library.gd`, `tests/headless/test_upgrade_library.gd`

Turbo and supercharger are both properties of the **engine**, not the car —
same pattern as the torque curve and gearbox (see
[engine-and-transmission.md](engine-and-transmission.md)). Either can arrive
two ways: baked into a stock `EngineLibrary` entry, or fitted as a found free-roam **part**
— `BoostLibrary.CATALOGUE`'s `"turbo"` / `"supercharger"` entries, found by level in the biome
ring each names ([loot.md](loot.md)). A part reaches the car through `LootRules.fielded` →
the `boosts` list → the `install_turbo` / `install_supercharger` `EFFECTS` rows. Only the
part's `*_boost_gain` scales with its level; the rest of its character is fixed.

Note: [nitrous](nitrous.md) is a **third**, non-exclusive power layer — its own
`"nitrous"` slot (`UpgradeLibrary.SLOTS`), so a car can carry turbo-or-blower
AND nitrous at once. It's a torque multiplier in the live sim only
(`install_nitrous`, `EFFECTS["install_nitrous"].feeds_pw == false`), so unlike
`install_turbo`/`install_supercharger` (`feeds_pw: true`) it never changes a
car's displayed power-to-weight — it makes the car quicker to drive, it isn't a stat.

## Config fields (`game_config.gd`, `@export_group("Engine & Transmission")`)

| Field | Meaning |
|-------|---------|
| `turbo_enabled` | Whether the turbo sim runs at all. `false` (NA) skips `_step_turbo`'s physics entirely — zero cost, byte-identical to the pre-turbo behaviour. |
| `turbo_inertia` | Rotational inertia (kg·m²) of the turbo shaft — the physical source of lag. Bigger = spools slower. |
| `turbo_omega_ref` | Shaft speed (rad/s) at which boost saturates at 1.0. Bigger turbos need a higher value (come on later/higher). |
| `turbo_boost_gain` | Torque multiplier at full boost: `delivered = na_torque * (1 + boost^turbo_boost_response * turbo_boost_gain)`. 0 = no gain (NA). |
| `turbo_parasitic_friction` | Constant extra crank friction (N·m) the fitted turbo adds (backpressure/pumping loss). **Always-on — not gated on boost or rpm.** Bigger turbos author more. Off boost it just bogs the engine; once boost is up the delivered torque swamps it. Because it's a fixed N·m, it's a large fraction of a small engine's peak torque and a small one of a big engine's — so a big turbo on a small motor really struggles to climb the low range, then comes alive up top. Authored per-turbo (engine dict / `install_turbo`); 0 = NA. |
| `turbo_boost_response` | Shaping exponent on `boost` for the **torque path only** (the HUD gauge + audio still read raw `boost`). `1.0` = linear (spool 50% → half the gain); `> 1` delays the power so a partially-spooled turbo delivers disproportionately little — lag felt more. Endpoints (0 boost, full boost) are unchanged for any value. Global (not per-turbo); tuned in `game_config.tres`. |
| `turbo_drive_gain` | Couples exhaust flow (∝ throttle × rpm) into shaft drive torque. |
| `turbo_drag_coef` | Bearing/aero drag on the shaft (∝ ω²) — sets steady-state speed for a given flow and the off-throttle bleed rate. |
| `turbo_antilag` | Anti-lag switch: keeps the shaft spinning off-throttle + triggers exhaust bangs. |
| `turbo_antilag_drive` | Residual exhaust drive injected off-throttle when anti-lag is on. |
| `supercharger_enabled` | Belt-driven supercharger flag. Drives the whine audio layer; on a **stock** blown engine that is all it does (`supercharger_boost_gain` stays 0 because the power is already baked into `peak_torque`). |
| `supercharger_boost_gain` | Torque multiplier at full belt boost: `delivered = na_torque * (1 + sc_boost * supercharger_boost_gain)`. **0 = no physics** — the switch that separates the audio-only stock flag from the supercharger upgrade. |
| `supercharger_rpm_ref` | Engine rpm at which belt boost saturates at 1.0. Boost is **linear in rpm** with no shaft state — there is nothing to spool. |
| `supercharger_parasitic_coef` | Belt drag on the crank, in N·m **per 1000 rpm**. Unlike the turbo's constant backpressure this grows *with* revs (the blower takes more to spin the faster it turns), so the top end pays for the instant bottom-end response. 0 = no penalty. |
| `engine_turbo_whistle_gain` / `engine_turbo_bov_gain` / `engine_turbo_antilag_bang_gain` / `engine_supercharger_whine_gain` | Independent audio mix levels for the four forced-induction sound layers (−1..1; negative = phase-inverted). |
| `engine_turbo_whistle_freq_min` / `engine_turbo_whistle_freq_max` / `engine_turbo_whistle_q` / `engine_turbo_air_mix` | Spool-whistle character: band-pass sweep range (Hz), resonance (airy↔tonal), and broadband air-rush blend. |

All of these are written by `EngineLibrary.apply()` (stock, from a catalog
entry's optional keys, defaulting to OFF/zero when absent — see
[engine-and-transmission.md](engine-and-transmission.md)) or by the
`install_turbo` / `install_supercharger` upgrade effects (`UpgradeLibrary.apply`,
below) — never edited directly on a live `Car`.

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
    # Exhaust flow follows COMBUSTION, not the pedal: mid-shift fuel is cut, so there
    # is nothing to spin the shaft even with the throttle input still held.
    var exhaust_throttle := 0.0 if shift_timer > 0.0 else throttle_in
    var drive := turbo_exhaust_drive(rpm(), exhaust_throttle, cfg.turbo_drive_gain, cfg.turbo_antilag, cfg.turbo_antilag_drive)
    omega_turbo = maxf(omega_turbo + turbo_shaft_accel(drive, omega_turbo, cfg.turbo_drag_coef, cfg.turbo_inertia) * h, 0.0)
    boost = boost_fraction(omega_turbo, cfg.turbo_omega_ref)
    # Blow-off fires on either of two triggers while boosted: a throttle snap-shut,
    # OR the start of a gear shift (the driver lifts to change gear) even with the
    # throttle still held.
    var shifting := shift_timer > 0.0
    if boost > BOV_BOOST_THRESHOLD:
        if _prev_throttle > 0.1 and throttle_in <= 0.05:
            bov_event = true
        elif shifting and not _prev_shifting:
            bov_event = true
    antilag_active = cfg.turbo_antilag and throttle_in <= 0.05 and boost > 0.05
    _prev_throttle = throttle_in
    _prev_shifting = shifting
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

`step()` then multiplies the throttle torque term by `boost_torque_factor()`
(a fourth pure helper), `1 + boost^response * gain`:

```gdscript
crank += throttle * cfg.peak_torque * cfg.global_torque_scale * _torque_fraction(rpm()) * boost_torque_factor(boost, cfg.turbo_boost_gain, cfg.turbo_boost_response)
```

The `turbo_boost_response` exponent shapes *how* the gain arrives across the
boost range without moving the endpoints (0 boost → factor 1, full boost →
`1 + gain` for any response): `1.0` is the old linear gain; `> 1` makes
part-spool deliver disproportionately little power so **lag is felt more** —
the gauge needle climbs while the shove waits for the top of the range.

**Lag, boost threshold, mid-range surge, and off-throttle bleed-down are all
emergent** from this one integrator — there is no separate "lag" or "surge"
constant. A small `turbo_inertia` spools almost instantly (low lag); a large
one takes real revs/seconds to build drive against its own ω²-drag before
boost climbs; lifting off throttle drops `turbo_exhaust_drive` to (near) zero
and the shaft decays under drag alone, so boost fades on its own.

**A gear shift bleeds boost the same way a lift does.** `step()` cuts fuel while
`shift_timer > 0.0` (its `combusting` flag), so the exhaust throttle fed to
`turbo_exhaust_drive` is forced to zero for the duration of the shift — otherwise
an automatic upshift would keep spooling the shaft on a throttle input that isn't
burning anything, and boost would *rise* through a gear change. The decay is
identical to a driver lift (`test_a_shift_bleed_matches_lifting_off`). Anti-lag is
the one thing that holds boost through a shift, and it still does: its residual
drive is a floor inside `turbo_exhaust_drive`, independent of throttle. The BOV
and anti-lag *audio* flags below still read the raw driver input, so they are
unaffected.

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

## The induction effect rows (`UpgradeLibrary`, `scripts/upgrade_library.gd`)

(The exact numbers a part stamps are authored balance placeholders in `BoostLibrary` /
`GameConfig`'s `run_boost_*` fields — do not pin them in tests.)

`UpgradeLibrary.apply()` handles **both** induction effect keys through ONE
`"install_induction"` op, with everything that differs between them living in the
`EFFECTS` descriptor row rather than in a branch — `enable` (the flag this part
switches on) and `gain_key` (the sub-key `effective_meta` rates power-to-weight from):

```gdscript
"install_induction":
    cfg.set(String(desc["enable"]), true)
    for tkey in (val as Dictionary):
        cfg.set(tkey, (val as Dictionary)[tkey])
```

So an induction upgrade is just "switch this on, stamp these fields" — the same
mechanism for the turbo and the supercharger (or a future third induction axis), which
is a table row rather than another `match` arm.

**Turbo and supercharger STACK (a real twincharger) — this used to be mutually
exclusive, and no longer is.** A `clears` key here once zeroed the rival's enable flag
and gain, back when both shared one `UpgradeLibrary.SLOTS` PURCHASE slot (a permanent-
part mechanism the roguelike pivot deleted). That's gone now: `BoostLibrary`'s parts have
no such slot, `apply()` no longer clears anything, and `EngineSim.step()`
already multiplied the turbo factor and the supercharger factor together
UNCONDITIONALLY (see the crank formula in *Supercharger* below) — the physics never
actually assumed exclusivity, only the old purchase UI did. Fitting a supercharger must never
take away a turbo the player already found.

**The part's `effect_fields` dict carries its own audio gains, not just
physics.** `BoostLibrary.CATALOGUE`'s `"turbo"`/`"supercharger"` entries author
`engine_turbo_whistle_gain` / `engine_turbo_bov_gain` / `engine_turbo_antilag_bang_gain`
(turbo) and `engine_supercharger_whine_gain` (supercharger) inside their
`install_turbo`/`install_supercharger` sub-dicts, sourced from fixed (never
level-scaled — absent from `scaled_subfields`) `GameConfig` fields
`run_boost_turbo_whistle_gain` / `run_boost_turbo_bov_gain` /
`run_boost_turbo_antilag_bang_gain` / `run_boost_supercharger_whine_gain`. Without
these, fitting the part switched on real physics (`turbo_enabled` +
a non-zero `*_boost_gain`) but left the audio gain fields at whatever the car's OWN
engine authored — zero, for every catalogue engine that isn't already
stock-turbocharged/supercharged — so a part on an ordinary NA car ran
completely silent despite doing real work. The stock route (`EngineLibrary.apply()`
copying an engine's own authored gains) is unaffected; this only closes the gap for
the boost-catalogue route. Regression test:
`test_boost_library.gd`'s `test_installing_turbo_and_supercharger_boosts_together_leaves_both_audible`.

### Rated at peak boost (`effective_meta`)

`UpgradeLibrary.effective_meta(owned_car, meta)` computes the car's displayed
stats (HP / power-to-weight, used by the garage and car cards). Since the two axes can both be live at once, it
tracks each SEPARATELY — starting from the current engine's own stock
`turbo_boost_gain`/`supercharger_boost_gain`, each overridden independently by a
fitted `install_turbo`/`install_supercharger` boost on that axis — then combines them
MULTIPLICATIVELY, mirroring the sim's own crank formula rather than adding or picking
one:

```gdscript
out["peak_torque"] = float(out.get("peak_torque", 0.0)) * (1.0 + turbo_gain) * (1.0 + supercharger_gain)
```

i.e. the displayed torque is rated **at full (peak) boost on every fitted
axis**, the same multiplier the sim itself applies at `boost == 1.0` /
`sc_boost == 1.0`. This runs before the engine-detune scaling, so a boosted-but-detuned
car's rating reflects both.

## Supercharger (belt drive)

A supercharger arrives **two ways**, and which one it is decides whether it
carries physics:

- **Stock, on a catalog engine** — `EngineLibrary.apply()` copies the entry's
  `supercharger_enabled` key. The gain stays 0, so the belt physics never
  engage: the engine's forced-induction power is already baked into its
  authored `peak_torque`, and the flag drives nothing but the whine audio
  layer (below). This is exactly the pre-existing audio-only behaviour.
- **As the `supercharger` upgrade** — the top rung of the `"turbo"` slot,
  prerequisite-gated behind `turbo_large`. Its `install_supercharger` effect
  authors a non-zero `supercharger_boost_gain` (plus `supercharger_rpm_ref`
  and `supercharger_parasitic_coef`), which turns on the belt sim below.

The belt sim is deliberately **stateless** — that's the whole character of a
blower. Two pure statics on `EngineSim`, both called from `step()`:

```gdscript
# Boost: LINEAR in rpm, saturating at rpm_ref. No shaft, no inertia, no lag.
static func supercharger_boost_fraction(engine_rpm: float, rpm_ref: float) -> float:
    if rpm_ref <= 0.0:
        return 0.0
    return clampf(engine_rpm / rpm_ref, 0.0, 1.0)

# Belt drag on the crank (N·m), authored per 1000 rpm — grows WITH revs.
static func supercharger_parasitic(engine_rpm: float, coef: float) -> float:
    return coef * maxf(engine_rpm, 0.0) / 1000.0
```

`step()` recomputes `sc_boost` from the current rpm every substep (gated on
`GameConfig.has_supercharger_physics()` — the shared predicate, so the engine and the
HUD can't disagree about what counts as a fitted blower), adds the belt drag to the same
friction sum as `turbo_parasitic_friction`, and folds the gain into the torque line
alongside the turbo's factor. The gate skips BOTH the drag and the boost, so a car
without a blower pays one bool check per substep rather than a call and a divide:

```gdscript
crank += throttle * cfg.peak_torque * cfg.global_torque_scale * _torque_fraction(rpm()) \
    * boost_torque_factor(boost, cfg.turbo_boost_gain, cfg.turbo_boost_response) \
    * (1.0 + sc_boost * cfg.supercharger_boost_gain)
```

**The two forced-induction paths multiply, and both CAN be non-unity at once now** — a
car can genuinely run turbo AND supercharger together (see *Turbo and supercharger
STACK* above). `turbo_enabled` and `supercharger_enabled` are independent flags with
nothing clearing one when the other switches on, so a twincharged car's whistle, BOV
and anti-lag layers (turbo) play right alongside its whine (supercharger) — which is
the point: a real twincharger sounds like both at once.

**How it plays against Big Turbo.** Its peak gain is only a little higher, so
the two are close on paper; the real advantage is the *shape* — full boost the
instant the revs are there, with no threshold and no bleed-down. The cost is
drag proportional to rpm, so the blower gives up at the top of the rev range
what it hands you at the bottom, where the big turbo is still spooling.

`sc_boost` is reset in `EngineSim.reset()`. Consumers do **not** combine the two
readings themselves — `EngineSim.boost_reading()` is the single 0..1 forced-induction
reading (`maxf(boost, sc_boost)` — on a twincharged car, whichever is higher),
and the HUD's boost gauge plus its debug readout both go through it together with
`GameConfig.has_forced_induction()`.

**The audio bridge deliberately does NOT.** `engine_audio.gd` passes the raw `boost` field into the synth, because that argument drives the turbo
**whistle** and **blow-off valve** — layers only a turbo has. Feeding belt boost in would make a supercharged car whistle and
vent like a turbo; its own whine is rpm-pitched.

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

## Tests

`tests/headless/test_turbo.gd` (pure shaft maths — `boost_fraction`,
`turbo_exhaust_drive`, `turbo_shaft_accel`, `_step_turbo` sequencing:
spool-up-with-throttle / bleed-down-off-throttle / bleed-down-mid-shift /
anti-lag drive floor, including through a shift / BOV edge trigger — with
synthetic configs, no catalogue dependency),
`tests/headless/test_engine.gd` (NA regression — a `turbo_enabled == false`
config behaves exactly as before), `tests/headless/test_engine_audio.gd`
(whistle energy rising with boost, a BOV event adding a transient burst, a
supercharger whine only when enabled), `tests/headless/test_engine_library.gd`
/ `tests/headless/test_upgrade_library.gd` (catalog entries load, `apply()`
writes the fields, `install_turbo` sets `turbo_enabled` + stamps the effect
dict, `install_supercharger` sets the blower without clearing the turbo, `effective_meta`
rates at peak boost for both), and `tests/headless/test_boost_library.gd` (both parts fitted
together stay audible).
The blower's own physics live in `test_turbo.gd`'s supercharger block: boost
linear in rpm and saturating, drag affine in rpm, full boost on the FIRST
substep (no spool), boost tracking the revs both ways, inert without an
authored gain, and `reset()` clearing it.

## Related config

`turbo_enabled`, `turbo_inertia`, `turbo_omega_ref`, `turbo_boost_gain`,
`turbo_drive_gain`, `turbo_drag_coef`, `turbo_antilag`, `turbo_antilag_drive`,
`supercharger_enabled`, `supercharger_boost_gain`, `supercharger_rpm_ref`,
`supercharger_parasitic_coef`, `engine_turbo_whistle_gain`, `engine_turbo_bov_gain`,
`engine_turbo_antilag_bang_gain`, `engine_supercharger_whine_gain`,
`run_boost_turbo_whistle_gain`, `run_boost_turbo_bov_gain`,
`run_boost_turbo_antilag_bang_gain`, `run_boost_supercharger_whine_gain` (the
parts' own fixed audio-gain personality — see above). See
[configuration.md](configuration.md), [engine-and-transmission.md](engine-and-transmission.md),
[engine-audio.md](engine-audio.md), and [upgrade-catalogue.md](upgrade-catalogue.md).
