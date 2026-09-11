# Card carousel

**Source:** `scripts/card_carousel.gd` (`CardCarousel`), `scripts/card_ui.gd` (`CardUI` —
the extracted reusable card-building API, see *`CardUI` — the reusable card API* below),
`scripts/car_card_preview.gd` (`CarCardPreview`, the CAR page's spinning 3D thumbnail),
`scripts/car_preview_cache.gd` (`CarPreviewCache` autoload — the session-lifetime cache of
built previews, keyed by car).

**Tests:** `tests/headless/test_card_carousel.gd`, `tests/headless/test_car_card_preview.gd`
(the CAR page's 3D thumbnail specifically), `tests/headless/test_car_preview_cache.gd`
(the cache/warm-up autoload); the five converted pages' keyboard reachability is still
pinned by `tests/headless/test_hub_shell.gd` (`test_every_page_is_keyboard_navigable`).

The shared horizontal, side-scrolling card widget that replaced the vertical
row-of-buttons list on the hub's **MAIN**, **REGION**, **CAR**, **SHOP**, **SKILLS**
pages and the three **FREEPLAY** steps ([hub-shell.md](hub-shell.md)). **CHALLENGE, STATS and SETTINGS were
NOT converted** — those weren't in the set this asked for (STATS in particular has
nothing choosable to put on a card; CHALLENGE stayed plain rows).

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
width of the screen. `HubShell._is_carousel_view` gives the five carousel pages
(MAIN/REGION/CAR/SHOP/SKILLS) their own small `_CAROUSEL_PAGE_MARGIN` (8.0, vs. every other
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
neighbour's space even if something still overflows), and `_prepare_incoming_child` —
hooked onto `card.visual.child_entered_tree` / `card.info.child_entered_tree` — is the
actual fix, forcing `autowrap_mode = TextServer.AUTOWRAP_WORD_SMART` and clearing
`custom_minimum_size.x` on every `Label` a caller adds, so text wraps to fit the card
instead of forcing it wider. Because this is hooked at the carousel level rather than
patched into `HubShell._text_card`, it covers every current AND future caller
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

**A transparent body must not cast the theme-wide shadow either.** `menu_page.gd` wraps its
body box in `UITheme.shadowed()`, and that wrapper drew its 20%-black offset rect
unconditionally — normally invisible under the panel's own opaque face, but with `alpha:
0.0` there is no face to hide it, so the full body-sized rect showed through as "a dark
transparent container around all the cards". `UIHardShadowBox._draw` now skips the shadow
when the wrapped box has no fill — see
[ui-design-system.md](ui-design-system.md) → *Card drop shadow* → *An INVISIBLE box casts
no shadow*. The cards' own `shadow_right`/`shadow_bottom` slivers are a separate mechanism
and unaffected.

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
per-viewport. Four shapes were tried before landing on the one that holds:

1. **Every car, up front** — `HubShell._build_car` built one for EVERY car (every owned
   car plus the whole unowned catalogue). Blocked the main thread long enough on a real
   roster to read as the game freezing the moment a region was picked.
2. **A window of cards, rebuilt per move** — narrower, but every card in the window still
   got torn down and rebuilt from scratch on every `selection_changed`, which surfaced as
   the carousel visibly freezing the moment a player tried to MOVE the selection.
3. **Exactly one, reused** — fixed the freeze, but only the selected card ever spun; every
   other visible card sat there with a static placeholder, which read as broken once
   several cards are visible at once.
4. **A pool of N reused instances, one per SCREEN SLOT, scoped to the page** — every
   visible card finally got its own spinning preview, but a pool slot is tied to a
   POSITION on screen, not to a car: sliding the window still called `CarProp.spawn`
   again for whichever car newly occupied a slot, even a car the player had scrolled past
   and back to moments earlier. Reported as considerable lag on every selection move.

The shape that actually holds ties the expensive half — the spawned `CarProp` — to the
CAR, not the slot, AND makes the cache outlive the page: `CarPreviewCache`
(`car_preview_cache.gd`) is an AUTOLOAD, not a `HubShell`-owned `Dictionary` — `HubShell`
itself is torn down and rebuilt from scratch on every hub visit (a run always ends by
returning to it fresh via `Scenes.change_to`), so anything page-scoped forgets every car
each time, which a session-lifetime cache exists specifically to avoid. Every car card
still gets the cheap car-outline placeholder (`_card_icon("car")`) up front; `HubShell.
_sync_car_previews` asks `CarPreviewCache.get_or_build(car_ref)` for a preview whenever a
card enters the visible window (`CardCarousel.visible_card_count()`, centred on the
selection) and gets back either an ALREADY-BUILT instance (a cache hit — this car was
warmed or seen earlier) or a freshly spawned one (cached from here on). A card that
scrolls OUT of the window calls `CarPreviewCache.park(preview)` instead of freeing it —
parked previews sit in the cache's own hidden `graveyard` Control (a child of the
autoload, so it survives exactly as long as the game session does); `visible = false` on
an ancestor stops a `SubViewport` costing render time while parked, the same way it stops
any other `CanvasItem`. A card that STAYS in the window across a move is left untouched
entirely.

**Warmed behind the hub's loading screen, not built on demand.** `HubShell._ready()`
fires `CarPreviewCache.warm_all()` every time the hub loads, which walks every owned +
unowned-catalogue car and builds (then parks) whichever aren't cached yet, yielding a
frame every `_WARM_PER_FRAME` cars rather than doing it all in one synchronous burst —
building every car's preview synchronously in one call is the ORIGINAL freeze bug (shape
1 above), just moved to hub-load instead of removed, so the spread-out yielding is the
part that actually matters. On an INTERACTIVE load HubShell AWAITS the call while holding
its own `LoadingScreen` over the pages (MenuShowcase's build shows its own for the
background-track half of hub startup — same overlay pattern, second owner), so the
per-car build chunks land behind a loading screen the player reads as startup rather
than as a menu stuttering through its first seconds, and the CAR page afterwards opens on
pure cache hits. The original fire-and-forget form is retained for HEADLESS loads only
(tests/tools: no screen to hold, and suites must not block on warming). Awaiting
`warm_all()` means waiting for the whole cache even when a pass is already running — a
second call WAITS for the in-flight pass instead of returning "done" early, which is the
guarantee HubShell's loading screen relies on. Idempotent and cheap on every later hub
visit: a car already cached is skipped instantly, so only a genuinely new one (just
bought, say) costs anything — a post-run return to the hub holds its overlay for barely a
frame.

`CardCarousel.get_card(index)` is the accessor `_sync_car_previews` needs (reach back
into a card's `visual` slot after `add_card` returned it). Don't revert to a page-scoped
cache or to rebuilding a car's `CarProp` on every re-entry into view — both are exactly
the regressions this section documents. `CarCardPreview.show_car` still exists for a
caller that genuinely wants "this same viewport, a different car" (an existing, tested
capability of the class), but `CarPreviewCache` doesn't use it — a cache hit needs no
respawn at all.

**Known caveat, not yet handled:** the cache is keyed by car ref, not re-validated against
the car's current cosmetic state — an owned car's cached preview could go stale if its
paint/wheels/engine change via another menu (wheel customisation, engine swap) mid-session
without anything invalidating that cache entry. Not addressed here; flagged for whoever
next touches those flows.

## `CardUI` — the reusable card API

`scripts/card_ui.gd` (`CardUI`) pulls the card-BUILDING half of this widget — `card_icon`,
`text_card`, `build_carousel` — out of `hub_shell.gd` so a second screen
(`run_pick_panel.gd`, the between-stage pick) can build the exact same card shape without
duplicating the logic inline. **Temporary duplication, deliberate, not yet cleaned up:**
`hub_shell.gd` still carries its own private equivalents of the same three helpers
(`_card_icon`/`_text_card`/`_build_carousel`) — `CardUI` is the canonical version going
forward, and `hub_shell.gd`'s copies are pending consolidation onto it. Until that lands,
treat `CardUI` as the one to extend for a THIRD caller, and don't be surprised the two
private/public copies look near-identical — that's the known migration debt, not a bug.

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
