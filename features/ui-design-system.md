# UI design system

**Sources:** `scripts/ui_theme.gd` (`UITheme`), `theme/ui_theme.tres` (generated),
`tools/build_ui_theme.gd` (generator), `fonts/` (Syne Mono), and the
project default-theme wiring in `project.godot` (`[gui] theme/custom`).

One place that defines how every menu, panel and button looks, so the UI reads as
one polished, consistent whole instead of a pile of one-off `Color(...)` literals
and ad-hoc font sizes. The look is lifted from the previous **web build** of this
game: a retro arcade / terminal aesthetic.

## The look

- **Hand-drawn monospace font** (Syne Mono) — stat read-outs and money columns
  line up while the lettering keeps a characterful, slightly informal feel.
- **Pure-black, sharp-cornered panels** — no rounded corners, no gradients, no
  blur.
- **Crisp white text with a hard drop shadow** (the chunky terminal look). One
  documented exception — see "Gauge captions" below.
- A **tight accent palette**: **green** = active / selected / positive,
  **gold** = money / reward, **red** = danger / run timer / warning.

## House rules (enforced)

These are hard rules, not suggestions — `UITheme.enforce(root)` applies 1–3 to
every `Label`/`Button` under a menu root, and the global theme bakes in 2–4 as the
defaults:

1. **All menu text is UPPERCASE** (`UITheme.caps`).
2. **One fixed font size everywhere** (`UITheme.FONT_SIZE`, deliberately small) —
   no per-screen size hierarchy; titles, headings, body and buttons all match.
3. **Single-line menu buttons are a fixed, compact height** (`UITheme.MENU_ROW_H`).
   Multi-line rows (e.g. the settings option rows, which embed their own layout)
   are left to size themselves.
4. **Menu backgrounds are pure black** — buttons and panels alike. **One documented
   exception:** a star-gated SPECIAL event's floating map-pin readout is inverted (white
   face, black ink) so it stands out from a map of otherwise-identical black panels — see
   `hq.gd`'s `ACCENT_READOUT_BG` and [menus.md](menus.md). Any further exception should be
   argued and listed here, not added quietly; the rule is what makes the look coherent.

Menu builders call `UITheme.enforce(root)` once after building; screens with
dynamic text re-run it whenever that text changes (HQ on every view change /
focus / lift refresh, the podium after each reveal) so the rules keep holding.
The HUD, mobile controls and other in-world overlays are **not** menus and are
left alone (e.g. the big 3·2·1 countdown stays large).

## How it's applied (two layers)

1. **Global theme** — `tools/build_ui_theme.gd` reads the constants in `UITheme`
   and writes `theme/ui_theme.tres`, which is wired as the project-wide default
   theme (`project.godot` → `[gui] theme/custom`). **Every `Control` inherits the
   font, the button/panel styleboxes, the text colour and the drop shadow
   automatically** — this is what makes the whole game consistent without touching
   each widget. Scripts that still call `add_theme_font_size_override(...)` only
   change the *size*; the face, colour and shadow come from the theme.
2. **`UITheme` helpers** — the bits a flat theme can't express on its own:
   role-coloured labels (`UITheme.money`, `UITheme.label(text, "green")`),
   pure-black panel boxes (`UITheme.panel` / `panel_box`), the rule-enforcing
   `UITheme.enforce(root)`, and the selection treatment from the web build — a
   green underline + green text (`UITheme.mark_selected`) and the **▶ ◀** markers
   around the focused option (`UITheme.flank`).

## Single source of truth

Tune the palette / type scale / spacing in **`scripts/ui_theme.gd`**, then
regenerate the theme:

```
godot --headless --script tools/build_ui_theme.gd      # → theme/ui_theme.tres
```

Don't scatter new colour/size literals through the UI scripts — add them to
`UITheme` (and re-run the generator if they belong in the global theme). 3D world
materials (concrete, tarmac, podium steps, garage) are **not** UI and keep their
own colours.

### The palette is grade-baked

The palette constants are **derived, not authored**: each one has been run through
the world's colour grade (the GRID look — see
[rendering.md](rendering.md) → "Colour grade") so menus sit in the same palette as
the 3D they overlay. Each line keeps its authored design intent in a trailing
comment, and that authored value is the real intent.

The UI is deliberately **not** shader-graded. It lives on CanvasLayers drawn above
the post-process container, so reaching it would need a top layer sampling
`hint_screen_texture` — whose `BackBufferCopy` costs a render-pass break every
frame, a fixed cost that doesn't shrink with resolution and forces a tile-buffer
resolve on mobile GPUs. Because `UITheme` already centralises the palette as flat
constants, grading them once offline buys the same cohesion for zero runtime cost.

The consequence: **retuning the grade does not update the UI.** Re-bake, then
regenerate the theme:

```
godot --headless --script tools/bake_ui_palette.gd      # prints graded literals
godot --headless --script tools/build_ui_theme.gd       # → theme/ui_theme.tres
```

Paste the bake output over the palette block. `tools/bake_ui_palette.gd` holds the
authored palette itself and re-derives from that, so it's idempotent — running it
twice never double-grades. Its grade maths must stay in step with
`shaders/ps1_post_process.gdshader`; the vignette is omitted (a spatial screen
effect is meaningless on a palette entry) and alpha is passed through untouched.

Two things the bake does **not** cover, both intentional: the pure blacks come out
unchanged (a black pixel has no hue to shift and the contrast curve clamps at
zero), so house rule 4 still holds exactly; and anything *dynamically rendered*
into the UI — car thumbnails, the map-pin label viewports, `SubViewport` previews —
is real rendered content rather than a palette entry, so it stays ungraded.

Backdrops in particular used to drift (a hand-typed `Color(0, 0, 0, 0.96)` per
popup). There are exactly two:

- `UITheme.PANEL_DIM` — a menu sits over the still-legible world (pause menu).
- `UITheme.MODAL_DIM` — a blocking modal fully interrupts it (`confirm_popup.gd`,
  the HQ car-park prompts, the seed-lab popups).

Use one of those for any new dimmer rather than picking a fresh alpha.

## Where it's used

The global theme covers HUD, mobile controls, the loading screen and every menu.
Specific design-system touches:

- **HQ** (`hq.gd`) — rally-detail, tuning-lift and info panels are black house
  panels; the wrecked-car warning is red.
- **Settings** (`settings_menu.gd`) — selected camera/scheme rows use
  `UITheme.mark_selected` (green underline) instead of the old blue tint.
- **Pause** (`pause_menu.gd`) — `PAUSED` on a black title plate (button wording
  unchanged).
- **Podium** (`podium.gd`) — the reward card is a black panel with a green accent
  border; the player's leaderboard row is gold.
- **Standings** (`standings.gd`) — black background; the player's row is gold.
- **Wreck screen** (`wreck_screen.gd`) — red heading on a dim black backdrop.
- **HUD** (`hud.gd`) — the run timer is white (neutral ink), the stage-complete banner green.

## A passive readout in a row of buttons (`UITheme.readout_box`)

A read-only value that has to sit *inside* a row of buttons — the tuning lift's car
nameplate between its `<` / `>` chevrons, and the stats row under it — wears
`UITheme.readout_box()` rather than a hand-built panel. It returns the theme's own
**Button "normal"** stylebox, so the readout cannot drift from the buttons beside it.
Rebuilding one from `panel_box()` is NOT equivalent: a panel is fully padded (14px all
round) and may be translucent to float over the 3D world, while a button is pure black
with tight 4px vertical margins — so a hand-built readout came out visibly **taller** than
its neighbours and a slightly different shade. Pair it with
`custom_minimum_size.y = UITheme.MENU_ROW_H` so the heights match too (house rule 3 pins
buttons to exactly that). See `hq_overlays.gd` → `build_lift_overlay` for the two-row
example.

## A page's actions go in ONE bottom row

Every menu page ends in a **single horizontal action row**, centred, separated by
`UITheme.GAP` and preceded by a gap spacer that lifts it off the body above. **`< Back`
leads** it — leaving is always the leftmost item — and the page's own actions follow. A
page that stacked its actions as full-width bars *inside* its body read as a different
kind of screen, so that shape is gone.

The consequence for a reusable component: it **builds** its action buttons but does not
parent them, and exposes them for the host to place. `TuningPanel`
(`scripts/tuning_panel.gd` → `action_buttons()`) does exactly this with **Reset to
neutral** and **Wheels**; its hosts —`hq_overlays.gd` → `build_lift_overlay` (into
`_lift_page_actions`) and `start_line.gd` → `_build_menu_overlay` (which picks them up
generically via `component.has_method("action_buttons")`) — add them beside their own
Back. A host MUST add them to a container, or they are never shown and never freed.
`< Back` on these pages is a compact `UITheme.row_button` with `focus_mode = FOCUS_ALL`,
since sub-pages navigate by native focus (`MenuNav`).

## Sizing a scrolled body (`UITheme.fit_body_scroll`)

Modals put their autowrapped body `Label` inside a `TouchScrollContainer` so a long
message can never push the action buttons off screen (`ConfirmPopup`,
`UsernamePopup` — see `features/menus.md` → "Body scrolls, buttons stay pinned").
But a `ScrollContainer` deliberately reports **no minimum size on the axis it may
scroll**, so inside a `CenterContainer`/`PanelContainer` (both of which size to
their natural minimum) an untouched scroll collapses to ~0 tall. Its height must
therefore be set explicitly, and `UITheme.fit_body_scroll(scroll, body, wrap_width)`
is the one place that does it:

- **Show everything.** The scroll is given the body's true wrapped height, so a
  normal message never scrolls at all — these popups are fullscreen and their
  bodies are short. The viewport cap (`BODY_SCROLL_MARGIN`) is a *fallback* for a
  pathological string: it stays scrollable rather than clipped, and the panel
  never grows past the screen.
- **Two measurements.** Before the first layout pass the Label has no width, so the
  height is *estimated* from the font at the known wrap width; once the Label has a
  real width its `resized` signal re-fits from the Label's own exact content height.
  That second pass also covers the body TEXT being swapped later
  (`ConfirmPopup.set_body` / `open_committing`), which the one-shot measurement
  never did.
- **Don't measure with `Font.get_multiline_string_size` alone.** It returns
  lines x font-height and knows nothing about a Label's `line_spacing` theme
  constant, so it comes out `(lines - 1) * line_spacing` **short** — that was a real
  bug: multi-line popup bodies hid their last line behind a scrollbar on a
  fullscreen popup with room to spare. `_body_content_height` adds the spacing back.

Covered by `tests/headless/test_confirm_popup.gd` (body fully visible, replaced body
re-fits, long body stays scrollable).

## Theme generator

`tools/build_ui_theme.gd` builds the project-wide theme (`theme/ui_theme.tres`)
entirely from the constants in `scripts/ui_theme.gd` (`UITheme`), so the design
system has ONE source of truth: tune the palette / type scale there, re-run this,
and the whole game restyles. It writes styleboxes and colours for Label, Button,
PanelContainer / Panel / PopupPanel, HSlider, and ProgressBar. The `.tres` is
wired as the project default theme via `project.godot` `gui/theme/custom`, so
every Control inherits the font, styleboxes, text colour and drop shadow — which is
why opting OUT of the shadow takes a per-node override, not a property on the label
(see "Gauge captions"). Run it headless:

```
godot --headless --script tools/build_ui_theme.gd
```

## Fonts & licensing

`fonts/SyneMono.ttf` is the UI face — a hand-drawn monospace bundled under the SIL
Open Font License (`fonts/SyneMono-OFL.txt`). To try a different face, drop a TTF
in `fonts/`, point `UITheme.FONT_PATH` at it, and re-run the theme generator.


## Gauge captions — the one drop-shadow exception

The two in-run HUD bars (`HPBar` / `BoostBar`, see [hud.md](hud.md)) put their caption
**inside** the bar, sitting directly on the coloured fill. There the house drop shadow
works against legibility rather than for it: at caption size a hard black edge thickens
the glyphs and muddies them against a saturated fill instead of separating them from it.
So these two labels — and only these two — draw **plain ink with no shadow**
(`hud.gd::_style_gauge_captions`).

Two things to know if you add another caption-on-fill widget:

- The shadow is **not** a per-label property you can leave unset. It comes from the
  project-wide theme (`theme/ui_theme.tres` → `Label/colors/font_shadow_color`), so a
  label inherits it by default and overriding `font_color` alone does nothing to it. It
  has to be overridden to transparent:
  `add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))`.
- Tint the **bar**, not the pair. Both bars colour themselves with `self_modulate`
  rather than `modulate`, because `modulate` propagates to children and would drag the
  caption's colour along with the fill (turning the HEALTH caption red as health drops).

Guarded by `test_hud.gd::test_gauge_captions_have_no_drop_shadow` and
`test_health_grading_does_not_tint_the_caption`, so neither decision can silently
regress.