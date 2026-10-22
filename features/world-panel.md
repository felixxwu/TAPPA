# World-space menus (`WorldPanel`)

**Source:** `scripts/world_panel.gd` (`WorldPanel`).

**Tests:** `tests/headless/test_world_panel.gd`

> **DORMANT: the class is live, nothing hosts it.** Every screen that used to be a world
> panel lived on the deleted diegetic HQ. No production code constructs a `WorldPanel`;
> the only live use is the static `WorldPanel.layout_frame_size`, which flat pages call to
> measure the frame they lay out in (`card_ui.gd`, `ui_theme.gd`, `free_roam/world_pages.gd`).
> Read this file as the manual for re-hosting the mechanism.

A `WorldPanel` is **a menu that exists in the 3D world**: it hosts an ordinary menu
`Control` tree in an off-screen `SubViewport` and shows it on a **non-billboarded**
`Sprite3D`, so the panel is an object in the scene, welded at a fixed angle to whatever
it is parented to.

**The off-square angle is the point.** There is deliberately no billboarding, no
camera-facing rotation blend, and no runtime re-orientation anywhere in the class.
Foreshortening is the intended look. A panel has ONE mounting transform and the shot is
composed around it. Don't "fix" `billboard = BILLBOARD_DISABLED`.

**Which screens suit a panel:** one that is mostly a few controls attached to a thing you
are looking at. Dense information pages (tables of text) read badly at an angle — the two
HQ screens that were migrated and then reverted were exactly those.

## The `_frame` Control, and why it isn't optional

Every menu is laid out against the logical canvas `DisplayStretch` owns — `DESIGN_HEIGHT` tall
(`display/window/size/viewport_height`), width following the device aspect. A hosted tree full of
`PRESET_FULL_RECT` anchors and authored margins only lays out as intended against a frame of that
logical size. So a `Frame` Control sits between viewport and tree: it is exactly
`logical_size() / ui_scale` and is scaled by `SUPERSAMPLE * ui_scale` to fill the viewport. Host a
tree straight into the viewport and every margin in it is wrong.

`logical_size()` reads `DisplayStretch.DESIGN_HEIGHT` rather than hardcoding, so the two cannot drift.

### `ui_scale` — the "it's too small to read" dial

A panel hosts a FULL FRAME's worth of layout on one object, so every widget is small *relative to the
panel* however big the panel is. Moving or enlarging the panel scales the whole thing on screen;
`ui_scale` changes the ratio: the tree is laid out on a canvas `ui_scale` times smaller and then
scaled up, so widgets read bigger at no cost in rendered resolution.

**A smaller canvas fits less** — labels wrap to more lines and, worse, an `HBox` **cannot wrap** at
all, so a button row would run off the panel's right edge with its last button cut in half. That is
why a host of button rows needs a lower scale than a host of short readouts. `ui_scale` is a
constructor argument (`WorldPanel.new(height_m, ui_scale)`); its config fields were deleted with
the HQ.

**There is deliberately NO auto-fit.** A version of this measured the hosted tree's minimum size and
grew the canvas back until it fitted, so `ui_scale` could never clip. It was removed, and the reason is
worth keeping: **it could not be made to converge.** A minimum size is NOT independent of the canvas it
is measured in — autowrapped text changes height with width, and FILL-flagged children report larger
minimums in a larger box — so each refit could enlarge the canvas, which enlarged the minimum, which
enlarged the canvas. It hung two headless runs outright and would have hung the game. It also made the
value feel broken: raising `ui_scale` did nothing, because the clamp cancelled it exactly.

So the canvas is **exactly `logical_size / ui_scale`, always**. Too high a value clips — visible,
obviously wrong, and one edit away from fixed. That is a far better failure than an unbounded resize
loop, and it keeps the dial honest.

**Which dial for which symptom**, since this is the thing that costs the most time:

| symptom | dial |
|---|---|
| the whole menu is too small on screen | `world_panel_*_height` — a physically larger panel. No ceiling. |
| the text is too small *relative to the panel* | `world_panel_*_ui_scale`, until it starts to clip |
| a button row runs off the right edge | LOWER that screen's `ui_scale` (wider canvas), or shorten the row |

A panel's on-screen size is its metre height over its distance from the camera, and nothing else.
`ui_scale` cannot change it.

### Alignment per host: centring and left-align

Two opt-in metas, both applied by `apply_host_style` and both fully reverted for the flat layer:

- **`WorldPanel.CENTER_META`** — centres a Control vertically on a panel. Several screens anchor their
  content to the BOTTOM of the frame, which is right flat (a row over the 3D scene behind it) and
  wrong on a panel, where the panel IS the menu — content jumps bands between pages.
- **`WorldPanel.ALIGN_BEGIN_META`** — left-aligns a Control on a panel. `MenuPage` centres its panel
  horizontally (`SHRINK_CENTER`), so a page whose content width changes lands somewhere different each
  time, so a host's root rows and its sub-pages don't share a left edge.

**A trap worth recording:** the first attempt at centring used
`set_anchors_preset(PRESET_VCENTER_WIDE, keep_offsets = true)`, which kept offsets authored for a
BOTTOM-anchored box against completely different anchors — the column came out mis-sized and shoved
off the right edge, worse than the bottom-anchoring it replaced. Filling the frame and letting the
`BoxContainer` centre its own children is the honest way to say "centre this".

## Input: a SubViewport receives no window events

This is the crux. **A `SubViewport` has its own input and focus context and gets nothing from the main
window**, so every widget inside a panel — every `Button`, and `MenuNav` itself — is dead until the
panel pumps events across. The pump therefore forwards **everything**, keyboard and gamepad included.

**It is split across two input stages on purpose. It is not tidier to merge them.**

- **Pointer -> `_input` (early).** A host's own tap handling (say, picking an object in the 3D
  scene from its `_unhandled_input`) runs *before* its descendants, so
  forwarding at that stage would let the host act on a tap aimed at a button on the panel. Claiming it early and marking it handled is what
  stops one tap doing two things. Guarded by `MenuNav.input_blocked` so it cannot pre-empt an open
  `ConfirmPopup` above it.
- **Everything else -> `_unhandled_input` (late).** Native `ui_*` focus movement and a focused
  Control's key handling happen in the GUI phase *between* the stages; a panel that swallowed keys
  early would break the flat menus layered above it.

After pushing, the pump mirrors the SubViewport's verdict back, so the world behind a panel does not
also act on a consumed event. Touch needs no separate path —
`input_devices/pointing/emulate_mouse_from_touch` defaults on.

### `pixel_at`: analytic plane intersection, NOT an Area3D raycast

`pixel_at(screen_pos, bounded)` intersects the camera ray with the sprite's plane and converts the
local hit to UV. **No collider exists, deliberately:** it adds nothing to the physics world (the map
table already raycasts for pin picking, and a panel collider in front of those pins would intercept
them — a conflict that cannot arise if no collider exists); it is exact and independent of the physics
frame; and foreshortening concentrates mapping error at the far edge, where the conversion most needs
to be right. **Accepted trade-off: no occlusion test** — a press through geometry standing in front of
a panel still reaches it.

**`bounded = false` while a press is held**, so a slider dragged past the end of its track keeps
receiving positions (the `Range` then clamps itself) — on a foreshortened panel the cursor leaves the
quad far sooner than it looks like it should. Bounded is right for everything else: an unbounded
*press* would let a click metres off to the side land on a button.

`world_size()` derives the panel's metre extent from the sprite's own `pixel_size` and viewport size,
so the hit-test region can never disagree with the quad on screen.

## Post-processing applies, with no special-casing

Flat overlays are `CanvasLayer`s drawn *above* the `PostProcess` `SubViewportContainer` and are
deliberately ungraded. A `Sprite3D` is *inside* the scene, so grading, fog and tonemapping reach a
panel exactly as they reach the car beside it — that cohesion is the point, and the fog/exposure flags
are **not** disabled. See [rendering.md](rendering.md). **Standing risk:** the grade was tuned against
terrain and car paint, not UI text, so a grade retune can quietly hurt legibility.

## Adoption rule — which screens may become panels

**A screen migrates to `WorldPanel` only if its camera pose is authored and static.**

Screens under a free or orbiting camera — the title's orbit and the **pause** menu — **stay
screen-space permanently, by design.** A hard-welded panel under
an orbiting camera can be viewed edge-on or from behind with no recovery. This is a design rule, not
unfinished work; do not "complete the migration" by converting them.

**Consequence: shared components stay host-neutral.** Any menu component shared between a panel host and a flat
one (as `SettingsMenu` once was) must work in either without knowing which.

## Fitting content: measure the frame, not the viewport

Anything that sizes content to the screen must ask `WorldPanel.layout_frame_size(node)`, not
`node.get_viewport().get_visible_rect()`. Inside a panel the viewport is the `SubViewport`,
sized `logical * SUPERSAMPLE` — several times the `_frame` the tree is actually laid out on —
so a cap taken from it is far too generous and the content overflows the panel it is on.
Outside a panel the helper just returns the viewport rect, so callers need no host branch at
all. `UITheme._refit_body_scroll`, `CardUI` and `WorldPages` go through it.

## The `menu_nav.gd` change this required

`MenuNav.is_on_screen` already knew that a hidden `CanvasLayer` ancestor breaks the
visibility chain without changing anything on the `Control` chain. **A hidden `WorldPanel`
is the same trap one host later:** a menu in a panel lives inside a `SubViewport` whose
owning `Sprite3D` / `Node3D` chain is what gets hidden, and a `SubViewport` is not a
`CanvasLayer`. Without the added `Node3D` clause a hidden panel's `MenuNav` stays live and
keeps eating `menu_*` / `ui_cancel` from whatever is actually on screen.

See [menu-navigation.md](menu-navigation.md).

## What the tests guard

`tests/headless/test_world_panel.gd` — every panel built at a deliberately **off-square**
yaw, because a square-on panel would pass with a conversion that ignored the panel's basis
entirely. The cases that matter most:

- **The far foreshortened edge** maps to that edge. This is the point of the file: error
  concentrates at the far edge, so a pump that looks fine dead-centre can miss by a whole
  button out there.
- **A ray past the edge misses** (returns null), so the press is left for the world behind
  rather than clamped onto the nearest button.
- **A drag across a slider moves it**, and **a drag that leaves the panel keeps tracking**
  — the two cases that fail silently if the pump forwards only press and release.
- **`ui_scale` shrinks the layout canvas while still filling the panel** — asserted as a
  relationship (double the scale = half the canvas, same rendered coverage), never as a
  particular scale value. Get the second half wrong and the menu is bigger but cropped.
- **Keys reach a hosted `MenuNav`** and move focus inside the panel's own viewport.
- **`layout_frame_size` reports the frame, not the supersampled viewport** (and falls back to
  the viewport outside a panel), **`apply_host_style` can be forced** over content added after
  adopting, and **`hosted()` forgets a tree that was taken back** — the three helpers the
  host-awareness rules above are built on.
- **A hidden panel stops compositing and forwards nothing**, and **`MenuNav` is inert
  inside one.**

Test positions are built **forward** (panel UV → world point → screen via
`unproject_position`), never by reusing the pump's own maths — otherwise a wrong conversion
would agree with itself and pass.

**No tunable is asserted** (project rule): not `SUPERSAMPLE`, not the panel's metre height,
not the marker offset or yaw. Those are look values retuned by eye, so the tests assert the
behaviour that must hold at any of them.

