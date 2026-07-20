# Reactive Save store — observable state, self-updating panels

> **STATUS: SHELVED (2026-07-20).** Two Fable-5 reviews concluded this refactor
> solves a mostly *theoretical* problem: because `get_car()` returns live dict
> references, panels' `_owned` IS the stored state, so state can't desync — only
> painted widget pixels can, and hidden panels already reconcile via the host's
> `setup()`/`refresh()` on open. The proposed `_writing` echo-flag also trades a
> benign failure (stale label) for a nastier one (mid-drag rebuild dropping the
> slider grab). Decision: do NOT build the observable store until a real desync
> bug actually appears. The two genuine wins hiding in this spec were extracted
> separately:
> - **DONE:** `swap_engines` no longer burns a token on an identical-engine
>   (no-op) swap — `save_manager.gd`, test in `test_save_manager.gd`.
> - **NOT DONE (intentionally):** a lightweight `UpgradesMenu.refresh()` was
>   considered but has no current caller (all `rebuild()` callers are internal,
>   and `_on_detune_changed` already pokes in place) — it would be dead code, so
>   it was skipped.
>
> Everything below is the design as it stood when shelved; revive it only if the
> manual-refresh convention actually bites.

## Goal

Make `Save` (`scripts/save_manager.gd`) an **observable store** so UI panels
update themselves when the state they display changes, instead of relying on a
host to remember to call `refresh()`/`rebuild()` at the mutation site. This kills
the "forgot to update the UI" class of desync bug without touching how widgets
are built — the UI stays retained-mode and imperatively constructed.

This is deliberately the *smallest* reactive step. It is **not** data-binding and
**not** declarative components (both were considered and rejected as large
rewrites — Godot is retained-mode at its core, so a declarative layer means
building a reconciler and rewriting every menu, fighting the engine on focus and
the `MenuNav` framework the whole way). We add signals and subscriptions only.

## Decisions (agreed)

- **Scope:** observable store only. Widget construction (`hq.gd` builders,
  `SliderRow.build`, `TuningPanel`/`UpgradesMenu`) is unchanged.
- **Granularity:** per-domain signals (not one generic signal, not per-car-dirty).
  The signal list becomes a readable index of "what can change in game state,"
  and each mutator maps to exactly one signal.
- **Emit unconditionally after `save()`** — NOT emit-on-delta. (Emit-on-delta was
  the original plan; a Fable-5 review killed it — see "Why not emit-on-delta"
  below. Mutators keep their current *unconditional* `save()`, so persistence
  behaviour is unchanged; the `emit` is simply appended after `save()`.)
- **Loop-breaker is echo-suppression in the panel, not the store.** The editing
  panel sets a `_writing` flag around its own `Save.set_*` call and its handler
  early-returns while set. This stops the panel that made the edit from
  re-running its own (possibly rebuild-class) refresh mid-interaction.
- **Subscriber lifecycle:** connect once, never disconnect. Panels are built once
  at boot and live for the whole session, so this is their intended lifetime;
  Godot auto-disconnects if a panel is ever freed. **`setup()` runs on every
  open**, so guard the connect (`if not Save.x.is_connected(...)`) or connect in
  `_ready` — a bare `connect` in `setup()` errors on the second open.
  Handlers guard with three cheap early-returns (`_writing`, visibility, id).

## Why not emit-on-delta (the trap)

`get_car()` (`save_manager.gd:263-267`) returns the **live** dict from
`profile["cars"]` — no copy. Panels alias it: `_owned = Save.get_car(id)`
(`upgrades_menu.gd:246`). `TuningPanel._on_slider_changed`
(`tuning_panel.gd:88-94`) grabs `_owned["tuning"]` — the *same object* Save holds
— mutates it in place, then calls `Save.set_tuning`. A compare-before-write in
`set_tuning` would compare that already-mutated dict against a fresh copy of
itself → always equal → early return → **no save, no emit**. Slider edits would
silently stop persisting. So value-compare cannot live in the mutator without
also rewriting the panel write paths (which the scope forbids).

And the loop emit-on-delta was meant to prevent does not exist: panel `refresh()`
writes widgets via `set_value_no_signal` (`tuning_panel.gd`), which never writes
back to `Save`, so a handler calling `refresh()` cannot re-trigger a mutator. The
only real self-refresh hazard is the *editing* panel rebuilding mid-drag — solved
by the `_writing` echo guard, not by delta comparison.

## Signals

All carry `instance_id: int` to match the existing mutator signatures (mutators
key on `instance_id`, resolved via `get_car(instance_id)`), so a panel editing
one car ignores changes to another.

```gdscript
signal tuning_changed(instance_id: int)      # set_tuning, set_engine_detune
signal drivetrain_changed(instance_id: int)  # set_drivetrain_override
signal engine_changed(instance_id: int)      # swap_engines (fires for BOTH cars)
signal upgrades_changed(instance_id: int)    # set_upgrade_enabled, install
signal selected_car_changed(instance_id: int)# set_selected_car (real change only)
```

Signals are added incrementally — only wire the ones a panel actually subscribes
to in this work; the rest can follow when a consumer needs them. Do not emit a
signal with no subscriber "just in case."

- **`set_wheel_toe` is intentionally NOT mapped** — no panel displays toe, and
  `field_repair` (`save_manager.gd:588`) also writes it; per the no-orphan-signal
  rule above, leave it un-signalled until something consumes it.
- **`inventory_changed` deferred** — the token flows (`consume_item`/`add_item`,
  `save_manager.gd:486-496`) have no live subscriber yet, and emitting from
  `consume_item` mid-`swap_engines` would fire a signal while the swap is
  half-applied (token gone, engines not yet exchanged). Skip it for now; when a
  consumer needs it, emit it from the *outer* mutator after it completes, not
  from `consume_item`.

### Open detail (resolve in the plan, not here)

`set_engine_detune` writes into the per-car **tuning bag**, but detune is edited
in `UpgradesMenu`, not `TuningPanel`. Decide during implementation whether it
emits `tuning_changed` (matches storage) or `engine_changed` (matches the editor
that shows it) — driven by which panel needs to re-render, not by where the byte
lives. Default assumption: `tuning_changed`, and `UpgradesMenu` subscribes to it
for the detune row. NOTE the P1 interaction: `UpgradesMenu` has only `rebuild()`
(no `refresh()`), and `_on_detune_changed` (`upgrades_menu.gd:164-168`) updates
the label in place *specifically to avoid a rebuild dropping the slider's drag
grab*. So the detune subscription MUST be echo-suppressed via `_writing` (the
editing panel skips its own emission) — otherwise every drag tick rebuilds
mid-drag. If echo-suppression feels fragile for this case, the fallback is to
give `UpgradesMenu` a lightweight `refresh()` that pokes the detune label in
place instead of rebuilding, and subscribe that.

## Mutator pattern (emit unconditionally after save)

Current `set_tuning` writes unconditionally and calls `save()`:

```gdscript
func set_tuning(instance_id: int, tuning: Dictionary) -> void:
    var car := get_car(instance_id)
    if car.is_empty():
        return
    car["tuning"] = tuning.duplicate(true)
    save()
```

Reactive version — unchanged persistence, just append the emit (NO delta guard,
for the aliasing reason in "Why not emit-on-delta"):

```gdscript
func set_tuning(instance_id: int, tuning: Dictionary) -> void:
    var car := get_car(instance_id)
    if car.is_empty():
        return
    car["tuning"] = tuning.duplicate(true)
    save()
    tuning_changed.emit(instance_id)
```

Per-mutator notes:

- **`swap_engines`** (`save_manager.gd:359-375`): guard `cur_a != cur_b` BEFORE
  `consume_item` — today it consumes a token and returns `true` even when both
  cars run identical engines (a zero-delta swap that burns a token; fixing this
  is in scope). On the real-change success path, emit `engine_changed` for
  **both** ids after `save()`.
- **`set_selected_car`** (`save_manager.gd:440-454`): emit only on a real change.
  "No change" is *same id AND already at index 0* (the function also reorders the
  lineup, so same-id-but-not-front is still a change). Critically,
  `selected_car()` (`save_manager.gd:423-432`) SELF-HEALS by calling
  `set_selected_car()` — emitting from inside a getter invites re-entrancy
  (a read triggering a write triggering handlers). Route the self-heal through a
  non-emitting internal setter (e.g. `_set_selected_no_signal`), and only emit
  from the public `set_selected_car`.
- **`set_upgrade_enabled`** already returns a bool for "changed?" — gate the
  `upgrades_changed` emit on that existing result, no new comparison needed.
- Emit AFTER `save()` and after the mutator has fully applied its state, so a
  synchronous handler never observes half-applied state.

## Subscriber pattern (panels)

Panels connect once (idempotently) and guard in the handler:

```gdscript
# once — in _ready, or in setup() behind an is_connected guard
# (setup() runs on every open, so a bare connect would error the 2nd time):
if not Save.tuning_changed.is_connected(_on_tuning_changed):
    Save.tuning_changed.connect(_on_tuning_changed)

# wrap the panel's OWN writes so its handler skips its own emission:
func _on_slider_changed(value: float, axis: String) -> void:
    ...
    _writing = true
    Save.set_tuning(int(_owned.get("instance_id", -1)), tuning)
    _writing = false
    ...  # existing in-place label poke stays

func _on_tuning_changed(instance_id: int) -> void:
    if _writing:                        # our own edit — UI already updated in place
        return
    if not is_visible_in_tree():        # hidden panels do no work
        return
    if instance_id != int(_owned.get("instance_id", -1)):  # ignore other cars
        return
    refresh()
```

- `_writing` is the loop-breaker: the editing panel already poked its own widgets
  in place (`tuning_panel.gd:95`), so re-running `refresh()`/`rebuild()` for its
  own edit is redundant and, for `UpgradesMenu`, actively harmful (rebuild drops
  the slider drag grab). It replaces the abandoned emit-on-delta guard.
- Hidden panels short-circuit; the host already calls `setup()`/`refresh()` on
  open, so a panel that missed updates while hidden reconciles on show anyway.
  The signal's real job is the **visible, external** case: another panel or the
  live-car re-field shifts a value this panel currently shows.
- The `on_change: Callable` prop-drilling stays — it still tells the host to
  re-field the live car (physics/3D concern, not UI state). The signal replaces
  only the *UI-refresh* half that hosts currently trigger manually.
- Read the id from the panel's existing `_owned` dict (`_owned["instance_id"]`) —
  no new field needed.

## What NOT to change

- No new binding helpers, no `bind(widget, path)` utilities.
- No declarative render functions / reconciler.
- No change to `SliderRow.build` or the imperative builders in `hq.gd`.
- Panels DO get minimal edits — a `_writing` flag around their own `Save.set_*`
  calls, and the idempotent `connect` + handler. That's the whole footprint on
  the view layer; widget *construction* is untouched.
- Do not remove the manual in-place widget pokes yet — the signal makes them
  *reliable* (they now also fire when state changes from elsewhere); a later,
  separate pass could dedupe host-side `refresh()` calls that the signal now
  makes redundant, but that is out of scope here to keep the diff reviewable.

## Testing

Per project rules — test the LOGIC, never tuned values or catalogue entries.

- **Emit on change:** `set_tuning` on a synthetic owned car emits
  `tuning_changed` once with the right `instance_id`. Use `CarFixtures.install` /
  a hand-built car, not a real catalogue entry. Assert via GUT
  `watch_signals(Save)` + `assert_signal_emitted_with_parameters`. Because we
  dropped emit-on-delta, do NOT assert "same dict emits nothing" — it now emits
  every call, which is intended.
- **swap_engines:** emits `engine_changed` for **both** ids when the current
  engines differ; emits nothing (and does not consume a token) on the
  same-id / no-token / identical-engine paths. The identical-engine case is the
  new guard — assert token count is unchanged there.
- **set_selected_car:** emits `selected_car_changed` when the id actually
  changes; emits nothing when re-selecting the already-front car; the
  `selected_car()` self-heal path does NOT emit (non-emitting internal setter).
- **Subscriber echo-suppression (behavioural, if a panel test exists):** driving
  an edit through the *real* panel write path (not a direct `Save.set_tuning`)
  must not re-enter the panel's own refresh/rebuild — assert the editing panel
  does not rebuild in response to its own edit, and that an *external*
  `tuning_changed` for the panel's own id while visible DOES refresh, while one
  for a different id does not. Fable's caveat: a test that only calls
  `Save.set_tuning` with fresh dicts can pass vacuously — exercise the aliased
  `_owned` path the panels actually use.
- Signal wiring belongs in `save_manager`-level unit tests; extend
  `test_save_manager.gd` (or nearest existing Save test) rather than a scene test.

## Blast radius / tests to run

`set_*` mutators are read by the tuning/upgrade panels and the live car field.
Run the Save tests plus the menu/tuning/upgrade tests:
`./run_tests.sh --fast test_save_manager test_tuning_panel test_upgrades_menu
test_retune test_tuning_library test_menu_flow` (adjust names to what exists),
and any engine-swap test for the `swap_engines` dual emit.

## Docs to update (same piece of work)

- `features/menus.md` — document that panels self-update via `Save` signals;
  add a short "reactive state" note next to the manual-refresh description.
- Add/extend a `features/` note on the `Save` store's signal contract if one
  exists; otherwise a paragraph in `menus.md` is enough.
