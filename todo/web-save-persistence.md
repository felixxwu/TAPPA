# Web Save Persistence — implementation spec

> Status: **planned, not yet implemented.** Split out from
> `todo/save-persistence.md`, whose only remaining open item is *"verifying the
> save round-trip on an actual web export (IndexedDB flush — highest-risk,
> untested)."* The desktop save path is **DONE and green**
> (`scripts/save_manager.gd`, `tests/headless/test_save_manager.gd`); this spec
> covers **only** making that same path actually survive a reload in the HTML5
> build on itch.io and on mobile browsers. Follow the config-first convention
> (`CLAUDE.md`). Update `features/save-persistence.md` and add tests/a manual
> check in the same piece of work.
>
> **Brainstorm-first:** this is a draft to steer, not a settled plan — the open
> questions at the bottom (which lifecycle signal to trust, whether to force a JS
> IDB sync) need a decision before building. The mechanism below is the proposed
> approach grounded in the current code.

## Why it's a gap (and why it matters now)

The meta-game's entire progression — owned cars, per-car HP, installed upgrades,
inventory, rally completion — lives in `user://profile.json` via the `Save`
autoload. On the **HTML5 export**, `user://` is **IndexedDB** (Emscripten IDBFS):
`FileAccess`/`DirAccess` writes land in an in-memory FS that the engine syncs to
IndexedDB **asynchronously**. If the sync hasn't completed when the page goes
away, the write is lost — the player reloads and their garage is empty. We are
now testing on a phone (web build), so a broken round-trip means **none of the
work shipped so far actually persists** for the real audience.

## Current state (measured from the code)

- **The write path is desktop-correct.** `save_now()`
  (`scripts/save_manager.gd:141-158`) writes a `.tmp` then `DirAccess.rename`s it
  over `profile.json`, keeping one `.bak` generation — atomic on a real
  filesystem.
- **The "flush before the tab closes" hook is the weak link.** `_notification`
  (`save_manager.gd:60-63`) calls `save_now()` on `NOTIFICATION_WM_CLOSE_REQUEST`
  **or** `NOTIFICATION_APPLICATION_PAUSED`. The code comment already anticipates
  the IDB-flush risk — but:
  - `NOTIFICATION_WM_CLOSE_REQUEST` is a **desktop window-manager** event; the
    browser fires no such thing on tab close / navigation, so on web it never
    arrives.
  - `NOTIFICATION_APPLICATION_PAUSED` is primarily a **mobile-app** lifecycle
    notification; whether Godot 4's web export delivers it on a browser
    `visibilitychange`→hidden is **exactly what's untested** (open question).
- **No web-specific code exists.** No `OS.has_feature("web")` branch, no
  `JavaScriptBridge` usage anywhere (`grep` confirms). The save layer is
  platform-blind today.
- **The export is threaded.** `export_presets.cfg` Web preset has
  `thread_support=true`; `build_web.sh` notes itch.io must enable
  **SharedArrayBuffer** (cross-origin isolation) or the game won't boot — a
  prerequisite for the round-trip even being testable.
  `progressive_web_app/enabled=false` (no service-worker caching to muddy the
  picture — good for a clean test).

## Step 1 — Verify the round-trip (do this first, before any code)

The highest-value action is a real measurement; the fix may be small or
unnecessary depending on what we find.

1. `./build_web.sh`, serve `build/web/` with cross-origin-isolation headers
   (COOP/COEP — required for SharedArrayBuffer; a plain static server won't do).
2. In a desktop browser: play far enough to mutate the profile (grant a car / take
   damage / complete a rally), then **reload**. Does the profile survive?
3. Repeat with a **hard tab close + reopen**, and with **backgrounding** (switch
   tab / minimise) then returning.
4. On a **mobile browser** (the actual target): same, including swipe-away.
5. Instrument: log in `save_now()` and `load_or_new()` (guarded by
   `OS.has_feature("web")`) so the browser console shows write/read and the
   loaded car count.

**If it already persists** on reload and normal backgrounding, scope collapses to
documenting that + the mobile-close caveat. **If it doesn't**, Step 2.

## Step 2 — Harden the flush (only as needed)

Proposed mechanism, smallest-first:

- **Trust a real browser lifecycle signal.** The only event mobile browsers fire
  reliably when a page is going away is **`visibilitychange`→`hidden`** (and
  `pagehide`); `beforeunload`/close are unreliable on mobile. Determine which
  Godot notification (if any) these map to on web and hook `save_now()` to it. If
  none maps cleanly, register a `JavaScriptBridge` listener
  (`JavaScriptBridge.create_callback`) on `document` `visibilitychange` that calls
  back into `Save.save_now()`.
- **Force the IDB sync if the engine's async sync is the gap.** `FileAccess` close
  schedules an IDBFS `syncfs`, but it's async. If the verify shows lost writes,
  push a small JS shim (via `JavaScriptBridge.eval` or a `head_include`) that
  triggers `FS.syncfs(false, …)` after our write, and/or save **eagerly** (we
  already debounce ~1s; consider `save_now()` rather than debounced `save()` on
  web at key beats — car grant, rally complete — so the sync window opens early).
- **Confirm the atomic rename works on IDBFS.** The `.tmp`→rename dance
  (`save_now():145-157`) assumes POSIX rename semantics; verify `DirAccess.rename`
  behaves on the web FS, or fall back to a direct overwrite on web (the `.bak`
  still guards corruption).
- **Surface the degraded state.** `save_disabled` already exists
  (`save_manager.gd:43`); if web storage is blocked (private mode / no IDB), make
  sure it trips and the player gets the "progress won't be saved" notice (the
  notice UI itself is menus/settings work — here we just ensure the flag is set).

## Dependencies

- **None blocking.** Builds entirely on the shipped `Save` autoload.
- **Relates to** `scripts/settings_menu.gd` — its `user://settings.cfg` has the **same**
  web-persistence concern; whatever flush approach we land here should be reused
  for the settings store (don't solve it twice).
- **Prerequisite for trusting** any longer play session on the web/itch.io build,
  so effectively gates a public release.

## Testing

- **Headless (desktop) stays the regression guard** — `test_save_manager.gd`
  already covers the dict/atomic/migration logic platform-independently; keep it
  green. The web FS itself can't be exercised headlessly.
- **Manual web checklist** (Step 1, recorded in `features/save-persistence.md`):
  reload / tab-close / background round-trips on desktop **and** mobile, with the
  console instrumentation, as the acceptance check. There is no automated web
  test harness in this project, so this manual pass IS the verification.

## Out of scope / open questions

- **Which lifecycle signal to trust** — does Godot 4's web export deliver
  `NOTIFICATION_APPLICATION_PAUSED` / `FOCUS_OUT` on `visibilitychange`, or must
  we go through `JavaScriptBridge`? **Decide via Step 1 instrumentation.**
- **Whether a forced `FS.syncfs` is needed** at all, or the engine's automatic
  sync already suffices for reload/background (only hard-close is at risk).
- **Eager vs debounced save on web** — drop the 1s debounce on web for
  safety, or keep it and rely on the lifecycle flush? Trade-off: IDB write
  frequency vs loss window.
- **Named save slots / cloud sync** — explicitly out; single auto-saved profile
  stays the model (`todo/save-persistence.md` › *Decided*).
- **The `_recompute_showdown()` wiring** noted as open in `save-persistence.md`
  is a *roster* concern, not web — tracked there, not here.
