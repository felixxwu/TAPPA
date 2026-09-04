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
never reappears, then begins the run; pressing back cancels the gate.

Every scrollable menu list uses **`TouchScrollContainer`** (`scripts/touch_scroll_container.gd`)
in place of a plain `ScrollContainer`: it drag-scrolls under touch even when the
finger lands **on a list-item button** (a plain `ScrollContainer`'s touch-scroll is
swallowed by the pressed child). It watches raw input in `_input` (before the GUI
pass) — a press arms a gesture, vertical motion past a small deadzone becomes a
scroll, a press that never moves passes through as a normal tap, and only the
release that ended a real drag is swallowed so the row under the finger doesn't also
fire. Scrolling is driven from the emulated mouse events (`emulate_mouse_from_touch`,
the same path the deleted map-table pan used).


**The HQ station sections that used to sit here are DELETED.** ~135 lines described the
diegetic hub's GARAGE and LIFT stations — the car on the lift, the `_car_cache` the lift
and car park shared, the station rows, the lift's sub-pages — none of which is a settings
concern and none of which exists (decision 9). What was worth keeping from them lives with
its own subject now: the car-prop caching pattern in [asset-pipeline.md](asset-pipeline.md),
the tuning pages in [tuning.md](tuning.md), and the one-bottom-action-row rule in
[ui-design-system.md](ui-design-system.md).

## Developer-only pages

**Benchmark, Dev and Seed lab are shown to everyone.** `_build_list_page` adds
those three category buttons whenever `SettingsMenu.dev_tools_enabled()` — the
single switch `car.gd` / `hud.gd` / `world.gd` / `world_panel_host.gd` /
`terrain_manager.gd` / `perf_log.gd` all key off for every other
dev affordance (force arrows, grip grid, world-menu A/B, config hot-reload,
skip-to-finish, chunk-border overlay, perf log). It defaults to **true** — dev
tools are exposed in the exported release/web build, not just the editor and
debug exports.

The pages are still **built** either way, and `show_benchmark()` / `show_dev()` /
`show_seedlab()` still work regardless of the switch — only the way in is gated.
That keeps `_pages`, focus handling and the tests that drive those pages directly
unchanged. `dev_tools_override` (static, `-1` = real default of `true`) exists so
a test can still assert the **hidden** case, which the always-on default alone
can't produce.

**Reset progress is NOT one of them.** Wiping the save used to sit on the Dev page
and so was invisible in release builds; it is now its own **player** category
(`show_reset`, added to the list unconditionally) and the Dev page no longer offers
a second copy — one route to an irreversible action, guarded by a confirm modal
rather than by hiding. Dev builds simply see both categories.

**Confirming the wipe reloads the hub scene** (`SettingsMenu._wipe_progress` →
`_reload_after_wipe`, at the end of the local wipe and again after the cloud
publish resolves when signed in). `Save.reset_new_game()` only replaces the
save profile in memory — it does nothing to whatever scene is currently live,
so without a reload the player kept driving their old car through a
now-nonsensical (fully dark) overworld: nothing re-ran the "no starter car
yet" setup a real new game boots into. The reload routes through
`Scenes.change_to(get_tree(), Scenes.hub_path())`, the same seam every other
hub transition uses, so it re-instantiates the hub fresh against the
just-wiped profile (starter-car picker included) exactly like a brand-new
player's first boot, and stays inert under `Scenes.block_real_changes` in
tests.

