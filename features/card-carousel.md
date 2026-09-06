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

## Touch drag must convert through a common (global) coordinate frame

`InputEventScreenTouch`/`InputEventScreenDrag` positions are LOCAL to whichever control
actually receives them — and a drag gesture doesn't stay on one control. The press is
caught by `_on_card_gui_input`, bound to the PRESSED CARD's own `gui_input` signal, so its
`.position` is local to that card; the drag samples that follow are caught by
`_gui_input`, the CAROUSEL's own override, so THEIR `.position` is local to the carousel
instead. `InputEventScreenTouch`/`Drag` have no `global_position` field to fall back on
(unlike mouse events, which is why the mouse-drag path never had this bug), so comparing
the two raw `.position` values directly computed a bogus delta on the very first drag
sample — as large as the distance between the pressed card and the carousel's own local
origin. The reported symptom: touching the peeking card next to the first (selected) card
and starting to drag made the whole strip jump immediately, before any real finger
movement. Both `_on_card_gui_input`'s touch branch and `_gui_input`'s
`InputEventScreenDrag` branch now convert through `get_global_transform() * event.position`
before ever comparing an x-coordinate across the two handlers — see
`test_touch_drag_tracks_the_real_finger_delta_not_a_coordinate_mismatch`. Don't reintroduce
a bare `t.position.x`/`d.position.x` comparison here; that is exactly this regression.

## A drag must arm from the carousel's own background too, not just from a card

`_drag_active` used to be armed ONLY inside `_on_card_gui_input`, which is bound to each
CARD's own `gui_input` signal. That was invisible while the page behind the carousel was
opaque black (a press anywhere that mattered was, in practice, always on a card or right
at its edge), but once the gaps became a window onto the live 3D showcase (see below),
starting a drag from the genuinely empty space between or around cards is something a
player will actually do — and that press never reached `_on_card_gui_input` at all, so the
drag silently did nothing. `_gui_input` (the carousel's own override) DOES receive a press
that lands on empty space (nothing else claims it), so it now arms `_drag_active` itself
too, through the same shared `_begin_drag(global_x)` helper `_on_card_gui_input` uses — a
press that started ON a card still also reaches here afterwards (cards use
`MOUSE_FILTER_PASS`, so the event bubbles up once the card's own handler has already run),
and re-arming with the same true global x is a harmless no-op, not a second gesture. The
release side needed the same treatment: `_gui_input`'s new press branch also has to clear
`_drag_active` on release, or a background-only gesture would leave it stuck true and bare
mouse motion (no button held) would go on panning the strip. See
`test_dragging_from_the_background_between_cards_still_pans_the_strip`. While fixing this,
the `InputEventScreenDrag` branch also picked up the `_drag_active` guard the
`InputEventMouseMotion` branch already had — without it, any screen-drag event reaching
the carousel (even one that never had a matching press) moved the strip.

## Config

Every carousel tunable lives on `GameConfig` (`scripts/game_config.gd` → `Card Carousel`
group), not hardcoded in the script: `card_carousel_aspect`, `card_carousel_card_width`,
`card_carousel_gap`, `card_carousel_unselected_alpha`, `card_carousel_snap_duration_s`,
`card_carousel_drag_step_fraction` (reserved for a future drag-vs-tap threshold refinement
— the shipped `end_drag_and_snap` already snaps to nearest regardless),
`card_carousel_car_spin_deg_per_s` (the CAR page's turntable speed), and
`card_carousel_visible_width_factor` (below).

## A card needs a visible edge, not just a gap

Every panel in `UITheme` is solid black by design (`panel_box`'s "rule 4"), and a card
sits directly on top of the ALSO-solid-black `MenuPage` body box. A pure-black card on a
pure-black body is invisible as a shape: the true gap between two cards and the inside of
a card read as the exact same colour, so widening `card_carousel_gap` alone cannot make
the strip look like separate cards — it only makes the (equally invisible) space between
two equally-invisible rectangles bigger. `modulate.a` dimming doesn't help either: 50%
transparent black over black is still black, so the unselected/selected cue was carried
entirely by the tiny icon rectangle inside each card, and the whole strip read as one
fused black slab with a few floating coloured squares — exactly the "cards joined into
one" bug report this section exists to prevent a repeat of.
`CardCarousel._card_stylebox(selected)` fixes this the same way `UITheme.reward_card_box`
already does for a black card that must pop against another black panel: an outline,
1px `UITheme.INK_DIM` normally and 3px `UITheme.GREEN` (the theme's existing
"active/selected" colour) on the centred card. `_layout()` reapplies it every card on
every layout pass since it doubles as the selection indicator. Don't drop the border to
"clean up" the stylebox — without it the carousel silently regresses to invisible cards
regardless of how big the gap or how strong the dim/opaque contrast is.

## Edge to edge, and never a clipped card

`MenuPage`'s body box deliberately hugs its content and sits with a wide gap to the
screen edge for every OTHER page (menu_page.gd rule 1) — right for a settings page or a
row list, wrong for a carousel that is supposed to read as a strip of cards running the
width of the screen. `HubShell._is_carousel_view` gives the five carousel pages
(MAIN/REGION/CAR/SHOP/PERKS) their own small `_CAROUSEL_PAGE_MARGIN` (8.0, vs. every other
page's 24.0) instead of that wide margin, and `_build_carousel` sizes the carousel to the
current logical frame width via `WorldPanel.layout_frame_size(_page, ...).x` (the same
"how much room do I actually have" call `RallyDetail.body_width` uses), then feeds that
through `_page.set_body_width(...)` — otherwise the box would still hug back down to
whatever narrow width the carousel used to default to.

`CardCarousel.fit_to_available_width(avail_width)` is what turns that raw pixel budget
into an actual card count: it rounds DOWN to a whole, ODD number of cards (`unit :=
card_width + gap`; `count := floor((avail_width + gap) / unit)`, forced odd) rather than
whatever fraction of a card happens to fit. Odd matters, not just whole: `_layout()`
always centres the SELECTED card exactly on the carousel's own centre-x, so an odd visible
count is the only way to get an equal number of whole cards peeking on both sides — an
even count would show one more full card on one side than the other, i.e. a card sliced in
half at the far edge, which is the exact "clipping" bug this method exists to rule out.
`clip_contents` on the carousel stays on regardless (a catalogue longer than the visible
count still needs to hide the far-off cards) — it's just that every card `clip_contents`
ever cuts is either fully inside the strip or fully outside it, never straddling the edge.

## A card must never grow past card_width, or it overlaps its neighbour

`card.root` (the card's `PanelContainer`) is an absolute-positioned child of `_strip`, a
plain `Control` rather than a layout `Container` — nothing ever assigns it a rect, so
Godot lets its actual size grow to fit whatever its children's combined minimum size
demands, same as any unmanaged Control. A caller's label that doesn't wrap (a region's
"Locked — clear `<gate>`" subtitle was the case that surfaced this) reports its full
unwrapped text width as its minimum size, which can exceed `card_carousel_card_width` —
and since cards sit at FIXED `index * (card_width + gap)` offsets rather than flowing
around each other, a too-wide card visibly overlaps its neighbour instead of pushing it
aside.

Two things fix it, both inside `add_card` so no caller has to remember either: `card.root
.clip_contents = true` is the safety net (a card can never visually bleed into a
neighbour's space even if something still overflows), and `_wrap_incoming_label` — hooked
onto `card.visual.child_entered_tree` / `card.info.child_entered_tree` — is the actual
fix, forcing `autowrap_mode = TextServer.AUTOWRAP_WORD_SMART` and clearing
`custom_minimum_size.x` on every `Label` a caller adds, so text wraps to fit the card
instead of forcing it wider. Because this is hooked at the carousel level rather than
patched into `HubShell._text_card`, it covers every current AND future caller
automatically — a new page that forgets to autowrap its own labels is covered anyway.

## The gaps show the live 3D showcase behind the page, not black

`MenuPage`'s body box is opaque black by default (`panel_box(1.0)`), which is right for a
page that should read as a solid panel — but wrong for a carousel, where the space between
cards is supposed to be a window onto the live 3D menu showcase behind the shell
(`todo/menu-background-showcase.md`), not more black. `HubShell._show` passes `"alpha":
0.0` into `MenuPage.open_modal`'s opts for the five carousel views only (others keep the
default opaque box), making the WHOLE body box transparent. Cards themselves are
unaffected — `_card_stylebox`'s `panel_box(1.0)` is independent of the page they happen to
sit on — so only the truly empty space (the gaps between cards, and around them) opens up
onto the showcase; nothing about a card's own read as a solid surface changes.

`MenuPage`'s body box **hugs its content's minimum width** (`menu_page.gd`'s
`_scroll.horizontal_scroll_mode = SCROLL_MODE_DISABLED` propagates the child's real
minimum width up to the box). Cards are absolute-positioned children of `_strip`, a plain
`Control` rather than a `Container`, so they never contribute to anyone's reported minimum
size — the carousel itself has to declare one. Without it the body box shrinks to whatever
its narrowest sibling (a "Money: N" label, say) needs, and the CardCarousel's own
`clip_contents = true` then clips every card down to that sliver — which reads as "a list
scrolling inside one small card" rather than a row of cards, since you never see more than
a fragment of whichever card is centred. `CardCarousel._init` sets
`custom_minimum_size.x = card_carousel_card_width * card_carousel_visible_width_factor`
(default 2.6×) specifically so the box grows enough to show the selected card next to a
peek of its neighbours. Don't reintroduce a bare `Vector2(0, height)` minimum size here —
that is exactly the regression this section documents.

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

## Exactly ONE live preview exists, reused, not rebuilt per selection

A `CarCardPreview` is a real `SubViewport` + camera + light + a full `car.tscn`
instantiation (every embedded car glb body, before `car_prop.gd`'s pruning) — cheap once,
expensive if paid for repeatedly. `HubShell._build_car` first built one for EVERY car up
front (every owned car plus the whole unowned catalogue), which blocked the main thread
long enough on a real roster to read as the game freezing the moment a region was picked
(region select is what leads to this page). A first fix narrowed that to a WINDOW of
cards around the current selection — better, but every card in that window still got torn
down and rebuilt from scratch on every `selection_changed`, which is what surfaced next as
the carousel visibly freezing the moment a player actually tried to MOVE the selection
(unavoidable — that's the only way to pick a car).

The fix that actually holds: every car card gets the cheap letter-icon placeholder
(`_card_icon`) up front, and the page keeps exactly ONE `CarCardPreview` alive for its
entire lifetime. `HubShell._sync_car_preview` reparents that SAME instance onto whichever
card is currently selected and calls `CarCardPreview.show_car(new_ref)` to swap which car
it shows — reusing the already-built `SubViewport`/camera/light rather than paying for
that setup again on every move, and rebuilding only the (already-cached, after the first
use) `CarProp` underneath it. The card the preview is LEAVING gets its placeholder icon
back. `CardCarousel.get_card(index)` is the accessor this needs (reach back into a card's
`visual` slot after `add_card` returned it). `_sync_car_preview`'s `state` argument is a
mutable `Dictionary`, not local variables closed over by the connecting lambda — GDScript
lambdas capture locals BY VALUE, so a plain `var preview = null` reassigned inside the
lambda body would not be visible on the NEXT firing of that same lambda; a Dictionary's
contents mutate in place instead, which does persist. Don't revert to building a
`CarCardPreview` per card, windowed or not — that is exactly this regression.

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
