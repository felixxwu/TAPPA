# TAPPA

A PS1-style rally game built in Godot, driven on one hand-built level: **Hafren
Forest**, a few kilometres of Welsh forestry roads rebuilt from real map data. Drive
it freely, take on rallies at its start lines, and spend what you earn on parts and
cars. Earlier versions (a rally career, a run-based roguelike, a procedural island)
are deleted; git history has them.

**Describing the game anywhere?** [`docs/store-listing.md`](docs/store-listing.md)
is the single source of truth for the pitch — tagline, short and full store
descriptions, the words to avoid, and the checklist of every surface (itch.io,
Google Play, the GitHub About field) that has to be kept in sync.

## Engine version

Pinned to **Godot 4.6.3** (see `GODOT_VERSION` in
`.github/workflows/deploy.yml`). Use that version locally to match CI.

## Project layout

The Godot project lives at the **repository root** — `project.godot`,
`run_tests.sh`, `build_web.sh`, etc. are all directly here. There's no
subdirectory to `cd` into.

For how the codebase itself works, start at [`features/README.md`](features/README.md) —
an agent-oriented index of the feature docs (car physics, drivetrain, engine,
the level, rendering, menus, testing, and more).

## Running the tests

```bash
./run_tests.sh              # full headless suite (GUT, vendored in addons/gut/)
./run_tests.sh --fast <name> # only test files matching <name>, for quick iteration
```

A full run takes roughly 5 minutes on a development machine (about 9 on a slower
CI-class container). Set `$GODOT` if your Godot binary
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
- [`CLAUDE.md`](CLAUDE.md) — project rules for working in this repo (docs-in-sync,
  menu navigation, testing conventions, environment notes).
