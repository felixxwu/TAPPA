# UI design system

**Sources:** `scripts/ui_theme.gd` (`UITheme`), `theme/ui_theme.tres` (generated),
`tools/build_ui_theme.gd` (generator), `fonts/` (Jersey 10), and the
project default-theme wiring in `project.godot` (`[gui] theme/custom`).

**Tests:** `tests/headless/test_ui_theme.gd`, `tests/headless/test_ui_theme_fmt.gd`

One place that defines how every menu, panel and button looks, so the UI reads as
one polished, consistent whole instead of a pile of one-off `Color(...)` literals
and ad-hoc font sizes. The look is lifted from the previous **web build** of this
game: a retro arcade / terminal aesthetic.

## The look

- **Pixel-grid monospace font** (Jersey 10) — stat read-outs and money columns
  line up, and the face is drawn to a pixel grid so it stays sharp/unaliased on
  the game's low-res render target instead of blurring like a smooth-scaling
  face would (see "Fonts & licensing" below for why this replaced Syne Mono).
- **Pure-black, sharp-cornered panels** — no rounded corners, no gradients, no
  blur.
- **Crisp white text with a hard drop shadow** (the chunky terminal look). One
  documented exception — see "Gauge captions" below.
- A **tight accent palette**: **green** = active / selected / positive,
  **gold** = money / reward, **red** = danger / run timer / warning.

## House rules (enforced)

These are hard rules, not suggestions — `UITheme.enforce(root)` applies 1–3 and 5 to
every `Label`/`Button`/`Panel`/`PanelContainer` under a menu root, and the global theme
bakes in 2–4 as the defaults:

1. **All menu text is UPPERCASE** (`UITheme.caps`).
2. **One fixed font size everywhere** (`UITheme.FONT_SIZE`, deliberately small) —
   no per-screen size hierarchy; body and buttons all match. **One documented
   exception, TITLES:** a screen title (`UITheme.title()`) and a card's own name
   (`UITheme.card_title()`, `CardCarousel`'s card.info first line) render at
   `UITheme.TITLE_FONT_SIZE` (2x `FONT_SIZE`) instead — a heading reads better
   larger, and an exact multiple of `FONT_SIZE` stays on Jersey 10's pixel grid
   the same way `FONT_SIZE` itself does (see "Fonts & licensing" below). Both
   helpers mark their label (`ui_title_size` meta) so `enforce()`'s size reset
   skips it — `enforce()` still uppercases it (rule 1 still applies). A label
   that wants the bigger size MUST go through one of these two helpers, never a
   bare `add_theme_font_size_override` (the one exception is the loading screen's
   headline below, which sits outside the enforced-menu system entirely — see why
   there). Elsewhere, a bare override leaves no marker, so the next
   `enforce()` pass (a view change, a focus refresh) silently resets it back to
   `FONT_SIZE`.
3. **Single-line menu buttons are a fixed, compact height** (`UITheme.MENU_ROW_H`).
   Multi-line rows (e.g. the settings option rows, which embed their own layout)
   are left to size themselves.
4. **Menu backgrounds are pure black** — buttons and panels alike. **One documented
   exception, the ACCENT READOUT:** a floating 3D readout that must jump out of a map of
   otherwise-identical black panels is inverted (light-brown face, black ink — the same
   board stock as the pacenote signs, [signs.md](signs.md)). Every surface that took it was
   on the deleted HQ map table, so nothing renders one today; the rule is kept because it
   is the one sanctioned way to break the black, and the next 3D readout should take this
   treatment rather than inventing a colour. The podium's `SPECIAL_UNLOCK` card used to
   keep its own **white**
   face on the argument that a full-screen celebration should sit at maximum contrast. It
   no longer does: at panel size white was the only such surface in the game, so instead
   of reading as the loudest of our own cards it read as another app's dialog dropped into
   the frame. It now wears the ordinary `UITheme.reward_card_box`, like every other reveal
   on that screen, and paints no ink of its own back on over the house rules. The lesson
   generalises — the inversion earns its keep on a SMALL marker that has to win against
   map paper, and stops paying at panel size. Any further exception should be argued
   and listed here, not added quietly; the rule is what makes the look coherent.

5. **Every themed Button/Panel casts UITheme's hard down-right shadow** — see
   "Card drop shadow" below. Applied by `enforce()` at runtime rather than baked into
   the saved theme; a widget that already carries its own stylebox override (a
   selected/focused row, a carousel card, `UITheme.panel()`) already wraps itself and
   is left alone.

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

## The card carousel

Five hub pages (MAIN/REGION/CAR/SHOP/SKILLS) present their choices as a
[`CardCarousel`](card-carousel.md) rather than a vertical row list — a horizontal,
side-scrolling strip of playing-card-proportioned panels, the centred card opaque and the
rest dimmed. It reuses the same house panel box (`UITheme.panel_box`) and label styling
as every other menu — it's a different LAYOUT, not a different visual language — so rules
1-4 above still apply unchanged inside a card. All of its own tunables (card size/aspect,
dim alpha, snap timing) live on `GameConfig`, not here, since they're gameplay-feel
tuning rather than the shared design-system palette.

### Card drop shadow

Every carousel card, and (since house rule 5) every themed Button/Panel/PanelContainer in
the game, casts a hard, zero-blur black shadow offset down-right — the CSS equivalent of
`box-shadow: 5px 5px 0 rgba(0,0,0,0.2)`. `UITheme.card_shadow_box()` (flat black, 20%
alpha, sharp corners) and `UITheme.card_shadow_offset()` (`CARD_SHADOW_AUTHORED = 5`
authored px, scaled by `UITheme.px`) hold the fill/offset; `UITheme.CARD_SHADOW_COLOR` is
the shared colour constant.

Two different mechanisms draw the SAME look, for two different reasons:

- **`CardCarousel`** draws it as a separate quad (`card.shadow`, a sibling `Panel`) — see
  [card-carousel.md](card-carousel.md) → *Cards cast a sharp drop shadow* for why (its
  cards are absolute-positioned outside normal layout, and `card.root` clips its own
  contents), and → *A shared CanvasGroup, not independent alpha* for why root and shadow
  are grouped under one `CanvasGroup` rather than dimmed independently.
- **Everything else** gets the shadow baked into a single StyleBox via
  `UIHardShadowBox`/`UITheme.shadowed(box)` (`scripts/ui_hard_shadow_box.gd`) — a StyleBox
  WRAPPER that draws the shadow rect then delegates to the wrapped box's own `draw()`, all
  in one draw call. `UITheme.panel()`, `mark_selected`, `mark_focused`,
  `mark_panel_focused`, `reward_card_box()` and `menu_page.gd`'s body panel all call
  `shadowed()` on their own hand-built stylebox; `UITheme.enforce()` applies the same
  wrapper to any Button/Panel/PanelContainer still on the theme's plain default look (see
  house rule 5 above).

**An INVISIBLE box casts no shadow.** `UIHardShadowBox._draw` skips the shadow rect
entirely when the wrapped box paints no fill — a `StyleBoxEmpty`, or a `StyleBoxFlat` whose
`bg_color.a` is 0 (`_inner_casts_shadow`). The shadow is normally mostly *hidden under* the
widget's own opaque face, with only the down-right sliver poking out; with a transparent
fill there is nothing to hide it, so the whole offset rect shows at its full 20% black and
reads as a large dark translucent panel the size of the widget. That was the carousel-page
bug: `menu_page.gd` wraps its body box in `shadowed()`, and a carousel page's body is
deliberately `panel_box(0.0)` (see [card-carousel.md](card-carousel.md) → *The gaps show
the live 3D showcase*), so the "transparent" body painted a dark grey box around the whole
carousel. Buttons, cards and opaque panels have a real fill and still cast as before. If
you add a new surface that must stay invisible, it gets this for free — don't reach for a
per-call-site opt-out.

Neither form uses `StyleBoxFlat`'s own `shadow_*` properties: that shadow rect is the box
expanded by `shadow_size` on ALL sides before the offset, so `shadow_size = 0` draws
nothing at all, and any size > 0 leaks the shadow out of the top-left edge too — a purely
diagonal, zero-blur offset is unreachable through it.

**`UIHardShadowBox` must never be baked into the SAVED global theme
(`theme/ui_theme.tres`).** That resource loads during early project boot, before
autoloads are guaranteed to exist — embedding a custom-script StyleBox in it once made
that early load corrupt identifier resolution for OTHER scripts that reference an
autoload (`world_panel.gd`'s `DisplayStretch.DESIGN_HEIGHT` failed to resolve, crashing
the engine with a SIGSEGV on every test run). `tools/build_ui_theme.gd` therefore keeps
`_btn_box`/`_build_panels` UNWRAPPED — `UITheme.enforce()` applies the shadow at runtime
instead, which is safe because it always runs well after boot. If you're tempted to bake
a `shadowed()` box into the theme generator again, don't — this is why.

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
one line. The old (deleted) challenge entry screen is the case that actually broke: it
pinned a 480×210 body in raw logical pixels and went cramped the moment `UI_SCALE` stopped
being 1. Both numbers were AUTHORED sizes and both belonged multiplied by `UI_SCALE`. The
guard that pinned it lived in the deleted `test_menu_flow.gd` — so **this trap
is currently unguarded**; any new page that pins a pixel size owes its own version of that
assertion (assert the RELATION — the string still fits on one line — never either number).

**A heading that must not wrap is a WIDTH problem, not a text-flow one.** The
tempting fixes are both wrong: `AUTOWRAP_OFF` alone makes the Label's minimum width
its entire string, which propagates up and widens the box past whatever
`set_body_width` pinned (so the panel now resizes under content that changes length),
and `clip_text` keeps the box still by throwing characters away. If a heading is
wrapping, the honest answer is usually that something else in its row is eating the
column. On the old challenge screen the kind tabs sat *beside* the title, so the header
demanded title-width **plus** tab-row-width and the titles got what was left; moving the
tabs to their own row dropped the demand to the longer of the two and every string fitted
in full, unwrapped and unclipped, at one line of extra height. Its two guards (the strings
stay on one line; the box does not resize as they change) needed to be a PAIR — either one
alone can be passed by a bad answer. Both went with the screen.

Diegetic (in-world) UI scales its MEDIUM by the same factor, never its apparent
size — the world already got the resolution increase, so content scaled twice
would read bigger in-world. `WorldPanel.logical_size()` grows by `UI_SCALE`
(cancelling the widgets' inflation exactly; `SUPERSAMPLE` was turned 4 → 3 to
keep the per-panel pixel bill flat). The deleted map-table pin readouts did the same by
scaling their label pixel size and font size by `UI_SCALE` while dividing their
`pixel_size` by it, so the box kept its exact world-metre size and only gained texture
resolution — the pattern for any future in-world readout. Truly canvas-independent art
stays authored.

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

- **The hub** (`hub_shell.gd`) — every page is a `MenuPage` of house buttons; a row the
  player cannot take (a locked region, an unaffordable purchase, a period already run) is
  `disabled` and carries `menu_nav_skip`, never a differently-coloured live row.
- **Settings** (`settings_menu.gd`) — selected camera/scheme rows use
  `UITheme.mark_selected` (green underline) instead of the old blue tint.
- **Pause** (`pause_menu.gd`) — `PAUSED` on a black title plate (button wording
  unchanged).
- **HUD** (`hud.gd`) — the run timer is white (neutral ink), the stage-complete banner green.
- **Loading screen** (`loading_screen.gd`) — `_title`/`_dots` (the "LOADING STAGE 2 OF 8…"
  headline, the one thing on the screen) render at `UITheme.TITLE_FONT_SIZE` directly, not
  through `UITheme.title()`: the screen never calls `UITheme.enforce()` (it isn't a menu —
  it has no buttons and its text isn't player-authored-length, so there's nothing rule 1/3
  need to guard), so there's no size-reset to dodge and no need for the `ui_title_size`
  marker. The tip line underneath (`_step`) stays at `UITheme.FONT_SIZE`.

## A passive readout in a row of buttons (`UITheme.readout_box`)

A read-only value that has to sit *inside* a row of buttons — the deleted tuning lift's car
nameplate between its `<` / `>` chevrons was the original case — wears
`UITheme.readout_box()` rather than a hand-built panel. It returns the theme's own
**Button "normal"** stylebox, so the readout cannot drift from the buttons beside it.
Rebuilding one from `panel_box()` is NOT equivalent: a panel is fully padded (14px all
round) and may be translucent to float over the 3D world, while a button is pure black
with tight 4px vertical margins — so a hand-built readout came out visibly **taller** than
its neighbours and a slightly different shade. Pair it with
`custom_minimum_size.y = UITheme.MENU_ROW_H` so the heights match too (house rule 3 pins
buttons to exactly that).

## A page's actions go in ONE bottom row

Every menu page ends in a **single horizontal action row**, centred, separated by
`UITheme.GAP` and preceded by a gap spacer that lifts it off the body above. **`< Back`
leads** it — leaving is always the leftmost item — and the page's own actions follow. A
page that stacked its actions as full-width bars *inside* its body read as a different
kind of screen, so that shape is gone.

The consequence for a reusable component: it **builds** its action buttons but does not
parent them, and exposes them for the host to place. `TuningPanel`
(`scripts/tuning_panel.gd` → `action_buttons()`) does exactly this with **Reset to
neutral** and **Wheels**; its host — `start_line.gd` → `_build_menu_overlay`, which picks
them up generically via `component.has_method("action_buttons")` — adds them beside its own
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

`fonts/Jersey10.ttf` is the UI face — a pixel-grid monospace bundled under the SIL
Open Font License (`fonts/Jersey10-OFL.txt`). It replaced the previous face,
Syne Mono (still in `fonts/` for reference, unused): Syne Mono is a hand-drawn
face designed for smooth up-scaling, and at the game's low native resolution
its curves rasterised inconsistently and read as blurry once anti-aliased.
Jersey 10 is designed to be read unscaled at low pixel densities, so it stays
crisp instead.

**Crisp rendering is two things, not one — the face alone isn't enough.**
`fonts/Jersey10.ttf.import` also disables antialiasing (`antialiasing=0`),
hinting (`hinting=0`) and subpixel positioning (`subpixel_positioning=0`), and
pins `oversampling=1.0`. Antialiasing/subpixel positioning are the actual
source of blur: with them on (the Godot default), glyph edges are
greyscale-blended and glyph origins sit at fractional pixel offsets, which
smooths a smooth-scaling face but muddies a pixel face's hard edges and breaks
its pixel-grid alignment. Any future font swap should carry the same
`.import` overrides, not just point `FONT_PATH` at a new TTF — a pixel font
imported with default settings will still look blurry.

To try a different face: drop a TTF in `fonts/`, point `UITheme.FONT_PATH` at
it, copy the same `.import` overrides onto its `.import` file (Godot generates
one with defaults on first import — force a reimport after editing it by
deleting the corresponding file under `.godot/imported/` and re-opening the
project), then re-run the theme generator.

### The rendered size matters, not just the face

Jersey 10 ships no hinted bitmap strikes, so its outline-to-pixel rounding
only lands clean at certain point sizes — off those sizes, stroke widths that
should read as the same thickness come out 1px apart and glyphs look
uneven/disfigured even with antialiasing correctly off. `tools/render_font_sizes.py`
sweeps a size range with the same hard-threshold rendering the game actually
uses, so the sizes can be eyeballed side by side rather than guessed; **18px**
was picked this way. `UITheme.FONT_SIZE`'s authored constant is chosen so
`authored * UI_SCALE` lands exactly on 18 at the CURRENT `UI_SCALE` — if
`UI_SCALE` is ever retuned (e.g. `render_height` changes), re-run the sweep
and re-pick both the authored constant and the target size, rather than
letting the scale silently drift the rendered size off the sweet spot. This
same caveat would apply to any future pixel-font swap: check its size sweep
before assuming a "sharp" import alone is enough.


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
## Card icons

Every card's visual slot (`CardCarousel` cards — `features/card-carousel.md`) draws one
SVG from `icons/cards/`, named by what the card is: a boost/skill's catalogue id
(`grip.svg`, `coin_magnet.svg`, …) or a fixed name (`car`, `region`, `region_locked`,
`engine_swap`, `shop`, `skills`, `stats`, `settings`, `new_run`, `resume_run`,
`rally_challenge`, `generic`).

**Style rules — keep every new icon inside them:**

- **White only.** No other colour, no gradients; `stroke="#FFFFFF"`.
- **Uniform line weight:** `stroke-width="6"` on a `0 0 96 96` viewBox, everywhere.
- **`stroke-linecap="round"` and `stroke-linejoin="round"`** — never butt/mitre.
- **Outline, not fill** (`fill="none"`); the one exception is a solid-white accent cell
  (the checkered flag's squares, a gauge's hub dot).

`hub_shell.gd::_card_icon` falls back to `generic.svg` for an id with no authored icon
(a test fixture's `fx_*` id); a SHIPPED catalogue entry missing its icon is caught by
`test_hub_shell.gd -> test_every_catalogued_boost_and_skill_has_a_card_icon`.
