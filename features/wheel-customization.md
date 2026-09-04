# Wheel customisation (cosmetic wheel swap)

Any owned car can wear **any other car's wheels**, purely for looks. It's the third
customisation system alongside [tuning.md](tuning.md) (free, reversible handling
sliders) and [upgrade-catalogue.md](upgrade-catalogue.md) (won, committed parts) —
and it sits with tuning in spirit: **free, ungated and reversible**.

**Tests:** `tests/headless/test_wheel_customization.gd`, `tests/headless/test_wheel_texture_imports.gd`

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
| The wheel view | **DELETED** with the diegetic hub — it was `hq.gd` → `CarparkMode.WHEELS` (`_enter_wheel_swap`, `_cycle_wheel`, `_apply_wheel_preview`, `_revert_wheel_preview`, `_commit_wheels`). No screen fits wheels today |
| Entry button | `scripts/tuning_panel.gd` → `TuningPanel._wheels_button` (inside the Tuning menu; wired via `setup(owned, on_change, on_wheels)`) |
| Camera framing | Deleted with it; `hq_wheel_cam_offset` / `hq_wheel_cam_look_height` survive in `GameConfig`, unread |
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

## The wheel view is DELETED — what a rebuild owes

There is **no screen that fits wheels today.** `TuningPanel` still builds the **Wheels**
button, but it is hidden whenever the host wires no `on_wheels`, and no host does
([tuning.md](tuning.md)). Everything below the data model still works: the catalogue, the
eligibility rule, `Save.set_wheels`, and the apply path. Only the way in is gone.

These are the decisions the deleted view had made, all of them earned, and a rebuild
should not re-derive them from scratch:

- **Not on a lift.** The old tuning lift held the car RAISED off its suspension, and
  wheels are judged by **stance**. The wheel view parked the car in the car park instead,
  frozen at its analytic rest height with its wheels drooped onto the floor by a real
  raycast (`settle_wheels_to_ground`) — genuinely sitting on its springs.
- **Alone in frame.** It parked a one-element lineup so no neighbour competed for the
  shot, and swapped in a low side-on camera framing for the duration.
- **Cycling previews live**, and deliberately bypassed the normal focus-change path: the
  focused car never changes, and that path would have revved the engine and overwritten
  the wheel-name label on every flick.
- **Back DISCARDS the preview, and the order matters.** `_revert_wheel_preview` ran
  BEFORE the lineup was cleared, because the car node survived in a cache under an
  unchanged `owned.hash()` (nothing was saved) and the lift borrowed that *same* node — so
  an uncommitted preview would otherwise have reappeared on the lift. **This was a bug
  first.** Any host that previews on a shared/cached node inherits it.
- **Re-entering after an early back-out must rewire cleanly** — also a bug first.
- **Damage never gates it.** A wrecked car can always be re-shod.
- **The label surfaces the eligibility rule** ("Unlock more wheels by owning more cars"),
  not the cosmetic-only guarantee.

Its 17 tests went with it; the 20 host-free ones in
`tests/headless/test_wheel_customization.gd` remain and cover the whole feature minus its
UI. See [testing.md](testing.md) → *The `test_menu_flow.gd` salvage*.

## Navigation, when it is rebuilt

The old view was a spatially-navigated 3D screen, so it followed the deleted hub's
`_unhandled_input` action pattern rather than `MenuNav.attach`. A flat rebuild uses
`MenuNav` like every other page ([menu-navigation.md](menu-navigation.md)). What to keep
either way:

- **Both axes step the style list.** The list reads vertically but a car park reads
  horizontally, so left/right AND up/down were both bound — all four keyboard and gamepad.
- **Select fits; Back discards** (see the ordering trap above).
- **The entry button is natively focusable.** `TuningPanel`'s Wheels button is `FOCUS_ALL`
  like the sliders, so it is reachable by keyboard/gamepad and not only by pointer, and it
  sits in the page's bottom action row beside `< Back` and Reset — `TuningPanel` builds it,
  the HOST parents it (`TuningPanel.action_buttons()`, [tuning.md](tuning.md)).
