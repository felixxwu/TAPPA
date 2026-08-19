# Settings — adding one, and where it lives

**Sources:** `scripts/settings_menu.gd` (`class_name SettingsMenu` — the shared settings
page used by BOTH the title screen and the pause menu), the per-setting apply-owner modules
(`scripts/fps_setting.gd`, `scripts/camera_manager.gd`, `scripts/music_director.gd` and
siblings — one module per persisted setting), and `Save.get_setting` / `Save.set_setting`
in `scripts/save_manager.gd`.

**Tests:** `tests/headless/test_settings_menu.gd`, `tests/headless/test_menu_nav.gd`, `tests/headless/test_camera_manager.gd`

How to add or change a **persisted setting**. This is its own area doc rather than a
subsection of the HQ screen because a setting is not an HQ concern: the same
`SettingsMenu` backs the title screen and the pause menu, and the thing that actually owns
a setting is its apply module, not any screen.

**Two things every new setting needs, both easy to miss:**

1. **It must be RE-APPLIED AT BOOT.** Writing `Save.set_setting` at toggle time only means
   the setting silently will not survive a restart. The apply-owner pattern below is what
   carries it; `camera_manager.gd`, `fps_setting.gd` and `music_director.gd` are the
   canonical examples to clone.
2. **Its row must be keyboard + gamepad navigable**, with a nav test — see
   [menu-navigation.md](menu-navigation.md). This is a CLAUDE.md rule for every menu change.

`Save.get_setting` / `set_setting` is a **generic settings dict**, so a new setting needs
**no `SCHEMA_VERSION` bump** — see [save-persistence.md](save-persistence.md).

## Every persisted setting owns its key in its own module

**A persisted setting is NOT owned by the settings UI.** Each one gets a small
`*_setting.gd`-style module (`class_name`, `extends RefCounted`) that owns three
things and nothing else:

1. its **`SETTING_KEY`** (the `Save.get_setting` / `Save.set_setting` key),
2. its **default** when the player hasn't chosen (usually read from the authored
   `GameConfig` baseline) and a **`resolve()`** that returns saved-or-default,
3. the **re-apply** — the code that makes a live scene reflect the new value.

`scripts/fps_setting.gd` (`FpsSetting`) is the **exemplar** — read it first when
adding a setting; `scripts/speed_lines_setting.gd` (`SpeedLinesSetting`, the speed
blur overlay) is the same shape with a live re-apply, `CameraManager` and
`MobileControls` are the signal-shaped variants. `SettingsMenu` then only *calls*
the module.

Two rules this exists to enforce:

- **Never put a setting's key or read-back as a `static` on `SettingsMenu`.** That
  inverts the dependency — a rendering/physics node would have to depend on the
  settings UI in order to know how to behave.
- **Never write the player's runtime choice into `Config.data`.** `GameConfig` is
  the designer-authored baseline that the setting's *own fallback default* reads;
  writing a player toggle back into it makes the "default" drift with player input
  and leak across scenes (it is a shared autoloaded resource). The choice goes in
  the save profile, via the module.

The node the setting drives should expose one **idempotent public apply method**
that is correct in both directions at any time (e.g.
`speed_lines.gd::set_effect_enabled(on: bool)`), and must stay fully wired while
switched off — a disabled state that skips its own setup can never be switched
back on without a scene reload.

Navigation lives inside the component: `show_list()` / `show_camera()` /
`show_schemes()` / `show_benchmark()` / `show_dev()` swap which page is visible (only the visible page contributes
height, so the long schemes page scrolls while the short list/camera pages don't),
and `page_changed(is_root)` lets the host steer its single bottom button — on a
sub-page it reads **< Back** (returns to the list); on the list it is the host's own
action. The saved choice in each section is highlighted and persisted via
`Save.set_setting`. Settings is also shown as a **pre-rally gate**: on mobile, if no
scheme has been chosen yet, Start opens this page (`_open_settings(true)`) instead of
launching — jumping **straight to the Mobile controls page** (skipping the category
list) so the player only picks a touch layout. The bottom button reads **Start >**
and confirms the pick (the highlighted default if untouched), saving it so the gate
never reappears, then begins the rally; pressing back cancels the gate to the car park.

All the scrollable menu lists (Settings, the tuning lift, the standings/podium
leaderboards) use **`TouchScrollContainer`** (`scripts/touch_scroll_container.gd`)
in place of a plain `ScrollContainer`: it drag-scrolls under touch even when the
finger lands **on a list-item button** (a plain `ScrollContainer`'s touch-scroll is
swallowed by the pressed child). It watches raw input in `_input` (before the GUI
pass) — a press arms a gesture, vertical motion past a small deadzone becomes a
scroll, a press that never moves passes through as a normal tap, and only the
release that ended a real drag is swallowed so the row under the finger doesn't also
fire. Scrolling is driven from the emulated mouse events (`emulate_mouse_from_touch`,
the same path the map-table pan uses).

**GARAGE.** A block garage interior holding the **map table** and the **tuning
lift**, with the player's **selected car sitting on the lift** (`_ensure_lift_car`,
spawned whenever the camera is inside — garage/lift — and dropped otherwise). The
**map table is the one exception**: `go_to(View.TABLE)` deliberately KEEPS the lift
car rather than clearing it. The table never shows the lift, but tearing the prop
down landed in the very frame the camera starts its flight to the table, which is
exactly where a hitch is most visible; the car is frozen with process disabled, so
leaving it standing costs nothing and the player is one Back away from wanting it
again. Every other station still clears it, which is what matters — the car park and
title lineup BORROW that node out of `_car_cache` (below), so the lift has to hand it
back before those build. Like the
car park, the lift prop is **reused only while both its instance id and a deep
`owned.hash()` match** — so any in-place data change to the selected car (repair, upgrade
toggle, engine swap, tuning) auto-respawns the prop; no mutator has to force a rebuild.

The lift and the car park **share the same `_car_cache`** (`hq.gd` → `_spawn_lift_car`
checks `_car_cache` before building, exactly like `_obtain_parked_car`): a car already
warmed by the parked lineup — the title screen, an engine-swap pick, or
Free Roam — is *borrowed* onto the lift by reconfiguring its transform/process-mode
rather than paying `CarProp.spawn` again (the expensive step: `car.tscn` embeds every
car glb, so instantiating it — even to immediately prune 8 unused bodies — is the "small
lag every time the tuning-lift car changes"). `_clear_lift_car` returns the favour: if
the departing lift car is the node `_car_cache` tracks for it, it's hidden + stowed
(same pattern as `_release_page_props`), never freed, so the next parked-lineup build or
lift visit reuses it. GARAGE/LIFT and CARPARK are mutually exclusive views, so handing
the one live node back and forth between the two contexts is safe — but it means
`_ensure_lift_car`'s id/hash "already there, no-op" fast path must also check
`_lift_car.visible`: a car-park mode that returns to the lift (engine-swap, wheels)
borrows the lift's node into its parked lineup and then hides + stows that lineup
(`_clear_lineup`) on the way back — so returning with the SAME car used to hit the id/hash
match while the shared node was still stowed off-screen, vanishing from the lift instead of
staying shown. Requiring `.visible` too forces the fall-through spawn path, whose cache hit
just repositions the node back onto the lift. (This bit the retired GARAGE-mode picker
first, which is where the guard came from.) See
[tuning.md](tuning.md) → *The tuning lift (UI)*. In the
garage the car rests **lowered on the ground** at its calculated settled ride height
(`car.gd` → `settled_ride_height`; see [tuning.md](tuning.md)).
Tapping the table drops to the map view; tapping the lift flies to the **tuning bay**
(LIFT view) for the currently-selected car. A HUD hint + Back (to the exterior) +
convenience buttons sit on top: the garage station row is **Back / Career / Garage /
Online / Multiplayer** — five fixed stops, so the left/right focus chain never changes
length.
**Garage** (`_enter_lift`) drops straight into the **tuning bay**
for the selected car — the car is changed there, on the lift (see below). **Free
Roam** (`_enter_free_roam`) — reached from the **title screen**, not here — opens the car
park across the WHOLE catalogue for a session-less drive in any car (owned or not). Because `car.tscn` embeds **all** the
authored car glb bodies (it reveals one and hides the rest — `car.gd` →
`_apply_model_visibility`), every parked prop is heavy to build, and Free Roam builds the
whole catalogue at once. Two mitigations keep the click from hitching: (1) each frozen
display prop **prunes the bodies it will never show** before duplicating meshes
(`car.gd` → `prune_inactive_bodies`, called from `CarProp.spawn`), and (2) the whole
catalogue is **pre-warmed once just after HQ boot** (`hq.gd` → `_ready` starts
`_prewarm_free_roam_deferred` *after* the `LoadingScreen` lifts, spawning **one prop per
frame**), each preview becoming a hidden cached prop **kept in memory** for the session —
preview entries use negative instance ids and are **exempt from
`_evict_unowned_cached_cars`**, so opening Free Roam is a cache hit, never a build. It used
to run synchronously behind the cover, but measured ~3x the entire rest of HQ boot
(see [debug-tools.md](debug-tools.md) → "HQ boot cost logging"), and HQ is
`run/main_scene` — so the warm now happens off the boot critical path while the player
looks at the title shot.

**It also only spawns while the player is STILL** (`hq_carpark._await_prewarm_window` asks
`hq._prewarm_should_wait` before every car). Each spawn is one indivisible `car.tscn`
instantiate — a ~100 ms frame on a slow device — so what decides whether it reads as a hitch
is not *when* it runs but *what the player is doing* while it lands: nothing, on a static
title shot; everything, mid-navigation. "Busy" is a reveal parade, a camera glide in flight,
a menu direction held, or any input inside `PREWARM_IDLE_MS`, and input is stamped in
`hq._input` (not `_unhandled_input` — a click on a garage button is exactly the interaction
to stay out of the way of, and those never reach the unhandled pass). A boot that does NOT
land on the title stamps its own arrival as interaction, because such a boot is a RETURN
(the podium's Continue, a quit back to HQ) and the player is heading somewhere within the
second. `PREWARM_MAX_STALL_MS` caps the waiting so a player who never sits still still ends
up with a warm catalogue rather than a permanently half-warm one.
If the player opens Free Roam *before* it finishes, nothing is
lost: `_obtain_parked_car` reuses whatever is warm and builds the remainder on the spot
(the old first-entry cost, for that remainder only), and the deferred loop skips those on
its next frame. (The underlying cost is that each car still *instantiates* all
embedded bodies before pruning; a deeper fix — lazy per-model body loading in `car.tscn` —
is noted but not yet done.) Settings no longer lives on this row — it's on the title
screen now (see the EXTERIOR section above).

**LIFT (the tuning bay).** Entering the bay **raises the car on the lift** — a slow
tween from the lowered (garage) pose up to `hq_lift_car_height` over
`hq_lift_raise_time` (`_apply_lift_height`); returning to the garage lowers it again.
The car is framed to one side (`hq_lift_cam_*`) as a **front three-quarter** shot — the eye
sits ~35° off the car's nose axis (it noses −Z, so the eye is round at −Z, in FRONT of it),
close enough to show face and near flank together, and on the −X side because +X leaves only
~0.7 m to the garage's side wall. The front is the readable end of a car (grille, lights,
stance) and the bay is where you pick one, so that's the end the shot leads with; it used to
be the mirrored **rear** three-quarter. See the export's doc comment in `game_config.gd` for
the full framing reasoning.

The bay opens on a **HUB page**
(`LiftPage.HUB`): a **bottom-left** readout of TWO equal-height boxed rows
(`_lift_info_panel`, a `VBoxContainer`) — row 1 the **car selector**
`[ < ] [ CAR NAME ] [ > ]` (`_lift_prev_button` / a boxed `_lift_car_label` /
`_lift_next_button`), row 2 the car's **stats line** (`_lift_car_stats_label`) — and UNDER
it the actions row: **< Back / Upgrades / Tuning / Test Drive**. (It was one panel holding a
single "name\nstats" label.) Both boxes wear `UITheme.readout_box()` with
`custom_minimum_size.y = UITheme.MENU_ROW_H` so a passive readout matches the buttons beside
it in height and shade — see [ui-design-system.md](ui-design-system.md). The two rows are
the hub's two cursor rows (see *Menu navigation* above).

To put a **different** car on the lift you stay in the bay: `< ` / `>` fire
`_cycle_lift_car(±1)` (the same callable the cursor activates), which sets the **selected
car** (`Save.set_selected_car`) and respawns the prop + refreshes the whole page. They walk
`_lift_cycle_order()` — the owned cars sorted by **ascending `instance_id`** (acquisition
order, which is stable). That is deliberately **not** `profile["cars"]` order:
`Save.set_selected_car` promotes the selected car to the FRONT of that array, so cycling by
list position would renumber the list on every press and ping-pong between two cars instead
of touring the collection. A car at 0 HP is cyclable like any other (it can sit on the
lift — and it is exactly the car you would bring here to repair). With only
**one** car owned there is nothing to cycle to, so `_refresh_lift_car_label` sets both
chevrons `visible = false` **and** `disabled = true` — hidden so the row reads as a plain
nameplate, disabled because `ButtonCursor` skips disabled stops but knows nothing of
visibility — and forces `_lift_row` back to `ACTIONS`; `_move_lift_row` is then a no-op
toward the empty selector row (`_selector_has_stops`). **Test
Drive** (`_test_drive`) launches free roam with the car already on the lift — no picker,
delegating to `_start_free_roam`. Each menu button opens that menu as its **own page** — a
`MenuPage` (`scripts/menu_page.gd`) whose solid body box is **centred on both axes and sized
to its contents**, not to a fraction of the screen; the car-description panel **hides** while
a sub-menu is open so the page has room. Every sub-page ends in ONE
centred horizontal **bottom action row** (`_lift_page_actions`, gapped off the body above):
**< Back** leads it (`_lift_back_button` → the hub; the hub's own Back returns to the garage),
and the TUNE page's own actions — `TuningPanel.action_buttons()`, i.e. **Reset to neutral**
and **Wheels** (`_tune_action_buttons`) — follow it. `_refresh_lift_ui` shows those only while
`_lift_page == LiftPage.TUNE`, set **after** `_tune_panel.setup` (which reasserts the Wheels
button's own visibility every refresh). The row lives inside `_lift_menu_bg`, so it hides with
the rest of the page on the HUB and needs no gating of its own. See
[ui-design-system.md](ui-design-system.md) → *A page's actions go in ONE bottom row*. Because
the hub controls and page chrome live on the hub, each menu page gets the **full panel height
to itself** and doesn't need to scroll. The two pages:


## Developer-only pages

**Benchmark, Dev and Seed lab are hidden from players.** `_build_list_page` adds
those three category buttons only when `SettingsMenu.dev_tools_enabled()` — which
keys off `OS.is_debug_build()`, the same signal `car.gd` / `hud.gd` / `world.gd` /
`perf_log.gd` use, so an exported release build never shows them while the editor,
debug exports and the headless test runner do.

The pages are still **built**, and `show_benchmark()` / `show_dev()` /
`show_seedlab()` still work — only the way in is removed. That keeps `_pages`,
focus handling and the tests that drive those pages directly unchanged.
`dev_tools_override` (static, `-1` = real build type) exists so a test can assert
the player-facing case, which `OS.is_debug_build()` alone makes untestable.

**Reset progress is NOT one of them.** Wiping the save used to sit on the Dev page
and so was invisible in release builds; it is now its own **player** category
(`show_reset`, added to the list unconditionally) and the Dev page no longer offers
a second copy — one route to an irreversible action, guarded by a confirm modal
rather than by hiding. Dev builds simply see both categories.

