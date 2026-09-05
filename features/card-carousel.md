# Card carousel

**Source:** `scripts/card_carousel.gd` (`CardCarousel`), `scripts/car_card_preview.gd`
(`CarCardPreview`, the CAR page's spinning 3D thumbnail).

**Tests:** `tests/headless/test_card_carousel.gd`; the five converted pages' keyboard
reachability is still pinned by `tests/headless/test_hub_shell.gd`
(`test_every_page_is_keyboard_navigable`).

The shared horizontal, side-scrolling card widget that replaced the vertical
row-of-buttons list on the hub's **MAIN**, **REGION**, **CAR**, **SHOP** and **PERKS**
pages ([hub-shell.md](hub-shell.md)). **CHALLENGE, BOOST_SHOP, STATS and SETTINGS were
NOT converted** — those weren't in the set this asked for (STATS in particular has
nothing choosable to put on a card; CHALLENGE/BOOST_SHOP stayed plain rows).

## Shape

Cards sit side by side, playing-card proportioned (`Config.data.card_carousel_aspect`,
taller than wide — a genuine tunable, not a hardcoded ratio), with the **centred** card
fully opaque and every other card dimmed to
`Config.data.card_carousel_unselected_alpha`. Each card is a `PanelContainer` split into:

- **`card.visual`** (top half) — an empty `Control` the caller populates: a
  `CarCardPreview` (car choice), or a plain `ColorRect` + letter `Label` placeholder
  (`hub_shell.gd::_card_icon` — region/perk/shop icons; no new art was commissioned for
  this, per the task's own "a simple colored/text placeholder is fine").
- **`card.info`** (bottom half) — a `VBoxContainer` the caller fills with whatever the
  screen wants to say: name, price, locked/owned state.

`CardCarousel.add_card(disabled: bool) -> Card` returns the `{root, visual, info,
disabled}` handle. A `disabled` card is **shown, dimmed, but never confirmable** — the
same "locked rows stay visible, just unfocusable" convention `hub_shell.gd` already used
for locked regions/perks, now expressed as a card rather than a `disabled` `Button` with
`menu_nav_skip` (a plain `Control` card has no such meta to set; the disabled flag lives
on the `Card` struct instead and `_confirm_selected()` reads it directly).

Signals: `selection_changed(index)`, `confirmed(index)`.

## Input

- **Keyboard/gamepad — the `MenuNav` seam.** `CardCarousel` is ONE focusable unit
  (`focus_mode = FOCUS_ALL`, set in `_init` — `MenuNav._make_focusable` only walks
  `BaseButton`/`Slider`/`LineEdit`, so the carousel keeps the mode it set itself rather
  than needing a fourth case there). Left/right move the selection by one card; up/down
  fall through to normal focus-neighbour movement so the cursor can still leave the
  carousel for a Back button below it. This works through **`menu_nav_handles_side(side)
  -> bool`**, a seam `menu_nav.gd::_unhandled_input` checks (via
  `has_method("menu_nav_handles_side")`) BEFORE its own `Range`/slider special-case —
  the exact same "this widget owns its own left/right" shape a slider already used, now
  named generically so the NEXT such widget doesn't need framework changes either
  (see menu_nav.gd's own comment at that call site). `menu_left`/`menu_right` (WASD) route
  through that seam; native `ui_left`/`ui_right` (arrows/D-pad/left-stick) are intercepted
  in `CardCarousel._gui_input` instead, because Godot's own focus-neighbour search would
  otherwise consume them in the GUI phase before `_unhandled_input` ever saw them.
  `ui_accept` is caught the same way in `_gui_input`; `menu_select` (no native GUI-phase
  consumer) is caught in the carousel's own `_unhandled_input`.
- **Mouse/touch.** Tapping a non-centred card **selects** it (moves toward centre);
  tapping the **already-centred** card **confirms**. Dragging (`InputEventMouseMotion`
  while a button is held, or `InputEventScreenDrag`) pans the strip live; releasing calls
  `end_drag_and_snap()`, which rounds the drag offset to the nearest card index and
  animates back to it — the strip never sits parked between two cards.

## Config

Every carousel tunable lives on `GameConfig` (`scripts/game_config.gd` → `Card Carousel`
group), not hardcoded in the script: `card_carousel_aspect`, `card_carousel_card_width`,
`card_carousel_unselected_alpha`, `card_carousel_snap_duration_s`,
`card_carousel_drag_step_fraction` (reserved for a future drag-vs-tap threshold refinement
— the shipped `end_drag_and_snap` already snaps to nearest regardless), and
`card_carousel_car_spin_deg_per_s` (the CAR page's turntable speed).

## The CAR page's spinning 3D preview

`CarCardPreview` (a `SubViewportContainer`) gives each car card ONE lightweight
`SubViewport` — 160×160, its own `World3D`, one `DirectionalLight3D`, one `Camera3D` — and
turntable-rotates a **frozen `CarProp`** (`car_prop.gd`, the same "display/frozen car"
recipe the old parked-lineup and podium showroom used) around a `Node3D` pivot each
`_process` frame. This is the cheap-by-construction shape the task asked for: one
`SubViewport` per card, not a full scene reinstantiation per frame — only the pivot's
Y-rotation changes after setup. `CarProp.spawn` is called with `stop_physics: true` and
`disable_process: true`, so the underlying `car.gd` instance does no physics or process
work at all; the only per-frame cost is the pivot's `rotate_y` and the SubViewport's own
render.

`CarCardPreview.new(car_ref)` takes either an **owned-car Dictionary** (a car the player
already has — shows its actual paint/wheels via `CarProp`'s `owned` opt) or a
**`CarLibrary` index** (an unowned catalogue car in the Buy list, via the `index` opt).

## Known open decisions (unilateral — flag for design review)

- **Card width / aspect / dim alpha / snap duration** are all authored defaults in
  `game_config.tres`, not something a designer asked for by number — they were picked to
  look reasonable, not measured against the shipped look. Retune freely; nothing else
  depends on the exact values.
- **The drag-to-select threshold** (`card_carousel_drag_step_fraction`, default 0.35) is a
  fraction of ONE card's width the drag must cross, measured from the card that was
  selected when the drag started — not a straight "nearest card by raw distance" snap,
  which would let a small accidental drag re-pick. A drag can still cross several cards
  at once if it goes far enough (`end_drag_and_snap` uses `ceili`/`floori`, not a
  one-card cap), which reads as sensible for a fast flick across a wide carousel.
- **Card icon placeholders for region/perk/shop are a solid-colour box + first letter**,
  not real art — the task said this was fine, but it is a visibly rough placeholder a
  future pass should replace with real icons per catalogue entry.
