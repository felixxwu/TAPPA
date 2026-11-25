# Character dialogue

`NpcDialogue` (`scripts/npc_dialogue.gd`) is a character talking to the player: a portrait leaning out over a black box at
the bottom of the screen, each page typing out letter by letter (`GameConfig.npc_text_chars_per_s`). Confirm / Back / a
click or tap shows the rest of the page, then turns it; after the last page it frees itself and emits `finished`. It sits on
CanvasLayer 100 with `PROCESS_MODE_ALWAYS` and swallows every input in `_input` while open, so a menu or the paused game under
it waits (keyboard, gamepad, mouse and touch all work). `NpcDialogue.open(parent, portrait_path, pages)`.

## The lines

Every line the characters say lives in `scripts/npc_lines.gd` (`NpcLines`): one const list per conversation, one string per
page. A `%d` in a page is filled with a number from the game by `NpcLines.fill` (the comment beside it says which).

## Portraits

`tools/render_npc.sh <name> <seed> [pose]` renders one limbless spectator from `tools/spectators.js` (the same figures the game's
crowds use) head and shoulders on a transparent background via headless Chrome (`tools/npc_portrait.html`), and writes
`textures/npc/<name>.webp` (lossy with alpha, via `cwebp`). Render characters as they're needed.

| Character | Seed | Used |
|---|---|---|
| `tutorial` | 7578 | `LevelView.TUTOR` |
| `dispatcher` | 9042 | `LevelView.DISPATCHER` |
| `recipient` | 20288 | `LevelView.RECIPIENT` |

## The new player's welcome (Hafren level)

- No car (a new game): `LevelView._start_without_car` opens him while the camera circles the start shop, and the shop menu only once he is done: your money and what to spend it on.
- The first car bought sets `LevelView._tutor_on_drive`; after the reload onto the road `_ready` pauses the game and he says
  a delivery is waiting nearby. Driving resumes on dismissal, with the sat nav already leading to the pick-up point.
- Stopping there, once the Enter prompt shows (`_check_delivery` waits for `service_at()` while `_greet_at_pickup` is set), the dispatcher says how many deliveries the point has on
  offer (`_offered_at`) and that they pay on completion, and sets `_greet_at_drop`.
- The first real delivery completed: its recipient thanks the player and says how many jobs their own point has. No more
  delivery tutorial after that. The road talks go through `LevelView._talk`, which pauses the game.
- The flags are static vars, not saved: quitting mid-tutorial skips the rest of it.

Tests: `tests/headless/test_npc_dialogue.gd`.
