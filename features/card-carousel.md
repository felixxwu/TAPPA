# Card carousel — every menu is a card list

**Source:** `scripts/card_carousel.gd` (`CardCarousel`, the widget), `scripts/car_card_preview.gd` /
`scripts/car_prop.gd` / `scripts/car_preview_cache.gd` (the car cards' 3D preview), `scripts/card_ui.gd`
(`CardUI` — the card-building API every menu uses: `card_page`, `card_list`, `text_card`,
`header_slot`, and the `titles` / `index_of` / `pick` readouts). Card icons are the white-outline
SVGs in `icons/cards/`.

**Tests:** `tests/headless/test_card_carousel.gd` (the widget, and `CardUI.card_list`'s entry →
card → action wiring); each menu's own nav test covers its page (`test_title_screen`,
`test_free_roam_rest_stops`, `test_loot`, `test_pause_menu`, `test_free_roam_shell`,
`test_photo_mode`, `test_world_session`).

The shared horizontal, side-scrolling card widget. It was the roguelike hub's menu shape, was
deleted with the hub in the free-roam demolition, and came back (October 2026) because the
plain row pages that replaced it were a narrow column in the middle of the screen. **Every
menu that is a list of choices is a card list:**

| Menu | Cards |
|---|---|
| Title MAIN (`title_screen.gd`) | Continue (only with a world), New world, Settings |
| Title STARTER | one per starter car (a spinning 3D preview, name, "hp · drive layout") |
| Pause menu (`pause_menu.gd`) | Resume, Reset, Photo Mode (only where the host offers it), the host's extra rows (free roam: Map, Stats), Settings, Quit |
| Rest stop MAIN (`rest_stop_page.gd`) | Continue, Parts, Garage, Map, Tune car; the stop's name, "Car repaired" and the money held sit above the cards |
| Rest stop PARTS | one per fitted part (pick → take off), then one per other part owned (pick → fit, or swap with the part in that slot; "Can't fit" cards are disabled), then one per part on sale (pick → buy and fit) |
| Rest stop GARAGE | one per owned car (a spinning 3D preview; the cursor starts on the car being driven), then one per car on sale (pick → buy and drive it) |
| Stats (`world_pages.gd`) | one per lifetime stat, and the biome rings reached (read-only) |

**Not card lists**, because they are not lists of choices: the **Settings** page (the shared
`SettingsMenu` — sliders, toggles and sub-pages), the rest stop's **Tune car** page (the shared
`TuningPanel`'s sliders), the **Map** (a picture; at a rest stop its Prev / Next / Travel buttons
pick a destination), and **confirm popups** (`ConfirmPopup`). Those are plain `MenuPage`s, widened
(`"width"`) so they are not a narrow column either.

**Build a new card menu** with `CardUI.card_page(host, {"title": …})` and
`CardUI.card_list(page, entries, header_lines, selected)`, where each entry is a dict —
`title`, `desc` (one line), `subtitle`, `extra` (+ `extra_variant`), `icon`, `disabled`, `action`. A card with no
`action` is read-only (the cursor can still land on it). Add a `< Back` with
`page.add_action(UITheme.row_button(...))` on a sub-page, and `MenuNav.attach(page, {first =
carousel, on_back = …})`. Item and car text should be SHORT — a card is a fixed size, and a title
that wraps to three lines pushes the subtitle off the card: loot uses `LootRules.card_text(item)`
(name, then what it does) and `LootRules.icon(item)`; cars use `CardUI.car_subtitle(entry)`.
Tests drive a card list through `CardUI.pick(carousel, title)` (select + confirm, no flash) or
`select(i)` + `_confirm_selected()` + `skip_confirm_flash()`.

**Car cards spin the car in 3D.** An entry with `"car"` (an owned-car dict, or a `CarLibrary` index)
shows a `CarCardPreview` (`scripts/car_card_preview.gd`: a frozen `CarProp` —
`scripts/car_prop.gd` — on a turntable in a small SubViewport) instead of an icon. Previews come from
the `CarPreviewCache` autoload (`scripts/car_preview_cache.gd`), one per car for the session; a page
calls `CardUI.park_previews(page)` before freeing itself so the next visit reuses them. Used by the
title's starter choice and the rest stop's Garage. Tests: `test_car_card_preview.gd`,
`test_car_preview_cache.gd`.

Cache hygiene: `get_or_build` always hands back an UNPARENTED preview — it pulls the node out of
whatever still holds it (the graveyard, or a page that was `queue_free()`d without
`park_previews`, which would otherwise make the caller's `add_child` fail). `drop_owned()` frees
every `owned:*` entry and runs on `WorldSession.world_changed` (any replaced world — New World, a
cloud download, a wipe, the benchmark ending — brings other owned cars, whose instance ids can
repeat the old ones); catalogue previews are kept.

## Shape

Cards sit side by side, playing-card proportioned (`Config.data.card_carousel_aspect`,
taller than wide — a genuine tunable, not a hardcoded ratio), with the **centred** card
fully opaque and every other card dimmed to
`Config.data.card_carousel_unselected_alpha`. Each card is a `PanelContainer` split into:

- **`card.visual`** (top half) — an empty `Control` the caller populates: a
  `CarCardPreview` (car choice), or a white-outline SVG icon from `icons/cards/`
  (`hub_shell.gd::_card_icon`, named by boost/skill id or a fixed name like
  "region_locked" — see `features/ui-design-system.md` → *Card icons* for the set's
  style rules).
- **`card.info`** (bottom half) — a `VBoxContainer` the caller fills with whatever the
  screen wants to say: name, price, locked/owned state.

`CardCarousel.add_card(disabled: bool) -> Card` returns the `{root, visual, info,
disabled}` handle. A `disabled` card is **shown, dimmed, but never confirmable** — the
same "locked rows stay visible, just unfocusable" convention `hub_shell.gd` already used
for locked regions/skills, now expressed as a card rather than a `disabled` `Button` with
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
  animates back to it — the strip never sits parked between two cards. The snap visibly
  travels through the intermediate positions: the tween drives offset AND layout via
  `tween_method`, re-running `_layout` every frame (the earlier `tween_property` form
  re-layouted only on `step_finished`, which fires once when a step completes rather than
  per frame, so the strip sat frozen for the whole snap and teleported at the end). A press
  that starts a new drag mid-snap kills the running tween, so the finger takes the strip
  over from exactly where the snap had reached. Drag release, tap-to-select and
  keyboard/gamepad movement all share the same animated snap through `select()`.

## Confirming is a beat, not an instant cut

`_confirm_selected()` (the already-centred card being tapped, or `ui_accept`/`menu_select`
pressed) does not emit `confirmed` on the spot. Instead the card flashes — alpha toggled
between full and `card_carousel_unselected_alpha`,
`Config.data.card_carousel_confirm_flash_count` times over
`Config.data.card_carousel_confirm_flash_duration_s` — and only once that plays out does
`confirmed(index)` fire and the caller act on the pick. The flash is what makes a confirm
read as "your choice registered" rather than a jump-cut straight into the next page.

While a card is mid-flash (`_confirm_index != -1`) every other entry point is locked out:
`select()`, a second `_confirm_selected()`, a tap on any card, and background drag/nav all
no-op or are ignored, so mashing the confirm input can't double-fire or restart the
animation. `_layout()` also leaves that one card's (and its shadow's) alpha alone for the
duration — it's owned by the flash tween, not the usual selected/unselected dimming.

`skip_confirm_flash()` is the test/host seam: jumps straight to `confirmed` firing, for a
test that cares about the confirm wiring rather than the flash animation itself (see
`test_card_carousel.gd`'s confirm-flash tests, and `test_hub_shell.gd`'s
`_touch_tap_selected_card`, which uses it to keep its menu-walk tests from needing to wait
out the real flash duration).

## One tap is delivered TWICE, and must still count as one tap

Godot's `input_devices/pointing/emulate_mouse_from_touch` is ON by default and this project
doesn't turn it off, so a single finger tap arrives as an `InputEventScreenTouch`
press/release pair AND a synthesised `InputEventMouseButton` press/release pair (touch
press, mouse press, touch release, mouse release — each touch event is immediately followed
by its emulated twin, so both presses precede both releases). `_on_card_gui_input` handles
both event types, so both releases used to call `_tap_card` on the same card: the first
`select()`ed it, which made the second one's `index == _selected` test true, so it
**confirmed** it. Net effect: tapping ANY non-centred card fired its action instead of just
scrolling it to the centre — the documented tap-to-select/tap-to-confirm rule above was
silently dead on a touch device.

Reported against the hub's MAIN page ("tapping Shop while New run is centred jumps straight
into the shop"), but it was never MAIN-specific: MAIN is simply the page whose cards are all
enabled, so it was where the phantom confirm had something to do. SHOP/SKILLS looked correct
only because most of their cards are disabled (locked, at MAX, or unaffordable) and
`_confirm_selected` drops a disabled index on the floor.

The fix is a per-GESTURE latch, `_gesture_tapped`: set when a release acts on a tap, cleared
by the next press in `_begin_drag`. Deduping by gesture rather than by event type is
deliberate — neither type can be dropped (the mouse pair is all a desktop player sends, the
touch pair carries the drag frame the section below depends on), and per-gesture state stays
correct however many pointer devices a platform decides to emulate. The latch lives in the
EVENT handler, not in `_tap_card`, so `_tap_card` stays the plain "a tap landed on card N"
seam the tests drive directly. Covered by
`test_a_touch_tap_delivered_twice_by_mouse_emulation_taps_only_once` and
`test_two_separate_taps_still_select_then_confirm`. Note that the unit tests calling
`_tap_card` directly can never catch this class of bug — it lives entirely in the event
path above that seam.

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
`card_carousel_car_spin_deg_per_s` (the CAR page's turntable speed),
`card_carousel_visible_width_factor` (below), `card_carousel_entrance_duration_s` /
`card_carousel_entrance_stagger_s` (the entrance fade below), and
`card_carousel_confirm_flash_duration_s` / `card_carousel_confirm_flash_count` (the confirm
flash above).

## Cards fade in, one by one, every time the list is (re)built

`add_card` starts each card at `modulate.a == 0` and defers (`call_deferred`) the start of
a per-card `Card.entrance` progress tween (0 -> 1, over `card_carousel_entrance_duration_s`)
until the current call stack finishes — so a caller that restores a remembered selection
with `select()` right after its `add_card` loop (hub_shell.gd's `_build_car`/`_build_cars`
— see below) gets to do so before any fade actually starts. `_animate_entrance` then delays
each card's tween by `abs(index - _selected) * card_carousel_entrance_stagger_s`: the
SELECTED card starts fading immediately and the rest fan outward from it in both
directions, reading as the strip building itself out from wherever the player's eye
already is rather than always left to right. (When `_selected` is 0 — the common case,
a fresh MAIN/REGION/SHOP/SKILLS page — this degenerates to the old left-to-right order.)
This is why the fix for "reopening the CARS page miles down a long list took seconds to
show anything" lives here rather than in hub_shell.gd: hub_shell only had to remember
which car to reselect, and the stagger fanning out from `_selected` made that selection
visible immediately regardless of its position in the list. `_layout()` multiplies
`entrance` into the alpha it already computes for selection dimming (`card.entrance *
(1.0 if selected else unselected_alpha)`), so a card fades in to whatever its STEADY-STATE
opacity should be — full if selected, dimmed otherwise — never all the way to 1.0
regardless of selection. The shadow strips reuse that same final `alpha`, so they fade in
in lockstep with their card with no separate bookkeeping.

`Card.entrance_started` guards against the deferred `_animate_entrance` call landing AFTER
`finish_entrance_animation()` (below) already jumped a card to steady state — without it, a
test/host that finishes the animation before the deferred call fires would see its card
yanked back to invisible and re-faded a frame later.

**This restarts on its own, with no "already shown" flag to track.** Every card
page builds a BRAND NEW `CardCarousel` (`build_carousel` creates one via `CardCarousel.new()`,
and every card is added fresh via `add_card`) — so pressing Back from a sub-menu to a card
page rebuilds the page, which means a genuinely new carousel with every `Card.entrance`
starting at 0. The animation
living entirely on per-card state (not on the page or on some "has this carousel ever
been shown" latch) is what makes restarting the default rather than something a caller
has to opt into.

`CardCarousel.finish_entrance_animation()` is a test/host seam only — it kills every
card's entrance tween and jumps `entrance` to 1.0 for every card, so a test that only
cares about steady-state alpha (selection/shadow dimming) doesn't have to await the real
fade duration. Nothing in production calls it.

## A card needs a visible edge, not just a gap — but not necessarily a border

Every panel in `UITheme` is solid black by design (`panel_box`'s "rule 4"), and a card
used to sit directly on top of an ALSO-solid-black `MenuPage` body box. A pure-black card
on a pure-black body was invisible as a shape: the true gap between two cards and the
inside of a card read as the exact same colour, so widening `card_carousel_gap` alone
couldn't make the strip look like separate cards — it only made the (equally invisible)
space between two equally-invisible rectangles bigger. `modulate.a` dimming didn't help
either: 50% transparent black over black is still black. The whole strip read as one
fused black slab with a few floating coloured squares — the "cards joined into one" bug
this section originally existed to fix, with an accent border (1px unselected, 3px on the
centred card — `UITheme.reward_card_box`'s existing precedent for a black card that must
pop against another black panel).

That border is GONE now (removed on request, from both states) because the fix that
actually holds arrived one layer up: the five carousel pages sit on a TRANSPARENT
`MenuPage` body box (see "the gaps show the live 3D showcase" below), so a card's own
opaque black fill already reads as a distinct shape against the busier background behind
it — an explicit border on top of that was visual clutter, not a second safety net.
`CardCarousel._card_stylebox()` (no longer selection-aware — it returns the SAME
`panel_box` fill regardless) is applied once in `add_card`; `_layout()` no longer
reapplies a stylebox every pass, since there is nothing left that varies by selection.
Selection is carried by `modulate.a` alone now. If a future change ever puts a carousel
back on an opaque body box, the invisible-cards failure mode above will return — that's
the condition to watch for, not a reason to restore the border pre-emptively.

## Cards cast a sharp drop shadow, not a blurred one

Each card is drawn with a **hard, zero-blur black shadow offset down-right** — the CSS
equivalent of `box-shadow: 5px 5px 0 rgba(0,0,0,0.2)`. Without it a black card on a busy
3D background read flat; the offset quad gives it a sense of sitting *above* the page,
in keeping with the PS1-era, no-soft-edges look (blurred shadows would fight it).

Mechanically the shadow is drawn as **only the L-shaped SLIVER that actually pokes out
from under the opaque card** — split into two non-overlapping `Panel` strips,
`card.shadow_right` (full card height, to the right) and `card.shadow_bottom` (card
width minus the offset, below) — rather than one full offset square. Both are added to
`_strip` immediately BEFORE the card's `root` (siblings paint in tree order, so they
land underneath) and are `MOUSE_FILTER_IGNORE`, so neither ever swallows a tap meant for
a card. Neither can be a child of the card: `card.root` paints an opaque black fill and
sets `clip_contents`, so anything inside it is both covered and clipped. `_layout`
recomputes both strips' position AND size every pass from the card's actual rect
(`card.root.size`, not the nominal `_card_height()` — a card whose content grew is still
fully shadowed):

```
shadow_right.position  = card.position + Vector2(card.size.x, off)
shadow_right.size      = Vector2(off, card.size.y)
shadow_bottom.position = card.position + Vector2(off, card.size.y)
shadow_bottom.size     = Vector2(card.size.x - off, off)
```

where `off == UITheme.card_shadow_offset()`. These two rects are exactly the full offset
square (`card.position + Vector2(off, off)`, size `card.size`) MINUS its intersection
with the card's own rect — i.e. the part a full square would have drawn but the opaque
card would have hidden anyway.

**Not `StyleBoxFlat`'s own `shadow_*` properties.** That shadow rect is the box *expanded
by `shadow_size` on all sides* and then offset: `shadow_size = 0` draws nothing at all,
and any size > 0 leaks shadow out of the top-left edge too — so a purely diagonal,
zero-blur offset is unreachable through it. The fill and offset live in
`UITheme.card_shadow_box()` / `UITheme.card_shadow_offset()`
(`CARD_SHADOW_AUTHORED`, scaled through `UITheme.px`) — see
[ui-design-system.md](ui-design-system.md) → *Card drop shadow* for the theme-wide sibling
mechanism (`UIHardShadowBox`) every ordinary Button/Panel in the game wears instead.

## Why two non-overlapping strips, not one square dimmed as a group

Two things were tried and discarded before landing on the sliver-strips shape above:

1. **One full offset square, dimmed independently of the card.** This is what a naive
   reading of "draw a shadow behind the card" produces, and it looks right SELECTED
   (fully opaque) — the card's opaque black fill hides all of the square except the true
   sliver at the bottom-right. But dimming an UNSELECTED (translucent) card this way reads
   wrong: root's fill covers ~95% of the square, so once root itself turns translucent,
   that whole covered region shows TWO stacked layers of partial black — root's own
   dimmed fill AND the square shadow behind it bleeding through — reading visibly darker
   than the thin sliver where only the shadow shows alone.
2. **The same full square, wrapped with `card.root` inside a shared `CanvasGroup`,
   dimming the group instead of root/shadow individually.** A `CanvasGroup` composites
   its children into one buffer BEFORE that buffer is blended against the background, so
   with root and shadow left at full internal alpha, the opaque card still fully hides
   the shadow within the overlap inside that buffer, and only the group's own
   `modulate.a` dims the pre-composited result once. This is the textbook fix for the
   artifact in (1) — but `CanvasGroup` is **not supported under the GL Compatibility
   renderer this project ships with** (`renderer/rendering_method="gl_compatibility"` in
   `project.godot`), and rendered as one shadow spanning the ENTIRE carousel container
   rather than sitting behind its own card.

Splitting the shadow into the two strips that genuinely never overlap the card sidesteps
the whole problem: there is no hidden region to reveal, so `root`, `shadow_right` and
`shadow_bottom` can each be dimmed independently by the exact same alpha with no seam —
no compositing node of any kind required, so nothing renderer-specific to trip over.

## Edge to edge, and never a clipped card

`MenuPage`'s body box deliberately hugs its content and sits with a wide gap to the
screen edge for every OTHER page (menu_page.gd rule 1) — right for a settings page or a
row list, wrong for a carousel that is supposed to read as a strip of cards running the
width of the screen. `CardUI.build_carousel` gives a card page its own small `CAROUSEL_PAGE_MARGIN` instead of that wide margin, and sizes the carousel to the
current logical frame width via `UITheme.layout_frame_size(page, ...).x`, then feeds that
through `page.set_body_width(...)` — otherwise the box would still hug back down to
whatever narrow width the carousel used to default to.

`CardCarousel.fit_to_available_width(avail_width)` claims that WHOLE pixel budget —
`custom_minimum_size.x = max(avail_width, card_width)` — rather than rounding down to a
whole number of cards. `_layout()` always centres the SELECTED card exactly on the
carousel's own centre-x regardless of how many cards fit, so nothing about the centring
depends on the count being whole or odd; a neighbour that only PARTIALLY fits inside the
claimed width is left peeking in at the strip's own `clip_contents` edge instead of being
rounded away into blank margin on both sides. That partial card is deliberate — it's the
visible cue that there's more to scroll — not the "clipping" bug it used to be read as (an
earlier version of this method rounded down to a whole, odd card count specifically to
avoid it; that traded a legible "there's more" hint for wasted edge-to-edge space, and was
reversed on request). `clip_contents` on the carousel is what makes a partial card read as
"sliced by the screen edge" rather than as a layout glitch — it always cuts cleanly at the
strip's own bounds, never mid-render.

### The fit has to be re-run on every window resize, not just once at open

`CardUI.build_carousel` (`card_ui.gd`) — the shared home for the sizing above, now that
`hub_shell.gd`'s and `run_pick_panel.gd`'s private copies both point at it — used to call
`fit_to_available_width` exactly once, at the moment the carousel page opened. A player who
resized or maximized the window (or rotated a device) while a carousel page stayed open kept
whichever width the window happened to be at open time forever: reported as "the card list
doesn't extend to the edges of the screen, it clips at a certain width". `build_carousel` now
also connects the page's `Window.size_changed` to re-run the same fit
(`CardUI._refit_carousel`), so the carousel keeps tracking the window instead of freezing at
its first size. The hook is torn down on the carousel's own `tree_exiting` (a `Window`
outlives any one page, so leaving the connection wired past the carousel's lifetime would
both leak one per page opened AND keep firing into a freed `page`/`carousel` pair —
`_refit_carousel` also guards with `is_instance_valid` on both for the frame between
`tree_exiting` and the disconnect actually landing).

The hookup uses a **lambda**, not `Callable(CardUI, "_refit_carousel").bind(page, carousel)`:
Godot's `Signal.connect`/`is_connected` treat two bound `Callable`s to the same static method
as equal regardless of their bound arguments, so binding gave "Signal already connected" the
moment a SECOND carousel page was ever opened (every `hub_shell.gd` page change hit it). Each
lambda closure is its own distinct object, which sidesteps the comparison entirely.

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
neighbour's space even if something still overflows), and `_prepare_incoming_child` —
hooked onto `card.visual.child_entered_tree` / `card.info.child_entered_tree` — is the
actual fix, forcing `autowrap_mode = TextServer.AUTOWRAP_WORD_SMART` and clearing
`custom_minimum_size.x` on every `Label` a caller adds, so text wraps to fit the card
instead of forcing it wider. Because this is hooked at the carousel level rather than
patched into one page builder, it covers every current AND future caller
automatically — a new page that forgets to autowrap its own labels is covered anyway.

## Wrapping fixed the width overflow, and shifted it onto height

Forcing a long label to autowrap trades width for height: a subtitle that used to be one
long unwrapped line became two or three SHORTER, TALLER ones. `card.info` (the bottom-half
slot) was a plain `VBoxContainer` added directly to `col` with no size cap of its own —
same shape as the pre-fix `card.root`, so the same failure mode applied one level down:
its combined minimum height (now inflated by wrapped text) could push `col`'s, and so
`card.root`'s, combined minimum height past `_card_height()`, growing the whole card
downward — reported as "the visual part on the top pushes everything else down past the
bottom of the card" (from the player's side, the card just looks like its content spilled
out the bottom, whichever slot's content happened to be the trigger).

The fix mirrors `card.visual`'s existing shape rather than inventing a new one:
`card.info` is now wrapped in `info_slot`, a plain (non-`Container`) `Control` with a
FIXED `custom_minimum_size.y` and `clip_contents = true` — a plain `Control`'s reported
minimum size to its parent is always exactly its own `custom_minimum_size`, never
inflated by what's inside it (the same property that already made `card.visual` immune to
this), so `col`'s combined height can never grow past what `visual_h + info_h` was set to,
however much text a caller stuffs into a card. `visual_h`/`info_h` are computed once, in
`add_card`, from the actual budget left inside the card after `card.root`'s own stylebox
padding (`UITheme.PANEL_PAD`, both edges) and `col`'s separation (`UITheme.GAP_TIGHT`) —
not "half of `_card_height()` each" in isolation, which is what would still overflow once
that padding/gap is accounted for. Content that still doesn't fit within its slot's fixed
height is clipped (visually cut off) rather than growing the card — a safety net, same
role `card.root.clip_contents` already plays for width.

## A card's own icon/preview must not swallow the tap meant for the whole card

Every `Control` defaults to `MOUSE_FILTER_STOP`. A caller's decorative content in
`card.visual` (`_card_icon`'s `ColorRect`, `CarCardPreview`) never overrode that, so a tap
landing on the card's own top-half art was consumed there and never reached `card.root`'s
`gui_input` — which is where `_on_card_gui_input`, and so tap-to-select/tap-to-confirm,
actually lives. Reported as "touch targets don't work for the visual upper half": the
bottom-half `Label`s worked (Godot's `Label` already defaults to `MOUSE_FILTER_IGNORE`),
the top half didn't. `_prepare_incoming_child` now forces `MOUSE_FILTER_IGNORE` on every
`Control` added to `card.visual`/`card.info`, not just `_card_icon`/`CarCardPreview`
specifically — nothing added to either slot is meant to receive input in its own right,
the CARD is the only tap target, so this is a blanket rule for the slot rather than a
per-content-type fix. Covered by
`test_a_card_still_confirms_when_tapped_on_its_visual_slot`.

## The gaps show whatever is behind the page, not black

`CardUI.card_page` opens its `MenuPage` with `"alpha": 0.0` (and zero margin / padding), so the
body box itself paints nothing: the space between and around the cards shows the frozen game
behind the pause menu and the rest-stop page (dimmed by the page's `"dim"` option), or the title
screen's background. Cards stay opaque — their stylebox (`_card_stylebox`) is independent of the
page they sit on.

## The car cards' spinning 3D preview

`CarCardPreview` (a `SubViewportContainer`) gives each car card ONE lightweight
`SubViewport` — 160×160, its own `World3D`, one `DirectionalLight3D`, one `Camera3D` — and
turntable-rotates a **frozen `CarProp`** (`car_prop.gd`, the same "display/frozen car"
recipe) around a `Node3D` pivot each
`_process` frame. This is the cheap-by-construction shape the task asked for: one
`SubViewport` per card, not a full scene reinstantiation per frame — only the pivot's
Y-rotation changes after setup. `CarProp.spawn` is called with `stop_physics: true` and
`disable_process: true`, so the underlying `car.gd` instance does no physics or process
work at all; the only per-frame cost is the pivot's `rotate_y` and the SubViewport's own
render.

`CarCardPreview.new(car_ref)` takes either an **owned-car Dictionary** (a car the player
already has — shows its actual paint/wheels via `CarProp`'s `owned` opt) or a
**`CarLibrary` index** (an unowned catalogue car in the Buy list, via the `index` opt).

## The car is centred on its OWN geometry, not a guessed camera offset

Cars in `car.tscn` are authored around whatever origin convention each source model
happened to use — not necessarily its own visual centre. Aiming the camera at a single
fixed point (a first-draft `Vector3(0, 0.6, 0)` guess) landed fine for some cars and
"not quite centred" for others, since that guess only matched one car's actual geometry.
`CarCardPreview._center_on_pivot` fixes this per-car instead of per-guess: right after
`CarProp.spawn` returns, it measures the union of every VISIBLE `MeshInstance3D`'s AABB
under the spawned car (`_visible_mesh_aabb` — pruning already dropped every OTHER
embedded car body, so this only ever measures the one model actually showing) and shifts
the CAR (not the camera, not the pivot) so that AABB's centre lands exactly on `_pivot`'s
own local origin. The camera then simply targets `Vector3.ZERO` — correct for every car
uniformly — and since `_pivot` is what `_process` spins, the turntable rotation orbits
around the car's true visual middle instead of wobbling around wherever its unshifted
scene origin happened to sit. Runs on every spawn, including `show_car` swaps, so a
different car mid-session gets recentred on ITS OWN geometry too, not the previous car's.

## A narrow FOV needs the camera moved back to keep the car's apparent size

`card_carousel_car_preview_fov_deg` (default 12°, `GameConfig`) is deliberately narrow —
a telephoto-ish lens flattens perspective distortion, which reads as more "product shot",
less "fisheye". A narrow FOV alone, camera left in place, makes the subject look SMALLER
(the lens is more zoomed-out per degree, not less) — so `CarCardPreview._init` derives the
camera's DISTANCE from the FOV rather than hardcoding both independently. Apparent size
for a fixed subject scales with `distance * tan(fov / 2)`; holding that product equal to
the bounding-sphere radius of the roster's largest car — half the diagonal of
`CarLibrary.max_car_bounds()`, the same source the car park sizes its reveal box from —
times `card_carousel_car_preview_frame_margin` (default 1.2, `GameConfig`) makes the
derivation SIZE the frame as well: that sphere is what contains a car at ANY turntable
heading, so framing it (with margin) is what keeps the longest/widest roster car inside
the square viewport instead of clipping out of the card. The original fixed reference
composition (`_REFERENCE_FOV_DEG = 40`, `_REFERENCE_EYE = Vector3(3.2, 1.8, 3.6)` — an
eye-tuned close-up) DID clip the longest cars, and any hand-retuned replacement would
silently stop fitting the day a longer car joins, which is why the frame now follows the
roster instead. Retune the fov or the margin freely — the distance follows them
automatically; don't reintroduce a second, independently-picked distance constant, or the
two will drift apart the next time either changes.

## A preview is CACHED per car, not rebuilt per screen slot

A `CarCardPreview` costs two separate things: the `SubViewport`/camera/light setup, and
`CarProp.spawn`'s `car.tscn` instantiation (every embedded car glb body, before
`car_prop.gd`'s pruning) — the SECOND one is genuinely per-car expensive, not just
per-viewport. Building one for every car up front blocks the main thread; rebuilding a window
of cards on every selection move freezes the carousel; a pool tied to screen slots re-spawns
a car every time it scrolls back into view. What holds ties the expensive half — the spawned
`CarProp` — to the CAR, and makes the cache outlive the page.

`CarPreviewCache` (`car_preview_cache.gd`) is an AUTOLOAD, so it survives the page being
rebuilt. `CardUI` card entries with a `car` ref call `CarPreviewCache.get_or_build(car_ref)`,
which returns either an ALREADY-BUILT instance (a cache hit) or a freshly spawned one (cached
from here on). A page being torn down calls `CardUI.park_previews(page)`, which hands each
preview to `CarPreviewCache.park(preview)` instead of freeing it — parked previews sit in the
cache's own hidden `graveyard` Control (a child of the autoload); `visible = false` on an
ancestor stops a `SubViewport` costing render time while parked.

`CarPreviewCache.warm_all()` (no production caller today) walks every owned + catalogue car and builds (then parks)
whichever aren't cached yet, yielding a frame every `_WARM_PER_FRAME` cars rather than
doing it in one synchronous burst; a second call WAITS for the in-flight pass. Idempotent and
cheap afterwards: a cached car is skipped instantly.

`CardCarousel.get_card(index)` reaches back into a card's `visual` slot after `add_card`
returned it. Don't revert to a page-scoped cache or to rebuilding a car's `CarProp` on every
re-entry into view. `CarCardPreview.show_car` still exists for a caller that wants "this same
viewport, a different car", but `CarPreviewCache` doesn't use it.

**Known caveat, not yet handled:** the cache is keyed by car ref, not re-validated against
the car's current cosmetic state — an owned car's cached preview could go stale if its
paint/wheels/engine change via another menu mid-session without anything invalidating that
cache entry.

## `CardUI` — the reusable card API

`scripts/card_ui.gd` is the one place a card is built. `text_card` / `fill_card` write an icon,
a centred title, an optional dim subtitle and an optional third line into a card;
`build_carousel` mounts a carousel edge to edge on a page and re-fits it on every window resize;
`card_page` and `card_list` (above) are the two calls a menu makes.

## The header above the cards is a fixed-height slot, so the cards don't jump per page

`MenuPage` hugs its content and vertically CENTRES the whole panel, so a page with a taller
header would sit its cards lower than one with none. `CardUI.header_slot(page)` reserves
`CardUI.CAROUSEL_HEADER_LINES` (3 — the rest stop's name, "Car repaired" and the money line)
lines above the carousel on EVERY card page, bottom-aligned, and `card_list` always calls it, so
the cards land at the same screen height on every page. A page built with no title gets
`CardUI.title_gap_spacer()` first, for the same reason. A header line longer than the frame wraps
(and then does push the cards down).

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
- **Card icons are real SVGs now** (`icons/cards/*.svg`) — white only, uniform 6px
  stroke, round caps/joins, one shape vocabulary across the set; see
  `features/ui-design-system.md` → *Card icons* before adding one.
