# Web multithreading (draft — open questions at the bottom)

Turn on Godot's threaded web build so work can leave the browser's main thread, then move our own heavy work
onto worker threads. Measured with the level replay on a Pixel 8 (`features/benchmark.md` → "Level replay").

**Depends on:** nothing to start. Phase 0 must pass before anything ships.

## Why, and what it can and can't buy

Pixel 8, Chrome, Hafren level replay (2026-11-19), ~12.6 ms of main-thread work per 16.7 ms frame:

| Part | ms | Leaves the main thread with threads on? |
| --- | --- | --- |
| Draw phase (WebGL calls, render sync, post-process) | ~6.4 | **No.** Godot's web renderer always runs on the main thread |
| Physics scripts (`_physics_process`, `car.gd` ~1.6) | ~4.2 | **No.** GDScript callbacks run where the scene tree runs |
| Process phase | ~1.1 | No |
| Car callbacks before the first signal (wheel ray casts, `_integrate_forces`) | ~0.6 | No |
| Physics engine step (Jolt) | ~0.3 | Only with `physics/3d/run_on_separate_thread` (to verify for Jolt on web) |
| Audio mixing | not measured | **Yes**: replays run muted (no user gesture), so real play costs more than the table |

So threads alone buy **well under 1 ms per frame** on the replay (the Jolt step plus audio mixing). The real wins
come from moving *our* work to `WorkerThreadPool`, which needs threads first:

- **Free-roam terrain streaming.** `scripts/free_roam/terrain_streamer.gd` builds chunks on the main thread
  under a per-frame time budget; over-budget frames are tracked as hitches (its `_rush_collision` path). Workers
  could build chunk data off-thread, leaving only the scene-tree attach on the main thread.
- **Level build at load.** `LevelView.load_level` (Hafren builds in ~1.2 s on desktop, much longer on a phone)
  and `GroundCover.build` (~150k tuft placements) are pure data work that splits across workers.

## Phases

### Phase 0 — does a threaded build work at all for us? (spike, nothing ships)

1. Export a second preset, `Web (threads)`, with `variant/thread_support=true`; leave the shipping `Web` preset alone.
2. `serve_web.sh` sends `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`
   (`tools/bench_collector.py` serves the files; add the headers there, behind a flag).
3. Run the level replay on the Pixel 8 and the Mac (same paired baseline method as the sweeps), threads vs no threads.
4. Check, by hand: **Google sign-in** (`scripts/cloud/google_sign_in.gd` → `_sign_in_web`; it relies on the popup
   posting back to `window.opener`, which cross-origin isolation cuts), **cloud save** (Firestore REST through
   `HTTPRequest`), and engine audio with sound actually playing.
5. On itch.io: upload the threaded build to a test page with itch's "SharedArrayBuffer support" option on.

**Gate:** threads must not be slower, and sign-in must have a working path (see the questions below).

### Phase 1 — ship the threaded build

- Switch `deploy.yml`'s web export to the threaded preset (or ship both, if a fallback is needed for browsers
  without cross-origin isolation).
- Turn on `physics/3d/run_on_separate_thread` if Phase 0 showed it works with Jolt on web and is faster.

### Phase 2 — move our heavy work to workers

- Terrain streaming chunk data → `WorkerThreadPool` tasks; the scene-tree attach stays on the main thread.
  Measure with the free-roam benchmark (`features/benchmark.md`), counting over-budget frames, not just fps.
- Level/ground-cover build at load → split across workers. Measure load time.
- Thread-safety audit first: shared `FastNoiseLite` instances and the caches noted in `terrain_manager.gd`.

### Not in scope

Rendering (it cannot leave the main thread on web) and GDScript physics callbacks. Those are cut by doing less
work (`car.gd`'s tick, the effect scripts, draw calls), tracked separately.

## Open questions (to settle with the user)

1. **Google sign-in.** Cross-origin isolation severs the popup's link back to the game. Options: keep a
   non-threaded build for signed-in play, move the callback to a redirect flow, or use Chrome's newer
   `Document-Isolation-Policy` header (Chrome-only), which isolates without breaking popups. Which way?
2. **Safari / iOS.** Threaded builds need cross-origin isolation, which iOS Safari supports, but threaded
   Godot web builds have had more audio and stability problems there. Do we care about iOS web players?
3. **Fallback.** Ship one threaded build, or detect `crossOriginIsolated` and fall back to the single-threaded
   build when it's off (two exports in the upload)?
4. **Worth it?** Phase 1 alone is under 1 ms per frame on the replay. Is the payoff Phase 2 (streaming hitches,
   load time), or should `car.gd` and the effect scripts come first?
