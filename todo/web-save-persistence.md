# Web save persistence — remaining work

**Step 2 (harden the flush) is DONE.** `save_manager.gd` has `flush_and_sync()` — the
single "we are about to go away" entry point — plus the `flushed` signal and the browser
lifecycle listeners that call it; covered by `tests/headless/test_save_web_lifecycle.gd`.
`features/save-persistence.md` is the living doc.

## Open: Step 1 — a manual on-device round-trip

Needs a human at a browser; nothing here is a code task.

1. `./build_web.sh`, serve `build/web/` with any plain static server (the build is
   single-threaded, so no COOP/COEP cross-origin-isolation headers are needed).
2. Desktop browser: play far enough to mutate the profile (grant a car / take damage /
   complete a rally), then **reload**. Does the profile survive?
3. Repeat with a **hard tab close + reopen**, and with **backgrounding** (switch tab /
   minimise) then returning.
4. On a **mobile browser** (the actual target): the same, including swipe-away.
5. Record the result in `features/save-persistence.md`.
