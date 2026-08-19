# UI design system

**Sources:** `scripts/ui_theme.gd` (`UITheme`), `theme/ui_theme.tres` (generated),
`tools/build_ui_theme.gd` (generator), `fonts/` (Syne Mono), and the
project default-theme wiring in `project.godot` (`[gui] theme/custom`).

**Tests:** `tests/headless/test_ui_theme.gd`, `tests/headless/test_ui_theme_fmt.gd`

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
   exception, the ACCENT READOUT:** a floating 3D readout that must jump out of a map of
   otherwise-identical black panels is inverted (light-brown face, black ink — the same
   board stock as the pacenote signs, [signs.md](signs.md)) — see `hq.gd`'s
   `ACCENT_READOUT_BG` / `_build_readout_sprite`'s `accent` flag and [menus.md](menus.md).
   Three surfaces take it, all on the HQ map table or the podium: a **SPECIAL event's**
   pin readout (`hq._build_pin_label` via `RallyLibrary.is_special`), a locked special's
   teaser (`hq._build_special_teaser_label`), and the **present box** that trades stars
   for a car (`hq._make_present_pin` — the one non-rally target on the map, so it should
   not read as another rally pin). The podium's `SPECIAL_UNLOCK` card
   (`podium.gd` → `_show_special_unlock`) used to be a fourth, keeping its own **white**
   face on the argument that a full-screen celebration should sit at maximum contrast. It
   no longer does: at panel size white was the only such surface in the game, so instead
   of reading as the loudest of our own cards it read as another app's dialog dropped into
   the frame. It now wears the ordinary `UITheme.reward_card_box`, like every other reveal
   on that screen, and paints no ink of its own back on over the house rules. The lesson
   generalises — the inversion earns its keep on a SMALL marker that has to win against
   map paper, and stops paying at panel size. Any further exception should be argued
   and listed here, not added quietly; the rule is what makes the look coherent.

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

## UI scale (`UITheme.UI_SCALE` / `UITheme.px`)

The UI was authored against the original 400-tall logical canvas; the shipped
render height is now larger (`GameConfig.render_height`, applied by
`DisplayStretch` — see [rendering.md](rendering.md)). `UITheme.UI_SCALE`
re-inflates the AUTHORED sizes so the UI keeps its apparent size: the design
constants (`FONT_SIZE`, `MENU_ROW_H`, `BUTTON_MIN_W`, paddings/gaps) are defined
as `authored × UI_SCALE`, and every literal font/UI pixel size in a script goes
through `UITheme.px(authored)`. Fonts therefore get a genuinely larger point
size — the TTF re-rasterises crisp at the new logical resolution — never a
scaled-up small glyph. Keep `UI_SCALE` equal to `render_height / 400` when the
render height is retuned, then re-run `tools/build_ui_theme.gd` (its stylebox
margins go through `px` too).

**A box pinned in pixels must be scaled like the text inside it.** The trap is a
container sized by a literal — `MenuPage.set_body_width` / `set_body_fixed_height`,
a `custom_minimum_size`, a container `separation` — while the fonts within it go
through `px`. The text then gets its genuinely larger point size and its container
does not, so content clips into the body scroll and values wrap that used to fit on
one line. The challenge entry screen (`hq_overlays.gd` → `build_challenge_overlay`)
is the case that actually broke: it pinned a 480×210 body in raw logical pixels and
went cramped the moment `UI_SCALE` stopped being 1. Both numbers are AUTHORED sizes
and both belong multiplied by `UI_SCALE`, exactly like `hq_carpark.gd` already does
for its column. The guard is
`test_menu_flow.gd::test_hq_challenge_header_never_breaks_across_lines`, which asserts
the relation (the headline strings still fit on one line on every kind tab) rather than
either number, so it survives a retune of the box or the type scale.

**A heading that must not wrap is a WIDTH problem, not a text-flow one.** The
tempting fixes are both wrong: `AUTOWRAP_OFF` alone makes the Label's minimum width
its entire string, which propagates up and widens the box past whatever
`set_body_width` pinned (so the panel now resizes under content that changes length),
and `clip_text` keeps the box still by throwing characters away. If a heading is
wrapping, the honest answer is usually that something else in its row is eating the
column. On the challenge screen the kind tabs sat *beside* the title, so the header
demanded title-width **plus** tab-row-width and the titles got what was left; moving
the tabs to their own row dropped the demand to the longer of the two and every string
fits in full, unwrapped and unclipped, at one line of extra height. The guards are
`test_hq_challenge_header_never_breaks_across_lines` (the strings stay on one line) and
`test_hq_challenge_screen_keeps_one_size_across_the_kind_tabs` (the box does not resize
as they change) — the pair is what pins the fix, since either one alone can be passed
by a bad answer.

Diegetic (in-world) UI scales its MEDIUM by the same factor, never its apparent
size — the world already got the resolution increase, so content scaled twice
would read bigger in-world. `WorldPanel.logical_size()` grows by `UI_SCALE`
(cancelling the widgets' inflation exactly; `SUPERSAMPLE` was turned 4 → 3 to
keep the per-panel pixel bill flat), and `hq.gd`'s pin readouts scale
`PIN_LABEL_PX` + `PIN_LABEL_FONT_SIZE` by `UI_SCALE` while dividing
`PIN_LABEL_PIXEL_SIZE` by it, so the box keeps its exact world-metre size and
only gains texture resolution. Truly canvas-independent art (e.g.
`overworld_marker.gd`'s meter-sized star textures) stays authored.

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

The three in-run HUD gauges (`HPGauge` / `BoostGauge` / `NitrousGauge`, a `HudGauge`
radial ring each — see [hud.md](hud.md)) no longer use text captions at all: each
draws a `GaugeIcons` glyph (cross / dial / bottle) in flat ink, in the hole of the
ring, never on top of the coloured fill — sidestepping the legibility problem this
section used to describe for the old bars' captions-on-fill (a hard black drop
shadow thickening and muddying glyph edges against a saturated fill). The
`GaugeIcons` glyphs are drawn with no outline and no shadow by construction, not via
an override on a `Label`.

This section is kept for history and because the underlying trap is still real: if
you add another caption-on-fill widget, know that —

- The shadow is **not** a per-label property you can leave unset. It comes from the
  project-wide theme (`theme/ui_theme.tres` → `Label/colors/font_shadow_color`), so a
  label inherits it by default and overriding `font_color` alone does nothing to it. It
  has to be overridden to transparent:
  `add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))`.
- Tint the **bar**, not the pair. Both bars colour themselves with `self_modulate`
  rather than `modulate`, because `modulate` propagates to children and would drag the
  caption's colour along with the fill (turning the HEALTH caption red as health drops).

There is no longer a caption-on-fill widget to guard, so the drop-shadow half of this
is documentation only. The tint half is still live and still guarded, by
`test_hud.gd::test_health_grading_recolours_the_fill_only` — the health grade must move
the fill without dragging the icon's ink with it.