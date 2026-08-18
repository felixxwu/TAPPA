# Star Economy — remaining work

**IMPLEMENTED.** Stars are spendable currency with a persisted ledger, cars no longer
drop from every rally win, and specials are completion-gated rather than star-gated.
The living docs (`features/reward-system.md`, `features/save-persistence.md`,
`features/rally-roster.md`) describe how it works; this file is only what's left.

Note the economy has since moved on from this spec's single "buy a random car" price:
stars are spent **per item** — `GameConfig.star_cost_per_repair`,
`star_cost_per_part`, `star_cost_per_drive_mode` (see `save_manager.gd`) — and there
is no `star_cost_per_car`. The old "surplus sink / raise the car price" item is
therefore moot and has been dropped.

## Open

1. **The Rally Challenge has no stars beat.** `challenge_session.gd` awards stars
   correctly (`Save.award_stars` on placement), but the challenge results screen never
   shows the three-star reveal the rally podium does, so a star earned in a challenge is
   paid silently. `podium.gd` → `_show_stars` / `_reveal_stars` is the pattern to share;
   the challenge award has no previous best, so its delta is simply the stars won.
2. **`podium.gd` `Stage.CAR_REVEAL` is not retired.** It is unreachable in real play —
   nothing sets `car_reward` any more — but the stage, `_show_car_reveal`,
   `_reveal_showroom_car`, `_start_slot` and the showroom/turntable props all still
   exist, and one test drives it through a synthetic result. Deleting it is safe.
3. **Unresolved from the original design:** the Challenge's reward threshold is the top
   HALF of the board while stars only pay the top 3, so a mid-table "placed" finish banks
   zero stars and walks away with only the boxes. Deliberate for now (the boxes are the
   consolation), but worth revisiting if it reads as a non-reward.
