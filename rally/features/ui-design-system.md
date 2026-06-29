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
  line up while the lettering keeps a characterful, slightly informal feel. Text
  is shown **verbatim** (the helpers never force casing); `UITheme.caps()` is
  available if a specific string wants the all-caps arcade look.
- **Pure-black, sharp-cornered panels** — no rounded corners, no gradients, no
  blur. Over the 3D world they sit ~90% opaque so text reads cleanly.
- **Crisp white text with a hard drop shadow** (the chunky terminal look).
- A **tight accent palette**: **green** = active / selected / positive,
  **gold** = money / reward, **red** = danger / run timer / warning.

## How it's applied (two layers)

1. **Global theme** — `tools/build_ui_theme.gd` reads the constants in `UITheme`
   and writes `theme/ui_theme.tres`, which is wired as the project-wide default
   theme (`project.godot` → `[gui] theme/custom`). **Every `Control` inherits the
   font, the button/panel styleboxes, the text colour and the drop shadow
   automatically** — this is what makes the whole game consistent without touching
   each widget. Scripts that still call `add_theme_font_size_override(...)` only
   change the *size*; the face, colour and shadow come from the theme.
2. **`UITheme` helpers** — the bits a flat theme can't express on its own:
   role-coloured labels (`UITheme.money`, `UITheme.label(text, size, "green")`),
   solid black panel boxes (`UITheme.panel` / `panel_box`), and the selection
   treatment from the web build — a green underline + green text
   (`UITheme.mark_selected`) and the **▶ ◀** markers around the focused option
   (`UITheme.flank`).

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
- **HUD** (`hud.gd`) — the run timer is red, the stage-complete banner green.

## Visual proof sheet

`tools/ui_preview.tscn` builds a representative screen (title, stat panel, money,
a selected menu option, a locked bar) and captures `tools/ui_preview.png`:

```
xvfb-run -a -s "-screen 0 1280x720x24" godot --path rally \
    --rendering-driver opengl3 res://tools/ui_preview.tscn
```

## Fonts & licensing

`fonts/SyneMono.ttf` is the UI face — a hand-drawn monospace bundled under the SIL
Open Font License (`fonts/SyneMono-OFL.txt`). To try a different face, drop a TTF
in `fonts/`, point `UITheme.FONT_PATH` at it, and re-run the theme generator.
