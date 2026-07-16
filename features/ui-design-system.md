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
- **Crisp white text with a hard drop shadow** (the chunky terminal look).
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
4. **Menu backgrounds are pure black** — buttons and panels alike.

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

## Theme generator

`tools/build_ui_theme.gd` builds the project-wide theme (`theme/ui_theme.tres`)
entirely from the constants in `scripts/ui_theme.gd` (`UITheme`), so the design
system has ONE source of truth: tune the palette / type scale there, re-run this,
and the whole game restyles. It writes styleboxes and colours for Label, Button,
PanelContainer / Panel / PopupPanel, HSlider, and ProgressBar. The `.tres` is
wired as the project default theme via `project.godot` `gui/theme/custom`, so
every Control inherits the font, styleboxes, text colour and drop shadow. Run it
headless:

```
godot --headless --script tools/build_ui_theme.gd
```

## Fonts & licensing

`fonts/SyneMono.ttf` is the UI face — a hand-drawn monospace bundled under the SIL
Open Font License (`fonts/SyneMono-OFL.txt`). To try a different face, drop a TTF
in `fonts/`, point `UITheme.FONT_PATH` at it, and re-run the theme generator.
