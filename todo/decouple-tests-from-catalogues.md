# Decouple tests from the car/engine catalogues

> Status: **DONE / implemented.** The injectable seam described below shipped as
> `CarLibrary.override_for_test` (`scripts/car_library.gd`) and
> `EngineLibrary.override_for_test` (`scripts/engine_library.gd`), used via
> `tests/headless/car_fixtures.gd` (`CarFixtures.install()`).

## Problem

Tests break whenever the authored catalogues change. Two recent examples:
renaming the LFA→Viper / Aventador→XJS churned ~40 test lines that hardcoded
`"lfa"` / `"aventador"` ids and display names; renaming the 911
(`"911 (930)"` → `"911 Turbo"`) broke a podium test that pinned the old name.

The catalogues (`CarLibrary.CARS`, `scripts/car_library.gd:101`; and
`EngineLibrary.ENGINES`, `scripts/engine_library.gd:59`) are *authored data*
that a designer retunes, renames, adds to, and removes from freely. Tests that
reach for a specific real entry by id — or assert its authored values — are
brittle by construction (this is exactly what `CLAUDE.md` › *Testing* already
warns against).

## Goal

Give tests their **own synthetic catalogues** to run against, so that
adding / removing / renaming / retuning a real car or engine cannot break a
logic, physics, or integration test. Contract tests that deliberately validate
the *shipped* catalogue stay on the real data.

## Approach — an injectable catalogue seam (static override)

Both libraries are `class_name` classes built around a `const` array + static
`by_id`/`index_of`. The least-invasive seam that matches this architecture is a
static override plus a single accessor. Production never sets the override, so
behaviour is unchanged; tests install a synthetic catalogue and reset it after.

Rejected alternatives: **constructor/parameter DI** (threading a catalogue
object through Car / SaveManager / RallyLibrary / HQ / Podium is a large refactor
against static-method-everywhere code); **mutating `const CARS`** (it's `const`,
and sharing a mutated array is worse than a clean accessor).

### `CarLibrary` seam (`scripts/car_library.gd`)

```gdscript
static var _test_catalogue: Array[Dictionary] = []   # empty ⇒ use the real CARS

static func all() -> Array[Dictionary]:
    return _test_catalogue if not _test_catalogue.is_empty() else CARS

static func override_for_test(cars: Array[Dictionary]) -> void:
    _test_catalogue = cars

static func reset() -> void:
    _test_catalogue = []
```

- `index_of()` (`car_library.gd:260`) and `by_id()` (`car_library.gd:268`)
  change to iterate `all()` instead of `CARS`. This covers **every**
  `by_id`/`index_of` caller automatically: `save_manager.gd` (117, 224, 346-347,
  513), `hq.gd` (781, 2026, 2049, 2187, 2230, 2416, 2478, 2627), `podium.gd`
  (394, 647, 687, 727), `engine_swap.gd` (61), `rally_session.gd` (179, 296),
  `reward_system.gd` (111, 133).
- **Direct `CarLibrary.CARS` readers** switch to `CarLibrary.all()`:
  - `car.gd:559` (`next_car_index`), `565` (`current_car_name`),
    `575` (`bonnet_cam_offset`), `594` (`apply_car`), `786` (`apply_owned` path)
  - `rally_library.gd:255, 379, 382, 391, 392, 395`
  - `reward_system.gd:119, 154`
  - `podium.gd:783` (`_car_names`)
  - `settings_menu.gd:111`
- `power_to_weight(entry)` (`car_library.gd:284`) and
  `max_lateral_g(entry, cfg)` (`car_library.gd:307`) already take a plain dict —
  no change; they work on synthetic dicts today.

### `EngineLibrary` seam (`scripts/engine_library.gd`)

Simpler — **no production code reads `ENGINES` directly**; all readers go through
`by_id` / `apply(dict)`.

```gdscript
static var _test_catalogue: Array[Dictionary] = []

static func all() -> Array[Dictionary]:
    return _test_catalogue if not _test_catalogue.is_empty() else ENGINES

static func override_for_test(engines: Array[Dictionary]) -> void:
    _test_catalogue = engines

static func reset() -> void:
    _test_catalogue = []
```

- `index_of()` (`engine_library.gd:123`) and `by_id()` (`engine_library.gd:130`)
  iterate `all()`. This covers `car.gd` (608, 791, 795, 807),
  `upgrade_library.gd` (149, 155), `hq.gd` (2234), `car_library.gd:285`,
  `engine_swap.gd:18`.
- `FIRING` (`engine_library.gd:34`) stays `const` — it's keyed by *layout*
  (`"i4"`, `"v8"`, …), a structural key, not an authored entry. Fixture engines
  reuse the real layout keys, so `apply()` and the audio path keep working.
- `apply(engine, cfg)` (`engine_library.gd:138`) takes a dict — no change.

## Fixtures — `tests/headless/car_fixtures.gd`

A new `class_name CarFixtures` (extends `RefCounted`) builds small synthetic
catalogues with **stable fixture ids/names that never track the real
catalogue**. Fixture cars carry all the real fields the code reads; fixture
engines reuse real `FIRING` layout keys.

Fixture cars (enough variety for every axis the tests exercise):

| id | drivetrain | weight bias | p/w band | notes |
|----|-----------|-------------|----------|-------|
| `fx_light_rwd` | RWD | ~50/50 | low | light roadster-like starter |
| `fx_fwd_hatch` | FWD | nose-heavy | low-mid | FWD path + an eligibility exclusion |
| `fx_rwd_coupe` | RWD | tail-heavy | mid-high | distinct large body, in mid p/w band |
| `fx_awd` | AWD | nose-heavy | mid | AWD handbrake / eligibility path |

Fixture engines (referenced by the cars above): at least an `i4` and a `v8`
(distinct layouts so audio/firing differences are exercised), each a full valid
`EngineLibrary` entry with its own `fx_*` id.

API:

```gdscript
class_name CarFixtures

static func cars() -> Array[Dictionary]      # the synthetic car roster
static func engines() -> Array[Dictionary]   # the synthetic engine catalogue

# install both overrides at once (call in before_each / before_all)
static func install() -> void:
    EngineLibrary.override_for_test(engines())
    CarLibrary.override_for_test(cars())

# clear both overrides (call in after_each / after_all)
static func restore() -> void:
    CarLibrary.reset()
    EngineLibrary.reset()
```

Every fixture returns a fresh `.duplicate(true)` per call so a test that mutates
an entry can't corrupt the fixture for the next test.

## Reset strategy — no leaks between files

Global static overrides must be cleared or they bleed into the next test file.
The rule for every converted file:

- Call `CarFixtures.install()` in `before_each` (or `before_all` when the file
  only reads the roster and never mutates it).
- Call `CarFixtures.restore()` in the matching `after_each` / `after_all`.

`CarFixtures.restore()` is unconditional and idempotent (`reset()` on both
libraries just clears the override array), so it is always safe to call — a file
may call it in teardown even if it never installed. This keeps the contract
simple: **every converted file resets in its own teardown.** No shared-teardown
magic is relied on, so the reset can't silently disappear when a helper is
refactored. The seam tests (below) additionally prove `reset()` restores the
real catalogue, guarding against a leak surviving a run.

## Test-file plan

### Convert to fixtures (were brittle: hardcoded id / name / value)

- `test_save_manager.gd` — `grant_car("viper"/"xjs"/…)`, `by_id(...)["max_hp"]`,
  `by_id(...)["engine"]` → grant/read fixture ids.
- `test_menu_flow.gd` — `grant_car`, `_grant_car`, the per-instance body-size test
  (632-634), the reward-name test (1288), eligibility derivation (595-596).
- `test_car.gd` — `apply_car(index_of("focus"/"xjs"/"mx5"))`, `by_id("twingo")`,
  `EngineLibrary.by_id(...)` value assertions.
- `test_rally_session.gd` — `car_id` / `car_name` fixtures; `by_id(reward)`.
- `test_reward_system.gd` — grants + `by_id`/`CARS` iteration over fixtures.
- `test_engine_swap.gd` — `CARS[0]`, real engine → fixture car + fixture engine.
- `test_config_isolation.gd` — `apply_car(index_of("charger"/"mx5"))`,
  `EngineLibrary.by_id(...)`.
- `test_upgrade_library.gd` — `by_id("twingo")` + `EngineLibrary.by_id(...)`.
- `test_car_library.gd` — the **apply / physics / cycle** cases
  (145-160, 204-206, 216-, 228-237, 247-, 260-, 282-, 298-, 307-, 317-, 326-)
  move to fixtures. Keep the **seam-logic** cases (below).
- `test_start_line.gd` — `CARS[prop._car_index]`, rival car_name.
- `test_rally_library.gd` — the `by_id("mx5")` split/derive cases → fixture car.

### Stay on the real catalogue (deliberate contract tests)

- `test_car_types.gd` — validates that *every shipped car* has a valid
  `car_type` / fields. Iterates `CARS` opaquely; doesn't break on rename/retune.
- `test_engine_library.gd` — validates the *shipped engines* (every entry has a
  firing table, `index_of`/`by_id` round-trip). Opaque iteration.
- `test_car_library.gd` roster-invariant cases (28-89): `> 1 car`, unique names,
  every entry's `engine` id resolves, `index_of`/`by_id` round-trip. These are
  the catalogue's own contract.

### New: seam tests

Add cases proving the seam itself:
- `override_for_test` makes `by_id`/`index_of`/`all()` return the synthetic set;
  `reset` restores the real one.
- An empty override falls back to the real catalogue.
- Same for `EngineLibrary`.

## Testing / verification

- Convert file-by-file; run each converted file with
  `./run_tests.sh --fast <file>` as it lands.
- After all conversions, a full `./run_tests.sh` (wide blast radius: touches
  core catalogue accessors used across physics, save, menus, rewards).
- Confirm the runtime budget (~5 min) is unaffected — fixtures are cheap dicts;
  no extra world generation.

## Out of scope

- `RallyLibrary` / `UpgradeLibrary` seams (only do these if a later need arises;
  same pattern would apply).
- Changing any production behaviour — the seam is inert in production.

## Follow-up docs

- `features/testing.md` — document the fixture pattern + the mandatory reset.
- `CLAUDE.md` › *Testing* — note that catalogue-dependent tests should install
  `CarFixtures` rather than reaching into the real catalogue.
