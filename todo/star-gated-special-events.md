# Star-Gated Special Events — remaining work

**SHIPPED.** The star-gated special-event ladder, the eight specials and their map
placement, the gating seam, tier removal, the two `max_potential_meta` flavours,
nitrous (slot, sim, input, gauge, audio, mobile controls) and the endgame are all
implemented, and the docs are the living record —
[`features/nitrous.md`](../features/nitrous.md) plus `rally-roster.md`, `regions.md`,
`reward-system.md`, `upgrade-catalogue.md`, `rally-session.md`, `menus.md`,
`save-persistence.md`, `forced-induction.md`, `engine-swap.md`, `configuration.md`,
`hud.md`, `controls.md`, `mobile-controls.md`, `car-physics.md`, `engine-audio.md`.

Two of the three loose ends this file used to track have since landed:
`GameConfig.engine_nitrous_hiss_gain` is exported, authored, cached in
`engine_audio_synth.gd` and per-engine overridable via `engine_library.gd`; and both
engine-swap UI gates now consult `RallyLibrary.engine_swaps_unlocked` (`hq.gd` and
`upgrade_options.gd`). One item remains.

## Open: the nitrous first-use hint

Show a hint at stage start naming the nitrous button, **until the player presses it
once, then never again**.

- Needs **new save state**: a single once-per-profile flag, persisted so the hint
  doesn't return next session.
- Needs the **right glyph for the actual device**, and `Platform` has no
  keyboard-vs-controller distinction (only `is_touch` / `is_web` /
  `is_mobile_or_web` / `is_headless`). So it needs last-input-device tracking (a
  controller can be plugged in mid-session), or at minimum "controller if any
  joypad is connected, else keyboard".
- Suppress it entirely when nitrous isn't fitted, and don't fire it on the stage
  where the part is first won mid-rally if the car doesn't have it yet.
