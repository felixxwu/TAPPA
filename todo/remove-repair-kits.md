# Remove Repair Kits

**Status:** planned. The Repair Kit consumable is being retired. Repairs now happen
**automatically between events** (`Save.field_repair`, driven by
`RallySession._enter_event` — see `scripts/rally_session.gd:392-400`), so the
player-spent Repair Kit is redundant. Kits already never drop
(`RewardSystem.REPAIR_KIT_DROP_WEIGHT := 0`, `scripts/reward_system.gd:23`), and the
lift-HQ "Repair" button is already **hidden** (`scripts/hq.gd` `_build_lift_overlay`,
`repair.visible = false`). This spec is the full teardown so no dead repair-kit code is
left behind.

## Open design questions (resolve before implementing)

1. **Anti-soft-lock replacement.** Repair Kits currently back the anti-soft-lock floor:
   `Save.ensure_repair_safety_net()` (`scripts/save_manager.gd:315`) grants a free kit
   when every owned car is wrecked and none is held, and `Save.can_scrap_car` keeps at
   least one car so the net always has something to bring back
   (`scripts/save_manager.gd:333`). If kits go away, a car wrecked to HP 0 needs some
   OTHER guaranteed recovery path. Options: auto-restore a wrecked car to full HP on
   return to HQ; or make between-event `field_repair` a *full* restore instead of the
   current partial slice (`field_repair_hp_fraction` 0.3 / `field_repair_toe_fraction`
   0.6 in `config/game_config.tres`). **Decide this first** — it determines whether
   `ensure_repair_safety_net` is deleted outright or replaced.
2. **Wrecked-car gating.** The car park blocks entering a wrecked car and offers an
   in-place Repair (`scripts/hq.gd` `_evaluate_focused_car` ~line 2686, `_car_repair_button`,
   `_repair_focused_car` ~line 2855). With no kits, either wrecked cars can't exist at
   rest (see #1) or the gate needs different wording / a different recovery action.
3. **Save migration.** Existing saves may hold `repair_kit` entries in `profile.inventory`.
   Decide whether to strip them in a `SaveManager` migration bump (the existing v1→v2
   migration at `scripts/save_manager.gd:220-232` is the template) or just leave them
   inert.

## Code touchpoints to remove / update

### Catalogue
- `scripts/upgrade_library.gd:18` `REPAIR_KIT_ID` const, `:70` the `"Repair Kit"` CARS
  catalogue entry, and the surrounding comments (`:17`, `:21`).

### Save / inventory (`scripts/save_manager.gd`)
- `use_repair_kit()` (`:564`) — delete (nothing spends kits once the UI is gone).
- `ensure_repair_safety_net()` (`:315`) — delete or replace per open question #1;
  callers are `SaveManager._ready`-time load (`:89`) and `scripts/hq.gd` (2 calls:
  `_refresh_lift_repair_button`, `_refresh_lift_ui`).
- KEEP `field_repair()` (`:588`) — this is the automatic between-event repair, the
  mechanic that replaces kits. It doesn't touch inventory.
- Update the header comment (`:4`, "the consumable inventory (repair kits)") and the
  scrap safety-net comment (`:333`).
- Migration: strip `repair_kit` from `inventory` if open question #3 says so.

### Reward pool (`scripts/reward_system.gd`)
- `REPAIR_KIT_DROP_WEIGHT` (`:23`) and the `pool.append({...REPAIR_KIT_ID...})`
  (`:69`) — delete; scrub the comments (`:20-22`, `:55-59`, `:65`, `:75`).

### HQ menus (`scripts/hq.gd`)
- Lift HUB Repair: `_lift_repair_button` field (`~:186`), the hidden button built in
  `_build_lift_overlay` (`~:1081-1089`), `_refresh_lift_repair_button()` (`~:1935`),
  `_repair_selected_car()` (`~:1961`), and the `_refresh_lift_repair_button()` call in
  `_refresh_lift_ui` (`~:2087`). Also the header-comment note (`~:20-21`) and the
  `_move_hub_focus` comment (`~:1982`).
- Car-park wrecked-car repair: `_car_repair_button` (`~:252`, built ~`:1176`),
  `_repair_focused_car()` (`~:2855`), `_repair_kits_owned()` (`~:2118`), and the
  wrecked-car warning/gating in `_evaluate_focused_car` (`~:2686-2707`) — rework per
  open question #2.
- Starter-comment (`~:355`) referencing the repair-kit safety net.

### Dev / settings (`scripts/settings_menu.gd`)
- Dev-page "Fit an upgrade … (repair kit -> inventory)" affordance (`:165-170`) and the
  "Drop a consumable (the repair kit)" helper (`:497`) — remove or repurpose.

### Win-a-kit-spend-now flow (`scripts/upgrade_reveal.gd`)
- The reveal offers to spend a just-won kit on a damaged car (`:168-169`, `:215`).
  Since kits no longer drop, remove this branch.

## Tests to update
- `tests/headless/test_save_manager.gd`, `test_upgrade_library.gd`,
  `test_upgrade_reveal.gd`, `test_menu_flow.gd`, `test_lineup_cache.gd` all reference
  `repair_kit` / `use_repair_kit` / `ensure_repair_safety_net` / `REPAIR_KIT_ID`.
  Rewrite them around the new auto-repair story (per project testing rules: assert the
  behaviour that must hold — "a wrecked car is recoverable" — not the removed mechanic).

## Docs to keep in sync
- `features/damage.md`, `features/reward-system.md`, `features/save-persistence.md`,
  `features/upgrade-catalogue.md`, `features/menus.md` — scrub Repair Kit references and
  document auto-repair as the recovery mechanic.
</content>
</invoke>
