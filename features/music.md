# Music

Interactive, looping background music. A single track loops into itself
seamlessly; the system is built so context tracks (HQ / event) can later swap on
an exact bar boundary. Ported from the `wufo3` project's double-buffered Tone.js
loop scheduler, adapted to Godot's audio model. Design spec:
`docs/superpowers/specs/2026-07-16-interactive-music-loop-scheduler-design.md`.

## File structure contract

A song is split into **4 segments** played in order. Each segment file is authored
(4/4) as **4 bars lead-in + 8 bars main + 4 bars lead-out** (16 bars). The 8-bar
main is what re-triggers; the lead-in and lead-out are transition material that
plays **simultaneously (full-volume sum)** across the seam between consecutive
segments (segment N's lead-out over segment N+1's lead-in, and vice-versa). The
short 8-bar re-trigger means a song swap can land roughly every 8 bars (~11 s at
168 bpm) instead of waiting a whole 32-bar phrase. bpm is per song (shared by its
4 segments), so bar duration is derived per song, not global. Files must import
with looping OFF and no leading/trailing silence.

Six tracks ship today, four segments each, as ~128 kbps Ogg Vorbis
(`music/echochamber1..4.ogg` is the HQ theme; `skillz`, `deadlock`, `nightandday`,
`threaded`, `whoyouare` are the rally pool). Segments must be authored so N→N+1,
the 4→1 wrap, and a cross-song 4→(new)1 all sum cleanly.

## Context selection (scene state, not transitions)

Which track plays is decided by the **live scene state**, not by transition hooks
(which are fragile). Every frame `MusicDirector._process` reads
`get_tree().current_scene.scene_file_path` and resolves it via
`MusicDirector._song_for_scene`: the **HQ scene** (`res://hq.tscn`, tested by
`MusicLibrary.is_hq_scene`) always wants `HQ_SONG` (echo_chamber); **every other
scene** (loading/start line/driving `main.tscn`, `standings.tscn`, `podium.tscn`,
…) wants the **current rally song** — one entry of `MusicLibrary.RALLY_SONGS`
(`skillz`, `deadlock`, `nightandday`, `threaded`, `whoyouare`). The result is
re-queued via `play_song`, which is idempotent and **latches the swap for the next
8-bar handoff** — so leaving the HQ doesn't cut to the rally song immediately; the
current Echo Chamber loop finishes and the rally song comes in beat-aligned (and
vice-versa on return). The `MusicDirector` autoload persists across scene changes,
so playback is continuous throughout.

### Random rally song (per event)

The rally context does not play a fixed song. `MusicDirector` holds
`_current_rally_song`, and **re-picks it at every loading screen**: `_tick` calls
`_update_loading_edge`, which watches the `loading_screen` group and, on its rising
edge (empty → present), calls `MusicLibrary.random_rally_song(_current_rally_song)`
— a uniformly random pool entry, **never the one just played** (no back-to-back
repeat). So a fresh song is chosen each time an event loads / you return to HQ /
the next event begins, and it's held for that whole event (every non-HQ scene
resolves to the same locked-in song until the next loading edge). The edge check
runs **before** the stall/suspend early-returns, so it still fires on the web build
(where a load suspends the director) — the pick lands while the loading screen is
up, so the following rally uses it. `_current_rally_song` is seeded once in
`_ready` (and lazily by `_song_for_scene`) so a rally entered before any loading
screen still has a valid song. HQ music is unaffected — it's always echo_chamber.

> Cross-tempo caveat: an HQ↔rally swap sums Echo Chamber's lead-out with the rally
> song's lead-in (and vice-versa). These are now Ogg Vorbis, which carries no fixed
> per-file encoder head-delay (the MP3 issue this note used to flag), so the summed
> tails stay tightly aligned at the swap seam. Swaps are also infrequent (HQ↔rally,
> and rally songs only change across a loading screen — never mid-event).

## Timing model (handoff-anchored)

The scheduled invariant is the **handoff `H`** — where the outgoing segment's main
loop ends and the incoming segment's main loop begins. The incoming segment's
lead-in must end at `H`, so it starts at `H − lead_in_sec(bpm)` (a faster song
starts later). After launching, `H` advances by `loop_body_sec` (the 8-bar main).
Continuous play is a constant 8-bar interval.

## Segment sequencing

`MusicDirector` tracks `current_song` + `current_segment`. At each handoff
`advance()` decides what to launch next: **segment 0 of `requested_song`** if the
requested song differs from the current one (a scene/context change interrupts the
sequence), otherwise **the next segment of the current song, wrapping 3→0**. So a
song plays 1→2→3→4→1→… until a different song is requested, at which point it jumps
straight to that song's segment 1 at the next beat-aligned handoff.

## Components

- **`scripts/music_schedule.gd`** (`MusicSchedule`) — pure static timing math
  (bar durations, `fire_start`, `late_by`, `advance_handoff`, `seed_handoff`,
  `catch_up`). No nodes/audio; fully unit-tested (`tests/headless/test_music_schedule.gd`).
- **`scripts/music_library.gd`** (`MusicLibrary`) — the `SONGS` catalogue
  (`id → {bpm, segments}`) + `by_id` / `segment_count`, plus the scene→song
  mapping (`HQ_SCENE`/`HQ_SONG`/`is_hq_scene`) and the rally pool
  (`RALLY_SONGS`/`random_rally_song`). Same pattern as
  `EngineLibrary`.
- **`scripts/music_director.gd`** (`class_name MusicDirector`, autoload singleton
  **`Music`** — the singleton can't be named `MusicDirector` without colliding
  with the class) — one `AudioStreamPlayer` + `AudioStreamPolyphonic`; each 8-bar
  segment is a voice via `play_stream(stream, from_offset)` so overlapping tails
  share one mix timeline. `advance(now)` is the pure per-frame decision (segment
  sequencing + swap latch); `seed_grid(now, id)` is the first-play grid seed;
  `_process` reads the scene state (`update_for_scene`) then applies `advance`.
  `PROCESS_MODE_ALWAYS` keeps music playing while paused. No hardcoded autostart —
  the first frame picks the song from the live scene.

## Public API (`Music` autoload)

- `Music.play_song(id)` — start if idle (first voice's lead-in is the intro), else
  latch a swap that lands at the next handoff.
- `Music.advance(now)` / `Music.seed_grid(now, id)` — the pure scheduling core
  (also the unit-test surface).

## Audio routing & volume

`MusicDirector` creates a dedicated **Music** bus at `_ready` (routed to Master),
independent of the procedural engine audio (`features/engine-audio.md`, on
Master). Volume is a **player setting** persisted in the save profile
(`Save.set_setting("music_volume", …)`, linear [0,1], default `DEFAULT_VOLUME =
0.6`) — the single source of truth (there is no `GameConfig` volume). `_ready`
reads it via `Save.get_setting`; `Music.set_volume(linear, persist := true)`
clamps, applies `linear_to_db` to the bus live, and persists. The Settings menu's
**Audio** page (`SettingsMenu`, shared by the HQ title screen and the pause menu)
has a focusable `HSlider` (stepped in 5% increments, `step = 0.05`) that calls
`set_volume` as you drag — live even while paused (`PROCESS_MODE_ALWAYS`).

## Clock & robustness

The scheduler clock is a **monotonic wall clock** (`Time.get_ticks_usec()`).
`AudioStreamPlayer.get_playback_position()` was the original plan, but it does
**not** advance for an `AudioStreamPolyphonic` stream (no single timeline), so it
cannot be used — the wall clock decides *when* to launch voices instead.
Overlapping voices still stay sample-aligned because they share the one
polyphonic mix timeline, and `from_offset` (late-compensation) absorbs per-frame
jitter; wall-vs-audio drift is ~ppm, negligible over a session. The `catch_up`
guard re-aligns the grid after a stall (dropping a re-trigger rather than
desyncing) — relevant to the single-threaded web build.

## Stall recovery (web)

The scheduler runs on a wall clock (`_audio_now()` = `Time.get_ticks_usec()`),
because an `AudioStreamPolyphonic` has no single playback position to read. On the
**web build** the loading screen (`world.gd._ready()` → `_generate_track`) blocks
the single main thread for seconds; the web audio pipeline underruns and goes
**silent**, while the wall clock keeps advancing. On resume the scheduler would
otherwise fire the next segment against time the audio never played — "goes silent,
resumes wrong".

`music_director` handles this in `_tick(now)` (called by `_process` with the real
clock; `_tick` is the testable seam):

- **Detect:** if the wall-clock gap between processed frames exceeds
  `GameConfig.music_stall_threshold_sec` (~0.5 s — far above a normal ~16 ms frame),
  a stall is inferred.
- **Suspend (edge-triggered):** stop the polyphonic playback (killing the now-dead
  voices), clear `current_song`/`requested_song`, and early-return each frame so the
  scene auto-restart path stays disabled. `world.gd` yields a frame between every
  generation stage, so the stop/clear runs only on the transition into suspend;
  later stall frames just reset the stable window.
- **Resume (clean):** once frames have flowed normally for
  `GameConfig.music_resume_stable_sec` (~0.4 s) AND no `LoadingScreen` is present
  (it joins the `loading_screen` group), re-seed from the current clock and launch
  segment 0 of the scene's wanted song. The loading-group check is load-bearing —
  chunk-precompute frames can satisfy the stable window mid-generation, so the group
  check is what prevents a mid-load resume.

The whole mechanism is gated on `OS.has_feature("web")` (overridable in tests):
desktop has an independent audio thread that does not underrun on a main-thread
stall, so a GC/window-drag hitch there must not restart otherwise-fine music. The
same detector also recovers from tab-backgrounding (main loop throttles, audio
dies, wall clock races), not just the loading screen.

## Tests

`tests/headless/test_music_schedule.gd` (timing relationships),
`test_music_library.gd` (catalogue contract), `test_music_director.gd`
(scheduling logic, no real audio), plus an autoload-present check in
`test_smoke.gd`. Per project rules, none pin authored values (bpm, durations,
song identity) — they assert relationships and logic.

## Not yet built (see the design spec)

- `stop()` and event→HQ transition semantics.
- Ducking music under SFX/engine audio.
