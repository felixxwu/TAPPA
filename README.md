# TAPPA

A rally career game built in Godot — "Gran Turismo, but with rally stages."
You build and tune a garage of cars, enter seeded rallies on a world map, and
chase a clean combined time across three events per rally, all while every car
you field (bar your immortal starter) is a real, depreciating asset that can be
damaged and ultimately wrecked. See [`gameplay.md`](gameplay.md) for the full
design vision — it's the north star the implementation ladders up to.

## Engine version

Pinned to **Godot 4.6.3** (see `GODOT_VERSION` in
`.github/workflows/deploy.yml`). Use that version locally to match CI.

## Project layout

The Godot project lives at the **repository root** — `project.godot`,
`run_tests.sh`, `build_web.sh`, etc. are all directly here. There's no
subdirectory to `cd` into.

For how the codebase itself works, start at [`features/README.md`](features/README.md) —
an agent-oriented index of ~60 feature docs (car physics, drivetrain, engine,
terrain, rendering, menus, testing, and more).

## Running the tests

```bash
./run_tests.sh              # full headless suite (GUT, vendored in addons/gut/)
./run_tests.sh --fast <name> # only test files matching <name>, for quick iteration
```

A full run currently takes roughly 8 minutes. Set `$GODOT` if your Godot binary
isn't at one of the runner's default locations. See
[`features/testing.md`](features/testing.md) for the full test-suite writeup.

## Building

Each script exports one platform locally and stamps a git-derived version
(`0.<commit count> (<short sha>)`) into `project.godot` for the duration of the
export, restoring it on exit:

```bash
./build_web.sh       # "Web" preset      -> build/web/index.html, zipped to build/rally-web.zip
./build_android.sh   # "Android" preset  -> build/android/tappa.apk
./build_windows.sh   # "Windows Desktop" preset -> build/windows/tappa.exe
```

Each accepts `--debug` for a debug export (default is `--export-release`). CI
(`.github/workflows/deploy.yml`) runs these same scripts on every push to
`main` and pushes the results to itch.io, plus a separate Android App Bundle
export to Google Play.

## Where to go next

- [`features/README.md`](features/README.md) — the map of how the codebase works.
- [`gameplay.md`](gameplay.md) — the design north star.
- [`CLAUDE.md`](CLAUDE.md) — project rules for working in this repo (docs-in-sync,
  menu navigation, testing conventions, environment notes).
