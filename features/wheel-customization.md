# Wheel customisation (cosmetic wheel swap)

Any owned car can wear **any other car's wheels**, purely for looks. It's the third
customisation system alongside [tuning.md](tuning.md) (free, reversible handling
sliders) and [upgrade-catalogue.md](upgrade-catalogue.md) (won, committed parts) —
and it sits with tuning in spirit: **free, ungated and reversible**.

## The rules

- **Cosmetic only.** The swap carries the wheel **texture** and nothing else.
  `wheel_radius`, `wheel_width_front` / `wheel_width_rear` — and therefore ride
  height, load sensitivity and grip — always come from the car's **own**
  `CarLibrary` entry. A wheel change cannot move a single stat.
- **Free and ungated.** No currency, no token, no consumable, no confirm dialog.
- **Eligibility: only wheels from cars the player OWNS are on offer.** This
  reverses an earlier decision ("every car's wheels are always on offer,
  regardless of ownership") — a car not yet in the garage doesn't donate its
  wheels. The car currently being customized always keeps its own stock wheel
  option available regardless of ownership bookkeeping, so a player can always
  revert to their own car's stock look — even the very first car, before any
  other car has been acquired. Wheel choice is still not a *committed* reward
  (nothing is spent or consumed to fit a style you're eligible for) — it's
  gated on ownership, not on a separate unlock.
- **Separate from the engine swap** ([engine-swap.md](engine-swap.md)): it borrows
  that system's *shape* but none of its code and none of its token economy.
- **No per-axle staggering.** One selection re-skins all four wheels. (The
  *physical* stagger stays — `wheel_width_front` / `_rear` still differ per car.)

## Why this is a texture swap

Wheels aren't part of any car's `.glb`. Each car's glb supplies only the body;
wheels are procedural `CylinderMesh` cylinders on `VehicleWheel3D` nodes, skinned
from a texture path. `car_library.gd`'s `CARS` table carries a **`wheel_texture`**
per car, and `car.gd` → `_relocate_wheels` is the single place a wheel visual is
built. So there's no rigging or wheel-well fitment problem: any wheel texture
already works on any body.

## Where it lives

| Piece | Where |
|---|---|
| Resolution rules | `scripts/wheel_style.gd` (`WheelStyle`) — `current_wheel_id`, `texture_for`, `options_for(stock_model_id, profile)`, `option_index` |
| Style catalogue | `scripts/car_library.gd` → `wheel_catalogue(profile)` — derived from `profile["cars"]` (owned cars only), no authored wheel table |
| Persistence | `scripts/save_manager.gd` → `set_wheels()` |
| Applied to the car | `scripts/car.gd` → `_owned_wheel_texture`, `_wheel_texture_for`, `reskin_wheels` |
| The wheel view | `scripts/hq.gd` → `CarparkMode.WHEELS`, `_enter_wheel_swap`, `_cycle_wheel`, `_apply_wheel_preview`, `_revert_wheel_preview`, `_commit_wheels` |
| Entry button | `scripts/tuning_panel.gd` → `TuningPanel._wheels_button` (inside the Tuning menu; wired via `setup(owned, on_change, on_wheels)`) |
| Camera framing | `scripts/hq.gd` → `_camera_target_xform`; `hq_wheel_cam_offset` / `hq_wheel_cam_look_height` in `GameConfig` |
| Tests | `tests/headless/test_wheel_customization.gd` |

## Data model

One **optional** key on the OwnedCar dict:

```
"wheels": "<donor CarLibrary model id>"   # absent = the car's own (stock) wheels
```

`Save.set_wheels(instance_id, wheel_id)` normalises **stock to an absent key** (an
empty id, or the car's own `model_id`, erases it). That matters: it keeps
`owned.hash()` — the key the HQ car-prop caches use — identical to a
never-customised car, so a revert invalidates the cached prop exactly as a fit does.

**No schema migration.** `_migrate` / `_default_profile` only backfill *top-level*
profile keys, and an absent per-car key already means stock — the same convention
`swapped_engine` uses. Old saves load unchanged.

A style id is a **donor car's stable id**, so it always resolves through
`CarLibrary.by_id`. `WheelStyle.texture_for` falls back to the car's own texture
when the id is unknown, so a donor that gets renamed or dropped from the roster
degrades to stock rather than to a blank disc.

## Apply path

`car.gd → apply_owned` resolves `WheelStyle.texture_for(owned, model_id)` into
`_owned_wheel_texture` **before** calling `apply_car`, so `_relocate_wheels` skins
the wheels with the donor's texture in the same pass it sizes them (via
`_wheel_texture_for`). The override is cleared at the end of `apply_owned` — the
same pattern as `_owned_drive_override` — so a later **bare** `apply_car` (free
roam, props, opponents) always shows stock wheels.

`car.gd → reskin_wheels(tex_path)` repaints the tyre caps in place without touching
geometry, physics or the pose — that's the live try-on. Pass `""` to restore stock.
Contrast `_relocate_wheels`, whose wheel detach/re-attach dance exists only to
re-latch moved suspension connection points.

## The wheel view

**Not the tuning lift** — the lift holds the car **raised** off its suspension, and
wheels are judged by *stance*. So wheel-swapping happens in the **car park**, where
`hq_carpark.gd → _spawn_lineup_progressive` places each car frozen at its analytic rest
height and then droops its wheels onto the lot floor with a real raycast
(`settle_wheels_to_ground`). The car is genuinely sitting on its springs.

`_enter_wheel_swap` (from the Tuning menu's **Wheels** button) parks `_lift_owned`
**alone**: a one-element lineup, which `_render_lineup_page` centres in the bays, so
no neighbour competes for the frame. `_camera_target_xform` swaps in the low side-on
`hq_wheel_cam_offset` framing while the mode is live.

- **Cycling** — `_cycle_focus` hands left/right to `_cycle_wheel` in this mode (a
  solo lineup has no bays to page), which wraps the cursor and previews the style on
  the car via `_apply_wheel_preview`. Deliberately bypasses `_focus_changed`: the
  focused car never changes, and that path would rev the engine and overwrite the
  wheel name label on every flick. The stats line under the wheel name reads "Unlock
  more wheels by owning more cars." — it surfaces the eligibility rule (own more
  cars to widen the style list), not the cosmetic-only guarantee (that's still true,
  just no longer what this particular label says).
- **Fit** — the action button (`_commit_wheels`) writes the style and returns to the
  lift. The stock option commits as an erase.
- **Back** — `_car_back` calls `_revert_wheel_preview` **before** `_clear_lineup`.
  This is load-bearing: the node survives in `_car_cache` under an unchanged
  `owned.hash()` (nothing was saved) and the lift borrows that *same* node, so an
  uncommitted preview would otherwise reappear on the lift.
- **Damage never gates it.** `_refresh_focus_damage` exempts `WHEELS` — now the only
  exemption from the wrecked-car gate, since the GARAGE picker mode it used to sit
  beside is gone — a wrecked car can always be re-shod.

## Navigation

The car park is a spatially-navigated 3D view, so this follows the
`hq.gd._unhandled_input` → `_cars_input` action pattern rather than
`MenuNav.attach` (see [menus.md](menus.md) → *Menu navigation*):

- `menu_left` / `menu_right` **and** `menu_up` / `menu_down` step the style list —
  the list reads vertically, so both axes are bound. All four are keyboard **and**
  gamepad actions.
- `menu_select` fits; `menu_back` discards and returns to the lift.
- The ◄ ► nav-row buttons and the swipe gesture route through `_cycle_focus`, so
  they cycle styles for free. Tap-to-focus (`_focus_car_at`) is a no-op here.
- The Tuning menu's **Wheels** button is a native `FOCUS_ALL` button (like the
  handling sliders and Reset to neutral), so it's reachable by keyboard/gamepad and
  not only by pointer. It sits in the Tuning page's **bottom action row** beside
  `< Back` and Reset — `TuningPanel` builds it but the HOST parents it
  (`TuningPanel.action_buttons()`; see [tuning.md](tuning.md)) — not as a full-width row
  inside the panel body.
