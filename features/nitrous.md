# Nitrous

A held-button torque boost with a per-stage tank. The single genuinely new
mechanic introduced by the special-event ladder
(`todo/star-gated-special-events.md` — the spec's filename, but the ladder gates
on the count of completed ordinary rallies now, not on a star total, see
[star-economy.md](star-economy.md)): a special event unlocks it, so it is
deliberately a reward that makes hard events easier rather than a stat that
reshapes the car.

**It is ONE part.** It was a four-rung ladder (NOS stage 1-4), each rung replacing
the last and each gated on its own showdown special. That is collapsed to a single
part carrying the top rung's numbers: the intermediate steps were changes the player
could not feel (0.22 to 0.24 boost between the first two) and each one consumed an
entire special's prize slot to deliver. It is gated on the **first** showdown the map
reaches, not the last — the endgame is completing every special, so a part gated on
the final one would be a reward with no game left to spend it in.

Three properties define it, and every design decision below falls out of them:

1. **It is a per-STAGE resource with no persistent spent state.** The tank is
   refilled to full by `EngineSim.reset()`, which runs at every stage start *and*
   at every in-stage reset-to-start. A stage therefore never begins with less
   than a full tank — so there is nothing to carry between events and no
   reset-to-refill exploit to defend against.
2. **It is invisible to the performance model.** It never reaches
   `UpgradeLibrary.effective_meta`, so fitting it cannot move a car's
   power-to-weight, its rally eligibility or the rival
   pace floor. Winning the last rung of the ladder can never lock you out of a
   rally you could previously enter.
3. **It has an ordinary garage row.** It did not: the slot was hidden and the part
   auto-fitted enabled, on the reasoning that a ladder always installing its highest
   rung left nothing to decide. With one part there IS something to decide — fit it
   or don't — and without a row a won bottle could only ever be fitted by the award
   path, never by the player. It is also still named, read-only, on the car-stats
   readout: `hq.gd::_car_stats_text`
   (shared by the tuning lift and the car-park lineup — see [tuning.md](tuning.md))
   appends `UpgradeLibrary.fitted_nitrous_id(owned)`'s name after the health
   segment, omitted entirely when the car has none, so the player can tell a
   nitrous-fitted car apart from a bare one without opening the (nonexistent)
   menu row for it.


## The catalogue side — its own slot

`UpgradeLibrary.SLOTS` gained a `"nitrous"` entry (a fifth at the time; the list has since
grown `gearbox` and `tires` — see [upgrade-catalogue.md](upgrade-catalogue.md)). It could not join the
`turbo` slot: one part per slot is *enabled* per car
(`Save._enable_exclusive`), which would have made nitrous mutually exclusive
with the turbo and the supercharger — exactly wrong, since nitrous is meant to
stack on top of whatever induction the car carries.

The slot behaves like every other one: it gets an ordinary tile on the upgrades grid
(`UpgradeOptions.grid_slots()` → `scripts/upgrades_grid.gd`), the part
installs **disabled** and the player enables it, and the single authored entry is gated
on winning its special via `unlocked_by_rally` (see
[upgrade-catalogue.md](upgrade-catalogue.md) and [rally-roster.md](rally-roster.md)).
The exact id, gate and magnitudes are authored in `UpgradeLibrary.UPGRADES`; read the
table rather than trusting a number quoted here.

**`UpgradeLibrary.HIDDEN_SLOTS` is now EMPTY.** Nitrous was its only member. The rule it
carries is real — a part in a slot with no garage row must install *enabled*, or it would
be permanently dead — and the code path survives in `Save.install_upgrade`, dormant. Since
no slot claims it, no test can exercise it end-to-end; `test_no_slot_is_hidden_so_every_part_installs_as_asked`
asserts the dormancy so it is visible rather than silent.

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
| `chase_fov_nitrous_boost` | extra chase-camera FOV (degrees) while delivering — presentation only, no physics. Lives with the other `chase_*` camera fields, not with the two above. |
| `shake_nitrous_gain` | camera-shake intensity while delivering. Also presentation only; lives with the other `shake_*` fields. |

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

A **violet** radial ring gauge (`NitrousGauge`, a `HudGauge` — see [hud.md](hud.md))
in the same family as the health and boost gauges: a pressure-bottle icon
(`GaugeIcons.Kind.NOS`) in the ring's hole rather than a text caption, `fill_color`
tinted via the shared `_gauge_color`, and visible **only** when nitrous is fitted
rather than sitting at zero.

`_NITROUS_HUE := 0.70` sits beside `_BOOST_HUE := 0.58` and deliberately differs
from it: a turbocharged car with nitrous shows **both** gauges at once, and two
near-identical blues would be unreadable mid-stage. The shared `_GAUGE_SAT` /
`_GAUGE_VAL` keep it a sibling of the other two. Layout is a row, not a stack:
health sits centred at the bottom with boost to its left and nitrous to its right.

Both answers come from the model — `Config.data.has_nitrous()` for "is it
fitted", `EngineSim.nitrous_fraction()` for "how much is left" — and the write is
change-gated on the **rounded integer percent** (`_last_nitrous_pct`, `-1`
meaning not fitted), so a continuous drain only touches the bar when the reading
actually moves. Unlike boost, the bar drains rather than tracking a live reading.
See [hud.md](hud.md).


## The camera punch (`chase_camera.gd`)

While nitrous delivers, the chase camera adds a **fixed**
`GameConfig.chase_fov_nitrous_boost` degrees to its field of view, eased in and out on the
usual `chase_fov_smoothing` weight, and feeds `shake_nitrous_gain` into the camera shake for
as long as it lasts. Like the audio bridge, both read the latched `nitrous_delivering` and
not `nitrous_active`, so the view only reacts when torque is really being made.
`_nitrous_delivering()` is deliberately NOT gated on `chase_fov_nitrous_boost` — it answers
"is nitrous delivering", and folding the FOV consumer's disable switch into it silently
killed the shake. See [camera.md](camera.md) → "Nitrous FOV punch" for why the amount is
fixed rather than speed-scaled, and how it interacts with the dolly zoom.


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

**Mix level:** `GameConfig.engine_nitrous_hiss_gain`, cached into
`engine_audio_synth.gd` → `_nitrous_hiss_gain` by `configure()`. The local
`NITROUS_HISS_GAIN` constant is only the fallback for a bare synth with no config applied
(i.e. a test). Filtered noise carries a lower RMS than a tonal wavetable, so the layer levels
sit nearer `TURBO_WHISTLE_LEVEL` than `TURBO_TONE_LEVEL`.

It ships at **0.25** in `config/game_config.tres`, down from the `0.7` script default. Worth
knowing why, because 0.7 sounded fine in isolation: `engine_turbo_whistle_gain` and
`engine_supercharger_whine_gain` both ship at **0**, so nitrous is the only layer of that
family actually audible, and a level chosen against its siblings-on-paper was far too loud
against the engine alone. Retune it in the `.tres`, and judge it against the mix it actually
plays in.


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
hit-test priority over the simple steering halves), `test_engine_audio.gd`
(the synth layer and its edges), `test_chase_camera_fov.gd` (the FOV punch appears while
delivering, eases back out on release, is NOT triggered by the button alone, and a target
with no drivetrain is safe) and `test_chase_camera_shake.gd` (delivering shakes the camera;
the button alone does not).

Per `CLAUDE.md`, do **not** pin the authored magnitudes — tank seconds, torque
gains, which rung hangs off which special event, the hue value. Test the behaviour that
must hold for any reasonable values: the tank starts full after `reset()`, the
multiplier applies only while held with charge, an empty tank applies none,
`effective_meta`'s power-to-weight is unmoved by fitting nitrous, and the part
installs enabled so it works with no menu interaction.
