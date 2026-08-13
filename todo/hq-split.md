# Splitting hq.gd

`scripts/hq.gd` was the largest file in the repo. Split it into cluster
helpers following the pattern `HqOverlays` / `HQEnvironment` already establish: a
`RefCounted` holding an `_hq: HqController` back-reference, reaching into it for state, node
parenting and widget helpers.

Status: **all three cuts are DONE.** `hq.gd` delegates to `HqChallenge`
(`scripts/hq_challenge.gd`), `HqTable` (`scripts/hq_table.gd`) and `HqCarpark`
(`scripts/hq_carpark.gd`), which now sit alongside it. The cut removed roughly a
third of the file at the time it landed; `hq.gd` has since grown again as
unrelated feature work landed on top, so run `wc -l scripts/hq*.gd` for current
sizes rather than trusting a number written here — the earlier snapshot counts in
this spec had all rotted by ~10-30% within weeks.

**The two follow-ups are also DONE** — see "Making the split a real boundary" at the
bottom of this file. Nothing in this spec is outstanding; it is kept as the record of how
the cuts were done and which failure categories to expect from the next one.

## Which cluster to cut first, and why

Measured test coupling — the numbers that actually decide the order:

| Cluster | Test refs | **Test files** |
|---|---|---|
| **challenge** | 108 | **1** (`test_menu_flow.gd`) |
| table / map | 130 | 3 |
| carpark | 139 | 4 |

The counts are close, so they don't discriminate. **File containment does**: every challenge
reference lives in one test file, versus 3 and 4. For a mechanical ~60-site rename, one file
is a sweep you can verify in a single run; four files is where a partial edit hides. So
**challenge first**, and it sets the pattern the other two follow.

## The key design decision: move the FUNCTIONS, leave the STATE

Counting the references by kind is what makes this tractable:

| Referrer | State refs | Function refs |
|---|---|---|
| `test_menu_flow.gd` | 64 | 44 |
| `hq_overlays.gd` | ~24 | ~14 |
| `hq.gd` itself | — | ~6 |

Moving the 13 `_challenge_*` state vars into the new class would break **all ~88 state
references**. Moving only the functions breaks **~64 call sites** and leaves every state
reference untouched — and the state refs are the ones where a silent partial edit hides,
because they read as plain property access rather than a call.

It also costs almost nothing in size: the 18 functions are ~480 lines, the 13 var
declarations are ~13. So the functions are ~97% of the win and ~40% of the breakage.

`HqOverlays` already works exactly this way (it reads `_hq._challenge_start_button` and
friends), so this is the established pattern rather than a new one.

## What the four parse/runtime failures were (read this before the next cut)

The move itself was scripted; every failure came from a category the script did not know
about, and each is worth anticipating rather than rediscovering:

1. **A `const` declared INSIDE the moved block got prefixed at its own declaration**
   (`const _hq._CHALLENGE_REWARD_TEXT := {...}`). Consts/enums/vars whose declaration travels
   with the block belong to the new class — exclude them from prefixing.
2. **Inherited `Node` API stayed bare** — `add_child`, `get_tree`, `is_inside_tree`. A scan of
   `hq.gd`'s own `func`/`var`/`const` declarations cannot see them, because they come from
   `Node3D`. They need `_hq.` too. Grep the moved file for bare `(`-calls afterwards.
3. **An enum was missed** (`CarparkMode`) because a same-named token elsewhere put it in the
   locals/params exclusion set. Harmless — the parser catches it.
4. **Const references from OUTSIDE were not swept.** The call-site sweep covered the 18
   function names only, so `test_menu_flow.gd`'s `hq._CHALLENGE_WIN_CONDITION` broke at
   RUNTIME (not parse time) once the const moved. Sweep constants as well as functions; they
   now read `HqChallenge._CHALLENGE_WIN_CONDITION` (static, no instance needed).

**GDScript is a good safety net for 1–3** — an unknown bare identifier is a parse error, so
misses fail loudly. Category 4 is the dangerous one: property access on the wrong object
compiles fine and only fails when the line runs. Check for it explicitly.

Also worth knowing: relocating a function block by line range leaves its **docstring** behind
if the range starts at the `func` line. That happened to `_build_carpark_nav_row` in step 1 and
had to be reunited by hand.

## Plan

1. **DONE — make the challenge block contiguous.** Three Android-app-notice functions
   (`_should_show_android_app_notice`, `_show_android_app_notice`,
   `_dismiss_android_app_notice`) and `_build_carpark_nav_row` sat *inside* the span; they are
   now relocated after it. Pure relocation, no reference changes, line count asserted
   unchanged. The challenge cluster is now `_challenge_info_row` (~1111) through
   `_begin_challenge_start` (~1594), banner included.
2. **DONE — created `scripts/hq_challenge.gd`** — `class_name HqChallenge extends RefCounted`,
   `var _hq: HqController`, `func _init(hq: HqController)`, mirroring `hq_overlays.gd`.
   Constructed in `hq.gd`'s `_build_hq` next to `_overlays`, held as `_challenge_ui`.
3. **DONE — moved the 18 functions** (keep their names verbatim — renaming multiplies risk for no
   gain) and prefix every `HqController` member they touch with `_hq.`. This is the only
   non-mechanical step: each moved body has to be read for bare references to hq state,
   methods and node vars. The 13 `_challenge_*` vars stay on `HqController`.
4. **DONE — rewrote the call sites** to `hq._challenge_ui.<name>` /
   `_hq._challenge_ui.<name>`: **15** in `hq.gd`, **11** in `hq_overlays.gd`, **49** plus **6**
   const references in `test_menu_flow.gd`. The member is named `_challenge_ui`, not
   `_challenge`, which would read oddly beside the `_challenge_*` state it sits next to.
5. **DONE — full suite**, and `features/menus.md` documents the new collaborator (sources list
   plus a section beside the `HQEnvironment` one). `features/architecture.md` needed nothing —
   it has no script inventory, and its `hq.gd::_challenge_refresh_generation` reference is still
   correct because that is state, which stayed on `HqController`.

## The 18 functions to move

`_challenge_info_row`, `_open_challenge_overlay`, `_close_challenge_overlay`,
`_select_challenge_kind`, `_fetch_challenge_placing`, `_apply_challenge_placing`,
`_set_challenge_win_text`, `_set_challenge_completed_text`, `_fetch_challenge_cutoff`,
`_apply_challenge_cutoff`, `_challenge_kind_button`, `_refresh_challenge_overlay`,
`_on_challenge_tab_activated`, `_on_challenge_start_pressed`, `_hand_off_to_challenge_scene`,
`_enter_challenge_car_screen`, `_build_challenge_lineup`, `_begin_challenge_start`.

## After challenge — the table cut is HARDER, and here is why

Measured before attempting it: **the table cluster is not contiguous the way challenge was.**
It sits in two regions with shared helpers interleaved:

- **pin building**, `hq.gd` ~659-959: `_refresh_map_pins`, `_make_pin`, `_add_pin_hit`,
  `_build_readout_sprite`, `_build_readout_box`, `_build_pin_label`,
  `_build_special_teaser_label`, `_special_unlock_line`
- **table nav / reveal / detail**, ~1652-2200: `_enter_table`, `_run_reveal_sequence`,
  `_reveal_active`, `_reveal_continue`, `_pin_position`, `_set_reveal_banner`,
  `_table_targets`, `_pan_table_step`, `_select_target_under_center`, `_on_rally_pin`,
  `_show_detail`, `_hide_detail`

**Helpers that must STAY on `HqController`** — they sit inside the pin region but are not
table-specific:

| Helper | Why it stays |
|---|---|
| `_detail_heading`, `_detail_wrap_label` | already used by `hq_challenge.gd` (3 and 6 refs) and `hq_overlays.gd`; they are shared widget builders, not table code |
| `_stars_for`, `_entry_plan`, `_has_eligible_car`, `_detuned_to_full`, `_meta_with_drive` | eligibility/progress helpers the CARPARK cut will also want; moving them into the table class would just relocate the entanglement |

So the table cut is **two moves plus a shared-helper boundary decision**, not one contiguous
sweep. Recommended order: do the **nav/reveal/detail region first** (it is the contiguous half
and needs none of the shared helpers), verify, then decide separately whether the pin-building
half belongs with it or wants its own `HqPins` collaborator.

**Three things sit INSIDE the nav/reveal/detail region that cannot move** — found by mapping
it, and all three would fail in ways the parser will not catch:

1. **`_process(delta)` at ~1931 is an engine callback.** Moving it to a `RefCounted` means
   Godot never calls it, so the table pan and the reveal animation would silently stop
   advancing — and several tests drive `hq._process(delta)` directly. It must stay on
   `HqController`; the moved code reaches back for whatever per-frame state it needs.
   This is the one that would have looked green and been broken.
2. **`_eligibility_summary` (~2134) and `_qualifying_cars_text` (~2157) are already shared** —
   `hq_challenge.gd` calls both. They stay on `HqController` like `_detail_heading`.
3. **`_enter_table` (~1652) sits before the region's banner**, so a banner-to-banner range
   misses it.

**Resolved by a prep pass, exactly like step 1 for challenge:** the three non-movable
functions were RELOCATED below `_hide_detail` under an explanatory banner
(`# --- Kept on HqController, NOT moved with the table cut ---`), which turned the region into
one contiguous slice `_enter_table` → `_hide_detail` (25 functions, 460 lines). Pure
relocation, verified before the extraction. **Do this prep step first every time** — it turns a
surgical extraction into a mechanical one, and it is independently verifiable.

The second region is ~550 lines and is the closest analogue to the challenge cut. Its test
coupling spans 3 files (vs challenge's 1), so sweep all three and re-read the
runtime-vs-parse-time warning above before trusting a green parse.

### Table cut, as executed

25 functions → `scripts/hq_table.gd` (`class_name HqTable`), held as `_table_ui`. Call sites:
**22** in `hq.gd`, **1** in `hq_overlays.gd`, **60** in `test_menu_flow.gd`, **4** in
`test_rally_detail.gd`. No consts moved with the block, so category 4 was limited to function
calls this time — but it still bit: `_hide_detail` failed at runtime because the external sweep
had not been run yet. **Sweep the other files in the same pass as `hq.gd`, not after.**

### Carpark cut, as executed

**35 functions / 661 lines → `scripts/hq_carpark.gd`** (`class_name HqCarpark`), held as
`_carpark_ui`: the eligible-lineup build, the parked-car prop cache and prewarm, focus
cycling, the swap/damage readouts and the carpark modals. Call sites: **32** in `hq.gd`, **3**
in `hq_challenge.gd`, **8** in `test_lineup_cache.gd`, **22** in `test_menu_flow.gd`, **4** in
`test_wheel_customization.gd`. The prep pass relocated **three intruders** out of the region
first: the boot-instrumentation block (`_log_boot_cost`, `_log_prewarm_cost`,
`_car_cache_mesh_cost` + the two `CAR_MESH_*` consts — called from `_ready`) and the two shared
tail helpers `_car_stats_text` and `_restriction_text` (the latter is called by
`hq_table.gd`). That left one contiguous slice, same as the table cut.

**Two NEW failure categories this cut surfaced** — add them to the list above, because neither
is caught by the parser and neither existed in the first two cuts:

5. **`self` passed where a `Node` is expected.** The moved bodies had
   `CarProp.spawn(self, …)` and `ConfirmPopup.open(self, …)`; both take a parent/host `Node`,
   and `self` is now a `RefCounted`. This **parses clean** and fails only when the line runs
   (`add_child` / `is_inside_tree` on a RefCounted). Grep the moved file for `\bself\b` — it is
   a two-second check and it is the highest-value one.
6. **Signals belong to the node.** `emit_signal("lineup_built")` moved verbatim; the signal is
   declared on `HqController`, so it had to become `_hq.emit_signal(...)`. Same shape as
   category 2 (inherited `Node` API), but easy to miss because it reads as a plain call rather
   than a node operation. Grep for `emit_signal` / `.connect(` / `is_connected`.

**A test double that SUBCLASSES `hq.gd` to override a moved function is a third trap.**
`tests/headless/hq_null_spawn_double.gd` did `extends "res://scripts/hq.gd"` purely to override
`_obtain_parked_car` — once that function moved, the override seam was dead and the test would
have silently stopped exercising the null-spawn path. Fixed by rebasing the double onto the new
collaborator: it is now `tests/headless/carpark_null_spawn_double.gd`
(`extends "res://scripts/hq_carpark.gd"`), installed over `hq._carpark_ui` instead of via
`set_script` on the HQ node. **Before any future cut, grep for
`extends "res://scripts/hq.gd"`** and check whether the double overrides anything in the slice.

## Making the split a real boundary — DONE

The three cuts left the split COSMETIC: 43 fields on `HqController` carried
`@warning_ignore("unused_private_class_variable")` purely because only a collaborator touched
them, and `_unhandled_input` still held every view's input logic. Both are now closed.

### 1. DONE — state follows its single user

The rule: a field moves to a collaborator when **exactly one** collaborator touches it and
`hq.gd` itself does not; it stays on `HqController` when two or more do. **19 of the 43** moved:

| Moved to | Fields |
|---|---|
| `HqTable` | `_reveal_queue`, `_reveal_shown`, `_reveal_token` |
| `HqCarpark` | `_upgrades_popup`, `_upgrades_popup_menu`, `_upgrades_popup_done`, `_upgrades_popup_dirty`, `_active_carpark_popup`, `_preview_audio`, `_settle_generation`, `_prewarm_marker` |
| `HqChallenge` | `_challenge_refresh_generation`, `_challenge_cutoff_cache`, `_challenge_placing_cache` |
| `HqOverlays` | `_title_free_roam_button`, `_title_settings_button`, `_title_exit_button`, `_title_version_label`, `_detail_dev_win_button` |

The **24 that stayed** did so for one of two reasons, both real:

- **Two collaborators genuinely share them.** `hq_overlays.gd` BUILDS most widgets that
  `hq_table.gd` / `hq_challenge.gd` then read, so every `_detail_*` label, every
  `_challenge_*_label` / `_challenge_kind_buttons` / `_challenge_start_button`,
  `_reveal_banner`, `_car_hint_label` and `_car_nav_row` has two owners. `_challenge_kind` has
  three (`hq.gd`, `hq_carpark.gd`, `hq_challenge.gd`).
- **A test file OUTSIDE the HQ set reads them off the controller.** `_prewarm_complete` and
  `_prewarm_running` are asserted by `tests/headless/test_lineup_cache.gd`; moving them would
  have meant editing a test whose subject is the lineup cache, not the split.

`hq.gd` also grew a small **public** API so the calls that reach for controller BEHAVIOUR stop
reading as private access: `view()` (the read-only half of `_view`), `go_to(view_id, snap)`,
`update_overlays()`, and the widget factories `label()`, `detail_heading()`,
`detail_wrap_label()`, `challenge_info_row()`. That converted **108** of the ~588 `_hq._private`
accesses. The remainder is deliberate: it is state, and the fields above are where the boundary
actually was — renaming the rest would be churn without one. Note `_go_to` / `_update_overlays`
are referenced by NAME in comments in `scripts/world_panel.gd` and
`scripts/world_panel_host.gd`; those two mentions are now spelled without the underscore in the
code but were left alone in those files.

**Two collisions the rename caused**, both parse errors so both loud: `label()` collided with
locals named `label` in `_make_pin` / `_build_readout_sprite` (renamed `pin_label` / `lbl`), and
`view()` collided with the `view` PARAMETER of `go_to` and `_station_xform` (renamed `view_id`).
Adding a method whose name a local already uses is the one hazard in this step.

### 2. DONE — per-view input dispatch

`_unhandled_input` keeps only what applies to every station in order (the
`MenuNav.is_text_editing()` bail, the debug F7/F8 keys, the `ConfirmPopup.any_open()` bail) and
then dispatches: `_challenge_ui.handle_input(event)` first (the challenge modal owns the screen,
so it answers `true` and every station stands down — this replaced hq.gd reading
`_challenge_shown` by hand), then `match _view` over `_exterior_input` / `_settings_input` /
`_garage_input` / `_lift_input` / `_table_ui.handle_input` / `_carpark_ui.handle_input`.

Each returns whether it CONSUMED the event. Nothing chains off the answer after the `match` —
`_unhandled_input` is the last stop — but the contract is what makes the challenge early-out
expressible. `_is_any_press` moved to `hq_table.gd` with the branch that was its only caller,
and `hq.gd::_cars_input` became `-> bool` so the carpark branch has a real answer to give.
The four stations with no collaborator of their own (title, settings, garage, lift) got private
`_*_input` methods on `HqController` rather than an invented collaborator.

**No keyboard/gamepad binding changed** — the refactor is branch-for-branch, and
`test_menu_nav.gd` / `test_menu_flow.gd` / `test_world_panel.gd` pass unchanged.

### 3. DONE — the two duplicated challenge coroutines

`hq_challenge.gd`'s `_fetch_challenge_placing` and `_fetch_challenge_cutoff` were the same
~30-line coroutine twice (arg guard → per-period cache hit → `Cloud`/signed-in guards →
"Loading…" → `await` → cache when ok → `is_inside_tree()` + generation staleness → apply),
differing only in cache, row-text setter, leaderboard method and renderer. Both are now
two-line wrappers over **`_fetch_decoration(cache, key, stage_count, generation, set_text,
fetch_method, apply)`**. The fetch is passed as a method NAME, not a `Callable`, because
`Cloud.challenge_leaderboard` may only be dereferenced after the null guard inside the helper.
Likewise `_set_challenge_win_text` / `_set_challenge_completed_text` are wrappers over
**`_set_row_text(label, prefix, tail)`**.

## Why this is worth doing carefully rather than quickly

A ~480-line move with per-identifier prefixing is exactly the shape of edit that produces a
half-moved file that still parses. Do step 3 with the whole cluster in context at once, and
run the full suite between steps 3 and 4 — not just at the end.
