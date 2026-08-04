# Splitting hq.gd

`scripts/hq.gd` is **~4850 lines**, the largest file in the repo. Split it into cluster
helpers following the pattern `HqOverlays` / `HQEnvironment` already establish: a
`RefCounted` holding an `_hq: HqController` back-reference, reaching into it for state, node
parenting and widget helpers.

Status: **all three cuts are DONE.** `hq.gd` went **4831 → 3258 lines** (−1573, −33%), with
`scripts/hq_challenge.gd` (496), `scripts/hq_table.gd` (477) and `scripts/hq_carpark.gd` (679)
alongside. The only item left is the **`_unhandled_input` follow-up** at the bottom of this file.

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

Once all three land, `hq.gd`'s `_unhandled_input` (~122 lines of `_view` dispatch) should hand
each cluster its own input branch (`_carpark_ui.handle_input(event)`) rather than keeping every
view's input logic centralised.

## Why this is worth doing carefully rather than quickly

A ~480-line move with per-identifier prefixing is exactly the shape of edit that produces a
half-moved file that still parses. Do step 3 with the whole cluster in context at once, and
run the full suite between steps 3 and 4 — not just at the end.
