# Detuned cars vs. rally minimum power-to-weight

## Why this exists

As of the "remove the auto-detune button" change, a car that the player detunes
(or ballasts) to squeak under a rally's `pw_max` ceiling now keeps that change
**permanently** — it's an ordinary garage edit, no longer a temporary,
per-rally, auto-reverted agreement. (Previously `hq._on_detune_confirmed` /
`start_line._apply_detune_and_launch` applied a one-off detune and registered it
with `RallySession.register_detune_revert` to undo it when the rally ended; both
of those paths are gone.)

The consequence: a car the player dropped to a low power-to-weight to enter a
low class can now **fail the minimum** (`pw_min`) of a higher-class rally,
because its stored `engine_detune` / ballast is still in effect. Nothing
auto-restores full power, and the player may not realise their car is
artificially weak.

## Where the minimum lives (real code)

- Rally bands are authored in `scripts/rally_library.gd` (`RALLIES`), e.g.
  `"restriction": {"pw_min": 91.0, "pw_max": 180.0}` (`rally_library.gd:87`).
  Many rallies carry a `pw_min` floor (see lines 87, 99, 109, 120, 135, 145,
  156, 189, 199, 209).
- `RallyLibrary.ineligibility_reason` (`rally_library.gd:299`) returns
  `"Power-to-weight too low (…, min …)"` when `pw < pw_min` (`:316`).
- `RallyLibrary.is_eligible` (`:323`) is the boolean form.
- The p/w figure comes from `UpgradeLibrary.effective_meta`, which folds in the
  stored `tuning.engine_detune` and the weight-slot `mass_mult` (ballast /
  lightweight) — so a detuned or ballasted car reads a lower p/w everywhere,
  including this floor check.
- `RallyLibrary.qualifying_detune` (`:337`) only ever LOWERS power to clear a
  `pw_max`; it explicitly returns `-1.0` when the resulting figure would fall
  under a `pw_min` floor (`:335-336`, `:350`). There is no "un-detune to reach a
  minimum" counterpart.

## The problem to solve

Let a car that was detuned/ballasted still field in a rally with a `pw_min`,
rather than being silently locked out because of its own earlier down-tune.

## Options (brainstorm with the user before implementing)

1. **Remove `pw_min` floors entirely.** The simplest fix: delete `pw_min` from
   the authored restrictions and drop the floor branch in
   `ineligibility_reason` (`:316-317`) + `qualifying_detune`'s floor guard.
   Rally classes would then be gated only from above (`pw_max`). This is the
   candidate the user floated as "a very simple fix." Trade-off: loses the
   "can't walk an easy rally in an overpowered car" framing that the band
   comments (`rally_library.gd:74-76`) describe — though `pw_max` already
   prevents the *over*-powered case; `pw_min` only stops *under*-powered entries,
   which matters less.

2. **Auto-restore enough power at the eligibility check.** When a car fails only
   `pw_min`, treat it as eligible if it *would* pass at a higher detune / with
   ballast removed (mirror `qualifying_detune` upward), and either prompt the
   player to un-detune (like the old over-power prompt, but in reverse) or field
   it at the restored figure for that rally.

3. **Make the detune-to-enter temporary again, but per the new UI.** Keep the
   permanent garage change, but when a car enters a rally *below its natural
   class* because of a manual detune, offer a one-tap "restore for this rally"
   the same way the removed agreement worked — reusing the still-present
   `RallySession.register_detune_revert` machinery (`rally_session.gd:499`,
   currently caller-less in production but unit-tested in
   `test_rally_session.gd`).

## Recommendation

Start by discussing whether `pw_min` earns its keep at all (option 1). If the
design still wants a floor, option 2 keeps it meaningful without trapping the
player. Option 3 re-introduces temporary state we just removed, so prefer it
only if the "permanent change" model proves confusing in playtesting.

## Dependencies

None — the auto-detune removal it stems from has already landed. Touches
`RallyLibrary` (restrictions + eligibility) and, for options 2/3, the start
gates in `scripts/hq.gd` (`_on_start_pressed` / `_show_over_limit_prompt`) and
`scripts/start_line.gd` (`launch`).
