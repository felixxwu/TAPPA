# World-space menus (`WorldPanel`)

**Sources:** `scripts/world_panel.gd` (`class_name WorldPanel` — the panel itself, plus the
`text_backing` / `apply_host_style` statics every host reuses),
`scripts/world_panel_host.gd` (`class_name WorldPanelHost` — one station's swap between its
flat layer and a panel), the two stations' wiring in `scripts/hq.gd`
(`_sync_panel`, `_car_panel_xform`, `_lift_panel_xform`), the tree handles set in
`scripts/hq_overlays.gd` (`build_car_overlay` → `_car_root`, `build_lift_overlay` →
`_lift_root`), the `Node3D` clause in `scripts/menu_nav.gd` (`is_on_screen`), and the
`world_space_menus` / `world_panel_*` fields in `scripts/game_config.gd`.

**Tests:** `tests/headless/test_world_panel.gd`, `tests/headless/test_menu_flow.gd`

Tests: `tests/headless/test_world_panel.gd` (the panel and its input pump), plus the hosting /
hot-reload tests in `tests/headless/test_menu_flow.gd`
(`test_hq_carpark_world_space_menu_hosts_backs_and_reframes`,
`test_hq_lift_hosts_its_menu_on_a_world_panel`, `test_hq_hot_reload_keeps_the_world_menu_toggle`,
`test_hq_panel_ui_scale_retune_reaches_the_panel`). None of them assert a POSITION — placements are
hand-tuned, see below.
Design: [`docs/superpowers/specs/2026-08-10-world-space-menus-design.md`](../docs/superpowers/specs/2026-08-10-world-space-menus-design.md).

A `WorldPanel` is **a menu that exists in the 3D world**: it hosts an ordinary menu
`Control` tree in an off-screen `SubViewport` and shows it on a **non-billboarded**
`Sprite3D`, so the panel is an object in the scene, welded at a fixed angle to whatever
it is parented to.

**The off-square angle is the point.** There is deliberately no billboarding, no
camera-facing rotation blend, and no runtime re-orientation anywhere in the class.
Foreshortening is the intended look. A panel has ONE mounting transform and the shot is
composed around it. Don't "fix" `billboard = BILLBOARD_DISABLED`.

## Status

**Four screens migrated** — car park, tuning lift, title and garage — behind
`Config.data.world_space_menus`, which the SHIPPED `config/game_config.tres` sets **ON** (the code default
in `game_config.gd` is off, so a test or tool that never loads the resource sees the flat path — do not
mistake that for what players get). The flat `CanvasLayer` path stays fully wired for all four.

**Nothing further is planned.** The map table was considered and dropped — it reads well flat, and both
screens at that station were tried on panels and reverted. Settings is not a task but a CONSTRAINT:
`SettingsMenu` must stay host-neutral because the pause menu it shares is permanently flat.

**TWO SCREENS WERE MIGRATED AND THEN DELIBERATELY REVERTED** to full-frame. Both are decisions, not
omissions — don't re-migrate them as unfinished work:

- **The rally detail page.** The densest page in the HQ (name, region, restriction, record, star row,
  reward line), read at the map table — whose camera sits under 2 m from the table looking steeply DOWN,
  so a panel there is read at a punishing angle and has to be small to fit the shot.
- **The online challenge screen.** Likewise dense (period, ceiling, eligible-car list, leaderboard) and
  likewise better with the whole frame than welded to a panel in the garage.

The pattern worth taking from both: **a diegetic panel suits a screen that is mostly a few controls
attached to a thing you are looking at, and suits a dense information page badly.** The four that
migrated are button rows and short readouts; the two that came back are tables of text.

- **Toggle live (debug builds only):** **F7** (`toggle_world_menus`), handled in
  `hq.gd::_unhandled_input`. Same shape as the wheel-force arrows' **H** — a config that starts
  world menus on works in any build, but the live key is a dev affordance and release exports
  ignore it.
- **Toggle persistently:** `world_space_menus` in `config/game_config.tres`. Note the `.tres`
  stores **no** `world_panel_*` overrides, so the values in `game_config.gd` are what's live and
  **editing them needs a restart** — F7 only flips the mode, it does not reload config.

**The lift is the screen that proved the input pump.** The car park could only ever demonstrate
taps and the look: its buttons are `FOCUS_NONE` with `_passthrough_overlay`, and it has no
sliders, so nav there is `hq.gd`'s spatial handler rather than `MenuNav`. The lift's sub-pages are
native-focus with real `HSlider`s, and the user confirmed drag and gamepad focus work through the
panel in the running game — which closed the design's spike gate.

## Tuning it live — no restart (F8)

**The loop:** open `config/game_config.tres` in the editor inspector, change a `world_panel_*` value
(or a station camera field), then press **F8** in the running game. `Config.reload_from_disk()`
re-reads the file and `hq.gd` re-applies it in place — you keep your position in the HQ.

**Why `Config.reset()` could not do this.** `load()` returns the **cached** resource — the copy the
process read at boot — so reset() re-duplicates stale values however many times it is called.
`reload_from_disk` uses `ResourceLoader.CACHE_MODE_REPLACE`, which actually goes back to the file
(and refreshes the cache, so later `load()`s agree with what is live).

**What updates without even pressing F8**, because it is read per frame: panel offset, yaw, pitch,
and the camera look/eye shifts — `WorldPanel._process` re-evaluates its anchor and the station poses
are re-derived each frame. So editing those through the editor's **Remote scene tree** (select the
`Config` autoload, expand `data`) is live as you drag.

**What needs the F8 re-apply:** `world_panel_*_height` and `*_ui_scale`. Both are baked in at panel
construction, so the host has to notice the change and rebuild — which it does on the
`_update_overlays()` that F8 triggers.

**Two caveats.** It is a **debug-build-only** key (same rule as the wheel-force arrows' H), and it
replaces `Config.data` wholesale, which **discards runtime mutations** — notably `car.gd`'s
`apply_car`, which reshapes the live config for the fielded car. Fine while tuning a menu's look;
not a game feature.

**Editing the SCRIPT defaults still needs a restart.** `game_config.gd` is compiled into the running
process. Tune on the `.tres` (an exported property shows in the inspector even when the `.tres`
stores no override for it — editing one stores it), not in the script.

## Placements are tuned BY HAND, live

Every placement in the "World-space menus" group of `game_config.gd` / `game_config.tres` is a
hand-authored set of metres and degrees. Tune them with the **F8 loop above** — edit, press F8, look.

There is **deliberately no automated framing test.** One existed (`test_world_panel_framing.gd`) that
projected each panel through its station camera and asserted it was fully on screen with its subject
visible, printing the exact height multiplier and world nudge needed. It was how the first pass of
these values was set, and it was removed once the placements moved to hand tuning: a test that
asserts a composition is a test that fails every time a designer legitimately recomposes, which is
the project's own rule against pinning tunable values.

**Four failure modes it used to catch, so they are worth knowing by eye instead:**

1. **A panel edge off-frame.** Most often the RIGHT edge, and most often a row of buttons rather than
   the panel itself — see the `ui_scale` note below.
2. **The subject pushed out of shot.** A panel that fits by shoving the car off-frame is not a fix on
   a screen whose job is showing you that car.
3. **THE PANEL BURIED IN THE GROUND.** A panel is depth-tested geometry, and growing one grows it
   about its CENTRE — so every height increase pushes its bottom edge down by half of it. This is how
   the title menu went **completely invisible** while still projecting perfectly on screen: its
   content sits at the bottom of its canvas (`ALIGNMENT_END`), and the bottom was ~1.6 m under y=0.
   If a panel vanishes and the position looks right, check whether it is underground.
4. **Occlusion generally** — a wall or prop in front of a panel hides it, and nothing checks for that.

**Two measurements that stay true and are easy to mis-guess:**

- **The logical frame is `viewport_height` tall and NARROWER than 16:9 of it** — 618x400 on a 16:9
  window at the current 400, because `DisplayStretch` divides the width by `horizontal_stretch`.
- **The camera's vertical FOV is 75 degrees, so the HORIZONTAL half-angle is about 50**, not 37.5.
  A panel that overhangs vertically can still fit across the frame.

## Relationship to the map-table pin labels

`hq_map_table.gd::_build_readout_sprite` does the same `SubViewport` -> `Sprite3D` trick for pin labels. That
path is **billboarded** and sets `gui_disable_input = true` (a label, not a menu); `WorldPanel`
inverts both. Three lessons it already paid for are inherited and are not optional:

1. **`render_target_update_mode` follows visibility**, and is never `UPDATE_ALWAYS` while hidden — 32
   pin viewports re-compositing invisible UI once cost ~1.9 MP/frame. `_apply_visibility` is the
   single place it changes.
2. **A SubViewport on a 3D quad loses resolution twice**, so a panel composites at `SUPERSAMPLE`x its
   logical size. **`SUPERSAMPLE` is 4** — menus are the one surface that should NOT look low-res: the
   PS1 aesthetic comes from the world's internal resolution and the dither/quantise post pass, while
   text on a foreshortened quad is where softness reads as a bug rather than a style.
   **It moves nothing:** world size is `vp.size * pixel_size` with `pixel_size = height_m /
   vp.size.y`, so the two cancel and a panel is `height_m` tall at any supersample; the frame's scale
   carries the factor, so the layout canvas still fills the viewport; `pixel_at` works in UV, so
   hit-testing follows. The cost is quadratic (~4.5 MP per target at the current logical height),
   affordable only because one panel is visible at a time and hidden ones are `UPDATE_DISABLED`.
   First knob to turn down if a phone struggles.
3. **The theme's hard black drop shadow is invisible on a black panel** — cleared per-surface.

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
why screens built of button rows get their own, lower scale (`world_panel_lift_ui_scale`,
`world_panel_garage_ui_scale`, `world_panel_title_ui_scale`) alongside the shared
`world_panel_ui_scale`.

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
  content to the BOTTOM of the frame, which is right flat (a row over the 3D station behind it) and
  wrong on a panel, where the panel IS the menu. On the lift that showed as the content JUMPING BANDS
  between pages: the hub column sat low while `MenuPage` centred the Upgrades/Tuning body.
- **`WorldPanel.ALIGN_BEGIN_META`** — left-aligns a Control on a panel. `MenuPage` centres its panel
  horizontally (`SHRINK_CENTER`), so a page whose content width changes lands somewhere different each
  time; the lift's hub rows and its sub-page did not share a left edge.

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

- **Pointer -> `_input` (early).** A station's own tap handling (`hq.gd`'s `_unhandled_input`, which
  picks cars out of the lineup) runs *before* its descendants, so forwarding at that stage would let
  HQ act on a tap aimed at a button on the panel. Claiming it early and marking it handled is what
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

Screens under a free or orbiting camera — the **start-line** pre-stage orbit, the **wreck-screen**
orbit and the **pause** menu — **stay screen-space permanently, by design.** A hard-welded panel under
an orbiting camera can be viewed edge-on or from behind with no recovery. This is a design rule, not
unfinished work; do not "complete the migration" by converting them.

**Consequence: shared components stay host-neutral.** `SettingsMenu` backs both the HQ settings
overlay and the (permanently flat) pause menu, so it must work in either host without knowing which.
Same for any future shared menu component.

## Station anchors — two conventions

| Station | Anchor | Convention |
|---|---|---|
| Car park | focused car's runtime `Marker3D` | welded to the car; marker basis is FLIPPED (see signs table) |
| Tuning lift | `hq_lift_pos`, world space | welded to the bay; no flip; the car noses -Z |
| Title / garage | that station's **camera look target** + offset | see below |

**The later screens changed tactic deliberately.** Welding to a car and then panning the
camera to find the panel cost several eyeball passes per station. Anchoring instead to the point
the camera **already aims at** (`_looked_at_panel_xform`) means the panel starts in shot — and
none of those four needs a camera shift at all, where the first two both did.

**Pitch is supported but currently unused at any station.** `hq.gd::_panel_basis` applies yaw about
world up, then pitch about the panel's own X. It was added for the map table, whose camera looks steeply
DOWN — an upright panel there is read almost edge-on, so a pitched one lies back toward the camera (a
briefing sheet angled on the table rather than a screen standing on it). The rally-detail page that
needed it went back to full-frame, so the mechanism is kept for whenever the table itself is migrated.

**Each station carries its own height** because their camera distances differ enormously (the
garage shot is ~8 m out, the table camera under 2 m), and one size cannot serve both. `ui_scale`
stays shared until a station proves otherwise, as the lift's unwrappable button rows did.

### Lift and car-park specifics

The lift needed one structural change: its layer had **two** anchored children (the sub-page
`MenuPage` and the hub column), and a panel hosts a single `Control` — so
`build_lift_overlay` now wraps both in one full-rect `_lift_root`. Both children keep their
own anchors, resolved against that root instead of the layer, so the flat layout is
unchanged.

**The garage is a much tighter space than the open car park** — enclosed bay, close camera —
so the lift has its own `world_panel_lift_*` fields rather than sharing the car park's.

Two of those exist for reasons worth knowing, because both contradict a rule stated elsewhere
in this document:

- **`world_panel_lift_ui_scale` — the lift does NOT share `world_panel_ui_scale`.** Its content
  is *wider* than the car park's: the selector row (‹ / name / › / Repair) and the hub row
  (Back / Upgrades / Tuning / Test Drive) are **HBoxes of buttons, and an HBox cannot wrap**.
  The autowrap fix that saved the car park's labels does nothing for them, so on too narrow a
  canvas the row simply runs off the panel's right edge and "HEALTH 100%" / "TEST DRIVE" get cut
  in half. A LOWER scale gives a WIDER canvas and the rows fit. For a screen built of button
  rows, this is the dial — not the panel size.
- **`world_panel_lift_camera_eye_shift` — the one station where a panel moves the EYE**, not
  just the aim (see "The camera PANS, it does not move" above, which the car park still obeys).
  The bay is genuinely too tight to solve by panning: the lift car's nose sits ~1.2 m from the
  eye, so the near car covers a wide wedge of screen and **occludes** any panel level with or
  behind it — no aim solves an occlusion. Pulling back shrinks the car's angular size and
  separates the two. Note −Z here moves *away* from the garage (whose footprint starts at z=0,
  `HQEnvironment._build_garage`) and out into the open, so pulling back cannot push the camera
  through a wall; going the other way would.

**Placement matches the car park**: the car's **front-left corner, just past the nose**. On the
lift the car noses −Z and its left is −X, so that corner is −Z and −X of `hq_lift_pos`. Being
ahead of the nose is what fixes the occlusion, not merely the framing.

## The car-park host swap

`hq_overlays.gd::build_car_overlay` stores its tree on `hq._car_root`, and
`hq.gd::_sync_panel` hands each migrated screen to its `WorldPanelHost` — a move,
not a rebuild. `_update_overlays` calls it AFTER setting layer visibility so it has the final
say on which host is showing.

Two wiring details worth knowing:

- **`_normalize_menus` enforces the house rules from a node DOWN**, so an empty
  `_car_layer` enforces nothing. It enforces `_car_root` directly whenever the tree is not
  under the layer.
- **The anchor is the focused car's `Marker3D`, not an authored scene node**, because the
  car-park lineup is built at runtime (one marker per owned car, laid out along X) — there
  is nothing fixed in `hq.tscn` to weld to. The panel's local offset and yaw from that
  marker are fixed and never recomputed against the camera, which keeps the weld honest.
  `hq_carpark.gd::_focus_changed` re-places the panel because that is the one place the
  selection actually changes.
- **An empty lineup means NO anchor, and a panel that silently stays where it last was.**
  `hq.gd::_car_panel_xform` reads `_markers[_focus]` and returns `null` when `_markers` is
  empty; `WorldPanel.place` early-returns on a null transform, so the panel keeps its stale
  pose — usually off-screen — and everything living on it (the shared `_start_button`
  included) is simply not where the player is looking. Nothing errors, which is what makes
  it a trap. This bit the present box: `hq.gd::_enter_present_box` clears the lineup for an
  empty lot, and `hq_carpark.gd::_release_page_props` frees every marker with it, so the
  "Open it" button had no anchor until `_open_present` happened to create one. The fix is
  the rule for any future mode too — **if you clear the lineup, put a marker back before
  `update_overlays()`**: `hq.gd::_add_present_marker` seats a single bay marker at
  `HQEnvironment.carpark_center()` (with the usual `rotation.y = PI`) and `_focus = 0` is
  set alongside it, so the panel is welded while the box is still shut.

### The marker's axes are FLIPPED — mind the signs

`hq_carpark.gd::_render_lineup_page` builds each lineup marker with **`rotation.y = PI`**,
so the car parks nose-out toward the courtyard camera. Everything in
`world_panel_car_offset` / `world_panel_car_yaw_deg` is expressed in that rotated marker
space, where:

| Marker-local | World | Meaning |
|---|---|---|
| `−Z` | `+Z` | the car's **nose** (toward the camera) |
| `−X` | `+X` | the car's **left** (screen-**right** from the menu camera) |
| `+Y` | `+Y` | up |

Get this backwards and the panel lands behind the car, off-screen, which reads as "the
panel didn't appear" rather than as a sign error.

### Current placement, and why it isn't square-on

The panel sits at the focused car's **front-left corner**, pushed forward and roughly one
`menu_car_spacing` to the left, so it stands **in front of the neighbouring car** on that
side instead of over the focused one. `world_panel_car_yaw_deg = 180` turns it to face the
camera side, which makes its **plane perpendicular to the car's direction** and its **width
run along the row** of parked cars.

**That yaw does not make it square-on to the camera**, and this is worth understanding
before anyone "corrects" it: the menu camera is a front-3/4 shot (`menu_camera_offset`), so
the off-square read comes from the **camera's** pose, not from skewing the panel. Which is
exactly what the design asked for — one honest mounting transform, with the shot composed
around it.

**Standing tension to watch when tuning:** the 16:9 aspect means width is always ~1.78× the
height, so a panel made large enough to read easily is wide, and one placed close to the
camera will start to cover the focused car. The right fix for "too small" is usually
`world_panel_ui_scale` (bigger UI, same physical panel) rather than
`world_panel_height` (bigger panel, more occlusion).

### The camera PANS, it does not move

`hq.gd::_camera_target_xform` adds `world_panel_camera_look_shift` to the car-park camera's
**look target** while world menus are on, leaving `menu_camera_offset` (the eye) alone.

This distinction is the whole point and was learned the wrong way round first: shifting the
**eye** recomposes the entire shot and moves the car within it, where shifting the **aim**
brings the panel into frame from the same viewpoint. Guarded by `test_menu_flow.gd` →
`test_hq_carpark_world_space_menu_hosts_backs_and_reframes`, which asserts **both** halves
(origin unchanged, basis changed) precisely so a future "simplification" back to an eye
offset fails.

### Label backings, and the clipping trap

The panel's viewport is transparent, so the 3D car park shows straight through behind the
menu. A `Button` carries its own surface and stays readable; a **bare `Label` does not**, so
`hq.gd::_text_backing` wraps each of the car overlay's labels in a `PanelContainer` that
wears `UITheme.panel_box` — the same "text on an opaque black box" look
`_build_readout_sprite` uses for the map-table readouts.

Three details that are each load-bearing:

- **The box is applied ONLY while world-hosted** (`_apply_car_text_backing`, called from
  `WorldPanel.apply_host_style`); flat, the wrapper wears a `StyleBoxEmpty`. World menus are off by
  default and the flat car park is the shipped look — this feature must not restyle it.
- **The wrapper mirrors its child's visibility.** Several of these labels are hidden/shown
  by name (`_car_warning_label`, the present-box hint, the swap preview) and every call site
  sets the *label*. Without mirroring, a hidden label leaves its wrapper drawing a small
  empty black blob where the text used to be.
- **The wrapper FILLS the width and its label autowraps.** This is the fix for real observed
  clipping: at a high `ui_scale` the canvas is narrow, and a shrink-to-content box let long
  lines grow *past* the panel edge where they were cut off mid-word ("SH*TBOX CUP - NEEDS
  50-90 HP/" with the remainder simply gone; likewise the car name and the stats line).
  Filling gives the label a real width to wrap within. The banner, the stats line and the
  car-name row therefore set `AUTOWRAP_WORD_SMART` — they never wrap on the wide flat
  canvas, so this costs the flat look nothing.

### ...and then vertical overflow, which is why the rows are tighter

Wrapping trades width for lines, so the clipping moves to the **bottom** next — which it
did: with a two-line stats row, the screen-authored **16 px margins and 12 px row gaps**
no longer fit a canvas only ~200 px tall (at `ui_scale` 1.8, against 360 flat), and the
action row was pushed off the panel with Back / Start Rally cut in half.

So `WorldPanel.apply_host_style` also **tightens the layout for the world host** —
separation `12 → 4`, margins `16 → 8`, and the label boxes' own padding — and reverts all of
it for the flat host. Closing the gaps buys back more height than any font change, and costs
the flat look nothing.

Two details that keep it honest across screens: it is deliberately ONE function doing both
the backings and the metrics (they must flip together on every host swap, and a second entry
point is how one of them ends up left behind in the wrong host), and the flat metrics are
**recorded on the tree itself** (`FLAT_METRICS_META`) on first adopt rather than restored from
a constant — so a screen that authored different margins gets its own values back, not the
car park's.

**If it still overflows**, the screen genuinely needs its content trimmed rather than
scaled — the content pressure the design doc named as the price of hosting trees verbatim.
The car screen's stats line is the obvious candidate (drive mode, power, mass, health and
NOS on one row).

## Visibility rules live in `_update_overlays`, not in the screens

`hq.gd::_update_overlays` drives every migrated screen through `_sync_panel`, which owns its
layer's visibility — because whichever host is NOT holding the tree must be hidden, or an empty
`CanvasLayer` (or an unfed panel) is left armed.

That makes any "screen A hides while B is up" rule belong here too. **The garage stands down while
the challenge modal is over it** (`_view == View.GARAGE and not _challenge_shown`). That used to be
an ad-hoc `_garage_layer.visible = false` inside `_open_challenge_overlay`, and it broke the moment
that function also had to call `_update_overlays` — which then re-showed the garage a line later.
Caught by `test_menu_flow.gd` -> `test_hq_challenge_entry_opens_and_is_navigable`.

Related: **the challenge screen's shown-ness is a flag (`_challenge_shown`), not its layer's
visibility.** It is a modal rather than a `View`, and in world mode its layer is empty — so code
that asked `_challenge_layer.visible` (including `hq.gd::_unhandled_input`'s guard that stops the
garage reacting to the same keypress) had to move to the flag.

**The same rule caught a second screen: the Android boot notice.** It hid the title with
`_title_layer.visible = false`, which in world mode addressed an already-hidden, empty layer — so the
notice drew over a live title menu and both `MenuNav`s answered the same keypress. The title's
shown-ness is now part of the rule here (`_view == View.EXTERIOR and _android_notice_layer == null`)
and both handlers call `_update_overlays()`. Guarded by
`test_menu_flow.gd` -> `test_android_notice_stands_down_a_world_hosted_title`.

**And the mirror-image rule for runtime UI: a modal never goes ON a station's layer.** Adding a page
to `_car_layer` puts it on the host that `sync` hides, so it renders nowhere. `MenuPage.open_modal`
owns the correct hosting (own `CanvasLayer` below `ConfirmPopup`, plus a
`MenuNav.SCREEN_CLAIMER_GROUP` claim so `WorldPanel._input` stops projecting the page's clicks into
the station behind it) — see features/menus.md -> "Hosting a modal".

**Formerly a known consequence on the title screen, now fixed:** the build-version watermark is a
separate child of the title layer rather than part of the menu tree, so a panelled title took the
watermark down with the flat layer — the readout naming the build was missing from the shipped
configuration. It has its own `CanvasLayer` now (`hq.gd::_version_layer`), shown with the title
screen on either host.

## Which host is live — ask, never derive

`WorldPanelHost.is_world()` is the one answer to "is this screen on its panel right now?".
Callers used to spell it `tree.get_parent() != flat_layer`, duplicated between
`release_tree` and `hq.gd::_normalize_menus` — a spelling that changes meaning the moment a
tree is parked anywhere else. `WorldPanel.hosted()` is **self-correcting** for the same
reason: `release_tree` re-parents the tree straight back to the flat layer (it must — freeing
a panel that still holds the tree takes the menu with it), so a stored `_hosted` went stale on
every revert and reported a flat screen as panelled. It answers from the scene tree instead.

Two things depend on that answer being right:

- **`gui_release_focus` must reach both hosts.** `hq.gd::_release_all_focus` releases the main
  viewport AND every panel's `SubViewport`, because a migrated station's focus owner lives in
  the latter. Without it, a button on the station you just left keeps focus and swallows arrow
  keys / Enter in the next one — the exact bug the release exists to prevent, live again in
  world mode.
- **Rebuilt content must be re-styled.** `WorldPanel.apply_host_style(root, world, force)`
  takes a `force` flag, and `_normalize_menus` passes it for whichever trees are currently
  panelled. The cheap early-out keys off the tree ROOT, so nodes added by a rebuild that
  happens *while hosted* (the Mystery Box garage repaint never goes through `_go_to`) kept
  their flat `StyleBoxEmpty` — a bare label over a sunlit car park — and never got centred.

## Fitting content: measure the frame, not the viewport

Anything that sizes content to the screen must ask `WorldPanel.layout_frame_size(node)`, not
`node.get_viewport().get_visible_rect()`. Inside a panel the viewport is the `SubViewport`,
sized `logical * SUPERSAMPLE` — several times the `_frame` the tree is actually laid out on —
so a cap taken from it is far too generous and the content overflows the panel it is on.
Outside a panel the helper just returns the viewport rect, so callers need no host branch at
all. `UITheme._refit_body_scroll` and `hq.gd::_modal_body_width` both go through it.

## The layers a host manages hold ONE thing

A `WorldPanelHost`'s flat `CanvasLayer` holds its screen tree and nothing else. Anything else
parented there renders nowhere the moment world menus are on, silently — see
[menus.md](menus.md) → "Hosting a modal" for the modal rule, and note the **build-version
watermark** now has its own `CanvasLayer` (`hq.gd::_version_layer`, shown with the title
screen) rather than riding on `_title_layer`, where it was invisible for the whole session in
the shipped configuration. In debug builds `WorldPanelHost._stand_down_flat` `push_warning`s
any stray it finds, naming the node — the invalid state announces itself at the moment it is
created instead of turning up as "that menu does nothing". A stray that genuinely means to go
down with the layer sets `ALLOW_HIDDEN_META`; nothing does today.

Guarded by `test_menu_flow.gd` -> `test_migratable_layers_gain_no_runtime_children`, which
drives every runtime-UI entry point over a station and asserts each managed layer still holds
only its tree.

## The `menu_nav.gd` change this required

`MenuNav.is_on_screen` already knew that a hidden `CanvasLayer` ancestor breaks the
visibility chain without changing anything on the `Control` chain. **A hidden `WorldPanel`
is the same trap one host later:** a menu in a panel lives inside a `SubViewport` whose
owning `Sprite3D` / `Node3D` chain is what gets hidden, and a `SubViewport` is not a
`CanvasLayer`. Without the added `Node3D` clause a hidden panel's `MenuNav` stays live and
keeps eating `menu_*` / `ui_cancel` from whatever is actually on screen.

See [menus.md](menus.md) → "Menu navigation" for the two flat-menu regimes this sits
alongside.

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

## Deferred

- **Migration of the remaining HQ screens.** Order from the design doc: tuning lift →
  rally detail + challenge → garage + title → map table (last; needs the pin-picking
  question answered even though no collider is added) → settings (dual-host).
- **Per-screen re-layout to panel-shaped viewports.** Trees are currently hosted verbatim
  at 16:9. Individual screens can later be laid out for a physical aspect ratio without
  touching `WorldPanel`; the car spec sheet is the strongest candidate.
- **Occlusion**, if a panel ever becomes walk-behind-able.
