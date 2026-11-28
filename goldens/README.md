# Goldens

Change detectors for the Rust migration's parity contract (`todo/2026-11-27-rust-native-migration.md`). Each file
is the blessed output of one deterministic mode (Phase 1.1's golden replay: headless, `--fixed-fps 60`, physics
thread off, `--seed=90210`), and a check compares a fresh run against it byte for byte. They pin every tuned
value on purpose, which is why they live here and not in `tests/headless/`.

| File | Mode | Check |
|---|---|---|
| `car_step.jsonl.gz` | free-run car snapshot per tick (1.2) | `./run_level_replay.sh --car-golden [rec] --check` |
| `events.jsonl.gz` | game-state trace on the pose-fed replay (1.4) | `./run_level_replay.sh --events-golden --check` |
| `scene_counts.jsonl.gz` | world items at pinned spots, matched within 1 cm (1.6) | `benchmark/scene_counts.tscn -- --check=…` |
| `menus.jsonl.gz` | keyboard and gamepad menu flow (1.5) | `benchmark/menu_flow.tscn` `--check` |
| `touch.jsonl.gz` | touch and tilt flow (1.5) | `benchmark/touch_flow.tscn` `--check` |

Format: gzipped JSON lines, sorted keys and full precision (`JSON.stringify(row, "", true, true)`). Line 1 is a
header `{format, level_path, car, seed, godot_version, platform, recording}`.

**Only `./bless.sh <car-step|events|scene-counts|menus|touch>` writes here.** It reruns the mode with `--bless`;
each mode, given `--bless`, writes its own file above. Bless only when a behaviour change is intended, never to
make a Rust port pass, and commit it with a `Bless:` line in the message saying what changed and why. Goldens are
blessed on the CI image (x86 Linux), since floating point may differ on other machines: run the Tests workflow by
hand with `bless` set, and commit the `goldens` artifact it uploads. CI's `goldens` job checks every blessed file
(skipping unblessed ones), and `bless-guard` fails a commit that changes this folder without a `Bless:` line.

Which feature each golden covers is in `todo/2026-11-28-parity-checklist.md`.
