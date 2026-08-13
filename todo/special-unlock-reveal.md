# Special-event unlock reveal

Status: **IMPLEMENTED.** `scripts/podium.gd` has `Stage.SPECIAL_UNLOCK` in its stage enum,
appended conditionally, rendered by `_show_special_unlock()`; `scripts/rally_session.gd`
builds a `special_unlock` payload via `RewardSystem.grant_special_unlock`.

When the player completes a **special event** for the first time, give them a big reveal
naming the upgrade it unlocked — and award that upgrade to the car they just drove.

Today a special silently opens a gate: `UpgradeLibrary.rally_gate_met`
(`upgrade_library.gd`) checks `profile.rallies[rid].completed`, which lets
`RewardSystem._eligible_parts` (`reward_system.gd`) start drawing the gated part. The
player is told nothing at the moment it happens.

**`completed` means a TOP-3 finish, not merely finishing.** `Save.complete_rally` is only
called inside the `if top3:` branch of the resolve path (`rally_session.gd`), so the
gate — and therefore this reveal — is earned by placing, not by turning up. Anywhere below
that says "completed", read "finished top-3". The map pin advertises what a special
*will* unlock beforehand; nothing marks the unlock itself.

## Decisions (agreed)

| Question | Decision |
|---|---|
| Placement | **A new podium stage**, between `LEADERBOARD` and `CAR_REVEAL`. |
| Semantics | **Announce it as now winnable AND award the upgrade to the car that just ran the rally.** |
| Missing prerequisite | **Silently unlock/grant the prerequisite** so the awarded part has something to sit on. |
| Presentation | **Distinct "big" treatment** — deliberately NOT the routine per-event upgrade card. |

## 1. Trigger — first completion, once

The unlock happens on `completed`, so the reveal must fire on the **transition** to
completed, not on every subsequent run of the same special. Two things follow:

- Whatever writes `completed` (the rally-resolve path in `scripts/rally_session.gd`) has to
  report whether *this* finish was the first, because afterwards the profile can't tell.
  Add the answer to `last_result()` — the podium already reads its whole summary from
  `RallySession.last_result()` (`podium.gd` header), so that is the natural channel.
- The reveal is skipped entirely when the finished rally isn't a special, or when the
  special was already completed. A replayed special must not re-award the part.

`UpgradeLibrary.unlocked_by(rally_id)` (`upgrade_library.gd:253`) already returns the item a
given special gates — its docstring anticipates exactly this surface ("a reveal banner or
podium line tomorrow"). Use it; do not add a second walk. It returns `{}` for a special that
gates nothing, which must also skip the stage.

## 2. The award, and the prerequisite cascade

The eight gated items form **ladders with per-car prerequisites**
(`UpgradeLibrary.requires_upgrade_id` / `prerequisite_met`, `upgrade_library.gd:274-285`):

| Item | Requires |
|---|---|
| `turbo_large` | `turbo_small` |
| `supercharger` | `turbo_large` |
| `nitrous_tank` | `nitrous` |
| `nitrous_shot` | `nitrous_tank` |

`prerequisite_met` is **per-car** — it reads that car's `installed_upgrades`. So awarding
`turbo_large` to the car that just won is meaningless if that car has no `turbo_small`.

**Agreed rule: silently grant the missing prerequisites too**, walking the
`requires_upgrade_id` chain down until it is satisfied, so the awarded part always has
something to sit on. Notes for implementation:

- Walk the chain, don't special-case the turbo — `nitrous_shot` can be two rungs up.
- The cascade is **silent**: the reveal names only the part the special unlocked. Listing
  the incidentally-granted rungs would bury the headline.
- Grant them the way the existing reward path does — `UpgradeReveal`'s normal parts are
  granted **fitted-disabled** to the driven car (see `upgrade_reveal.gd` header), so the
  player enables them in the upgrades menu. Match that; do not silently enable.
- Guard the already-fitted case: if the car already holds the part, award nothing and just
  announce (or skip — decide during implementation and say which).

**Balance consequence, accepted:** eight guaranteed parts across a playthrough, sometimes
more via the cascade. Specials become materially more rewarding than they are today.

## 2b. Remove the car reward for specials

With a guaranteed upgrade (plus any cascaded prerequisites) a special that ALSO hands over a
car is too much in one sitting. Specials stop drawing a car.

**Where.** `rally_session.gd:511-538`. The `if top3:` block already contains exactly this
carve-out for one case:

```gdscript
var is_final_special := RallyLibrary.is_special(_rally) \
    and RallyLibrary.all_specials_completed(Save.profile)
if is_final_special:
    # ... no car draw (the finale rewards completion, not a car).
else:
    var model: Variant = RewardSystem.draw_car(...)
```

So this change **generalises an existing precedent** rather than inventing one: widen the
no-car branch from "the final special" to "any special". `is_final_special` still matters
independently — it fires `game_won` / the credits — so the two conditions stay separate:
specials skip the car draw; the *last* special additionally fires the win beat.

`Save.complete_rally` must keep running for specials — it is what sets `completed` and so
what opens the upgrade gate and this reveal. Only the `draw_car` / `grant_car` /
`car_rewarded` trio is dropped.

**The podium's CAR_REVEAL stage then self-skips** for specials: it is already conditional on
a car having been won (`podium.gd` header — "Skipped if no car was won"), so an empty
`car_reward` needs no podium change. A special's podium becomes
PODIUM → LEADERBOARD → SPECIAL_UNLOCK, which reads better than three reward beats.

**Caveat worth a decision, from the code's own comment.** The line being changed currently
justifies itself as:

> Specials pay out exactly like ordinary rallies, which also keeps them safe from
> soft-locking a player who needs a car.

**DECIDED: removing that safety net is accepted.** The reasoning it rests on: ordinary
rallies remain a renewable car source (the draw fires on **every** top-3 finish, re-wins
included), so a player short of a car can always re-win one, and the star ladder means
specials only ever unlock alongside plenty of ordinary rallies. The residual case — a player
with *only* specials left and no eligible car for any of them — is accepted as not worth
guarding against. Do NOT re-add a special-case car draw for it; if it ever bites, the fix
belongs in the eligibility/soft-lock safety net that already exists for ordinary rallies
(`RewardSystem.any_car_has_room` and the wreck safety net in `hq.gd`), not here.

## 3. Presentation

A distinct full-screen milestone card, not the slot-machine reel. The reel implies
randomness and this outcome is fixed — the part is determined by which special was won.
Reuse `UpgradeReveal.card_width` (`podium.gd:463` already calls it) for consistent framing,
but not `start_spin`.

Content: the part name, what it does, and that it now appears in rally rewards. The podium's
single "Next" button steps past it like every other stage.

## 4. Where the code goes

- `scripts/podium.gd` — a `SPECIAL_UNLOCK` value in `enum Stage` (`podium.gd:21`) between
  `LEADERBOARD` and `CAR_REVEAL`, plus its build/enter/exit. Skipped when there is nothing
  to reveal, exactly as `CAR_REVEAL` is skipped when no car was won.
- `scripts/rally_session.gd` — surface "this finish first-completed a special" in
  `last_result()`.
- The grant itself belongs beside the existing reward-granting logic
  (`RewardSystem.draw_and_grant_upgrade`, `reward_system.gd:110`) rather than in the podium:
  the podium should *display* a decision already made, so a headless run resolves progression
  identically without building the scene.

## 5. Tests

Per `CLAUDE.md`: no asserting authored values, no depending on a specific catalogue entry.
Build synthetic upgrade/rally data where the rule needs a shape.

- **Fires once.** Completing a special the first time yields the reveal; completing it again
  does not, and does not re-award.
- **Not for ordinary rallies.** An ordinary rally finish produces no unlock stage.
- **The cascade satisfies the prerequisite.** Award an item whose `requires_upgrade_id` chain
  is unmet on the driven car; assert `prerequisite_met` holds afterwards for the awarded
  item. Assert the *relationship*, not which parts appeared — that keeps it true if the
  ladders are re-authored.
- **The cascade terminates** on a chain with no prerequisite, and doesn't loop.
- **Granted fitted-disabled**, matching the existing reward path — not enabled.
- **Podium skips the stage** when `UpgradeLibrary.unlocked_by(rally_id)` is `{}`.
- **A special awards no car**, an ordinary top-3 finish still does. Assert on the presence of
  a car reward, not on which car — the draw is seeded and the roster is tunable.
- **`completed` is still recorded for a special** despite the dropped car draw, since that is
  what opens the upgrade gate. This is the regression the change could easily cause.
- **The final special still fires `game_won`** with no car — the pre-existing behaviour must
  survive the branch being widened.
- Headless: the podium builds synchronously and resolves spins instantly (`podium.gd`
  header), so the stage must be steppable without animation.

## Dependencies

None blocking. `UpgradeLibrary.unlocked_by` and the fitted-disabled grant path both exist.

## Docs to update in the same work

- `features/reward-system.md` — specials now grant, not just gate; the cascade rule; and
  specials no longer draw a car.
- `features/upgrade-catalogue.md` — the prerequisite ladder can be satisfied by cascade.
- `features/menus.md` — the podium stage list (currently three stages).
- `todo/star-gated-special-events.md` — the ladder section, which describes gating only.
