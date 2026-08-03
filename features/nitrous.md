# Nitrous

A held-button torque boost with a per-stage tank. The single genuinely new
mechanic introduced by the star-gated special-event ladder
(`todo/star-gated-special-events.md`): the top four rungs of that ladder unlock
nitrous and its three upgrades, so it is deliberately a late-game toy that makes
hard events easier rather than a stat that reshapes the car.

Three properties define it, and every design decision below falls out of them:

1. **It is a per-STAGE resource with no persistent spent state.** The tank is
   refilled to full by `EngineSim.reset()`, which runs at every stage start *and*
   at every in-stage reset-to-start. A stage therefore never begins with less
   than a full tank — so there is nothing to carry between events and no
   reset-to-refill exploit to defend against.
2. **It is invisible to the performance model.** It never reaches
   `UpgradeLibrary.effective_meta`, so fitting it cannot move a car's
   power-to-weight, its rally eligibility, its `qualifying_detune` or the rival
   pace floor. Winning your 40-star reward can never lock you out of a rally you
   could previously enter.
3. **It has no garage UI.** An unwanted bottle is simply a button you don't
   press, and since it can't change eligibility there is nothing to decide — so
   the slot is hidden and the part auto-fits enabled.


## The catalogue side — a hidden fifth slot

`UpgradeLibrary.SLOTS` gained a fifth entry, `"nitrous"`. It could not join the
`turbo` slot: one part per slot is *enabled* per car
(`Save._enable_exclusive`), which would have made nitrous mutually exclusive
with the turbo and the supercharger — exactly wrong, since nitrous is meant to
stack on top of whatever induction the car carries.

Two conventions hang off the slot id:

- **`UpgradeLibrary.HIDDEN_SLOTS := "nitrous"`.** The flow controllers
  (`rally_session.gd` `report_event_result`, `challenge_session.gd`) install
  awarded parts **disabled**, because the reveal overlay is what enables the
  player's pick. With no garage row, a disabled bottle would be permanently
  dead — so parts in this slot are installed **enabled**
  (`Save.install_upgrade(..., true)`).
- **`upgrades_menu.gd` skips the slot** when building its slot rows, so it never
  appears in the garage. There is no uninstall path and nothing to show in the
  tuning lift.

The four authored rungs form a **chained ladder inside the one slot** — each
`requires_upgrade_id`s the previous one (the `turbo_small` → `turbo_large`
precedent) and each is star-gated on its own special event via
`unlocked_by_rally` (see [upgrade-catalogue.md](upgrade-catalogue.md) and
[rally-roster.md](rally-roster.md)). Because one part per slot is enabled, a new
rung simply **replaces** the last. Each rung mixes the two levers — tank
**seconds** ("longer") and torque **gain** ("harder") — so the escalation never
reads as the same number three times. The exact ids, gates and magnitudes are
authored in `UpgradeLibrary.UPGRADES`; read the table rather than trusting a
number quoted here.

### The effect row

`UpgradeLibrary.EFFECTS["install_nitrous"]` is `{"op": "write_fields",
"feeds_pw": false}`. `write_fields` is a plain splat of the authored sub-dict
onto the live `GameConfig` — no enable flag and no slot rival to clear, unlike
the `install_induction` op the turbo and supercharger share, because
`GameConfig.has_nitrous()` reads the *values themselves*, so a zero gain or a
zero tank simply IS "not fitted".

`feeds_pw: false` is the load-bearing half. It is what keeps nitrous out of
`effective_meta`'s power-to-weight mirror — property 2 above — and it is
enforced structurally by the shared descriptor table rather than by a special
case in `effective_meta`.


## Config (`GameConfig`, `scripts/game_config.gd`)

| Field | Meaning |
|---|---|
| `nitrous_boost_gain` | extra torque fraction while held — delivered torque is multiplied by `(1.0 + this)`. `0` = not fitted. The "harder" lever. |
| `nitrous_tank_seconds` | seconds a full tank holds. The "longer" lever. |

`GameConfig.has_nitrous()` returns true only when **both** are positive,
mirroring `has_supercharger_physics`. It is the single "is nitrous fitted"
predicate, shared by the sim, the HUD gauge and the mobile overlay.

Both default to `0.0` in the script and are **not** authored in
`config/game_config.tres` — the baseline car has no nitrous, and the upgrade's
effect dict is what writes them in (pipeline step 2, see
[configuration.md](configuration.md)).


## The sim (`EngineSim`, `scripts/engine.gd`)

State, all public so the audio bridge and HUD can read it:

| Member | Meaning |
|---|---|
| `nitrous_charge` | seconds left in the tank |
| `nitrous_active` | the driver is holding the action **this tick** — written each tick by `car.gd` |
| `nitrous_event` | set on the substep delivery *starts* (the trigger crack) |
| `nitrous_emptied` | set on the substep the tank runs dry (the cutoff cue) |
| `nitrous_fraction()` | `charge / tank_seconds`, clamped; `0` when not fitted |

`_step_nitrous(cfg, h, combusting)` resolves delivery once per substep. It
clears both edge flags at the top, bails to a zero charge when
`cfg.has_nitrous()` is false, and delivers only when `nitrous_active` **and**
`combusting` **and** `nitrous_charge > 0`. The `combusting` term — throttle
open, not mid-shift, no fuel cut — means the tank can't be dumped off-throttle
where it would do nothing. On a delivering substep the charge drains by the
substep `h` and `step()` multiplies delivered crank torque by
`(1.0 + cfg.nitrous_boost_gain)`.

That multiplier sits **alongside**, not inside, the turbo/supercharger boost
chain: forced induction raises the torque curve permanently and feeds
power-to-weight; nitrous multiplies the delivered result for as long as the
button is down and never leaves the live sim.

`EngineSim.reset()` refills `nitrous_charge` to `cfg.nitrous_tank_seconds` (or
zero when not fitted) and clears the three flags — property 1 above.


## Input

- **Keyboard: LEFT Shift.** The `nitrous` action in `project.godot` binds
  `physical_keycode` 4194325 (`KEY_SHIFT`) with **`"location": 1`**
  (`KEY_LOCATION_LEFT`) — the only action in the project that deliberately sets
  `location`, so don't "normalise" it away. Left-only because on Windows holding
  *right* Shift for ~8 s opens the Filter Keys prompt, and nitrous is a held key.
  Shift is also the one key comfortable for both driving postures (WASD and the
  arrow cluster), and is browser-safe, unlike Tab/Ctrl/Alt/Cmd.
  The action is named `nitrous`, never `shift` — `shift_up` / `shift_down` (E/Q)
  are gear changes.
- **Controller: X, joypad button 2.** Freed up by removing the `toggle_gearbox`
  action, which is now a settings-menu option instead (`settings_menu.gd`
  `gearbox_auto()`). See [controls.md](controls.md).
- **Mobile: a small "NOS" button**, which also holds the throttle while pressed (no
  scenario wants nitrous without gas, and the buttons are adjacent).
  See [mobile-controls.md](mobile-controls.md);
  the summary is that `mobile_controls.gd` gates the region on
  `_has_nitrous_button()` (i.e. `GameConfig.has_nitrous()`), anchors it left of
  the GAS pedal — falling back to the BRAKE pedal in the auto-gas schemes, which
  have no gas pedal — and hit-tests `"nitrous"` **first** in `_button_region`, so
  in the simple left/right scheme (where the steering halves cover the whole
  lower screen) the button wins the overlap instead of steering. It is dropped
  outright when the gap to the steering cluster has closed below
  `_MIN_NITROUS_W`, and `_sync_nitrous_button` rebuilds the overlay when the
  driven car changes, not only when the scheme does.

`car.gd` reads it in one line inside its live-driver branch:
`engine.nitrous_active = _driver_input_live() and Input.is_action_pressed("nitrous")`.


## The gauge (`hud.gd`)

A **violet** `ProgressBar` (`NitrousBar`) in the same family as the health and
boost bars: caption inside the bar, `self_modulate` tinted via the shared
`_gauge_color`, no drop shadow on the caption (the gauge-caption exception, see
[ui-design-system.md](ui-design-system.md)), and visible **only** when nitrous
is fitted rather than sitting at zero.

`_NITROUS_HUE := 0.70` sits beside `_BOOST_HUE := 0.58` and deliberately differs
from it: a turbocharged car with nitrous shows **both** bars stacked at once, and
two near-identical blues would be unreadable mid-stage. The shared `_GAUGE_SAT` /
`_GAUGE_VAL` keep it a sibling of the other two. Stacking order is nitrous above
boost above health.

Both answers come from the model — `Config.data.has_nitrous()` for "is it
fitted", `EngineSim.nitrous_fraction()` for "how much is left" — and the write is
change-gated on the **rounded integer percent** (`_last_nitrous_pct`, `-1`
meaning not fitted), so a continuous drain only touches the bar when the reading
actually moves. Unlike boost, the bar drains rather than tracking a live reading.
See [hud.md](hud.md).


## Audio (`engine_audio_synth.gd`, `engine_audio.gd`)

A sixth synth layer, procedurally generated like every other forced-induction
sound — **no new sample assets**. See [engine-audio.md](engine-audio.md) for the
synth architecture.

It is deliberately **all hiss, no tone**: a car can carry a turbo (band-passed
noise whistle), a supercharger (tonal belt whine) and nitrous simultaneously, so
the nitrous layer has to stay identifiable against both. It is equally
deliberately given **no "power" layer** — nitrous multiplies torque, so the rpm
the sim reports already climbs faster and the existing rpm tracking makes the car
sound faster on its own. Adding a loudness layer would double-count that.

Four beats, built from envelope shapes already in the file:

1. **Trigger crack** on the delivery edge — a softer-attack, flutter-free
   variant of the blow-off valve burst (`NITROUS_CRACK_*`). This is what sells
   the button press.
2. **Sustain hiss** while delivering — low-passed noise on its own rolling
   noise-table read index (`_ni_nitrous`), ramped in by
   `NITROUS_HISS_ATTACK_RATE`, sitting *under* the engine note.
3. **Cutoff cue** on release **and** on tank-empty: the hiss low-pass cutoff
   slides from `NITROUS_HISS_LP_HZ` down to `NITROUS_TAIL_LP_HZ`, so it reads as
   a *descending* hiss rather than a fade. The dry-tank case is armed at full
   strength regardless of the current sustain level — it's the cutoff the player
   did **not** choose, so it has to be unmistakable.

`engine_audio.gd` bridges the per-substep sim flags to the per-buffer synth:
`nitrous_on` is `engine.nitrous_active and engine.nitrous_fraction() > 0.0`, with
`nitrous_trigger` / `nitrous_empty` OR-ing the sim's `nitrous_event` /
`nitrous_emptied` against its own frame-level edge detection, because a frame's
worth of substeps has usually already cleared the sim flags.

**`nitrous_on` is the DELIVERY state, never "nitrous is fitted".** That is what
keeps the HQ garage preview silent: `car_preview_audio.gd` applies the
highlighted car's fitted upgrades before revving, so a nitrous-equipped car
*has* nitrous there — but with no throttle-and-button input there is no delivery,
and the preview passes the nitrous args hard-false anyway.

**Not yet wired:** the mix level is the local constant
`engine_audio_synth.gd` → `NITROUS_HISS_GAIN`, standing in for a
`GameConfig.engine_nitrous_hiss_gain` field alongside
`engine_supercharger_whine_gain`. Once that field exists the constant becomes the
cached config gain. Filtered noise carries a lower RMS than a tonal wavetable, so
the levels sit nearer `TURBO_WHISTLE_LEVEL` than `TURBO_TONE_LEVEL`.


## Also not yet implemented

The **first-use hint** — a once-per-profile "press Shift" prompt at stage start,
suppressed forever after the first press. It needs a persisted profile flag and a
keyboard-vs-controller device distinction that `Platform` does not currently have
(it only knows `is_touch` / `is_web` / `is_mobile_or_web` / `is_headless`). Still
recorded as outstanding in `todo/star-gated-special-events.md`.


## Tests

Nitrous coverage lives in `tests/headless/test_hud.gd` (the gauge is hidden
unless fitted, tracks the tank fraction, keeps its caption inside the bar, and
tints distinguishably from the boost bar — asserted as a *relationship*, never a
pinned hue), `test_mobile_controls.gd` (the NOS region's per-scheme placement and its
hit-test priority over the simple steering halves) and `test_engine_audio.gd`
(the synth layer and its edges).

Per `CLAUDE.md`, do **not** pin the authored magnitudes — tank seconds, torque
gains, which rung sits at which star rung, the hue value. Test the behaviour that
must hold for any reasonable values: the tank starts full after `reset()`, the
multiplier applies only while held with charge, an empty tank applies none,
`effective_meta`'s power-to-weight is unmoved by fitting nitrous, and the part
installs enabled so it works with no menu interaction.
