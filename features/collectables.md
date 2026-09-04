# Collectables — stage coins

**Source:** `scripts/coin_layout.gd` (`CoinLayout` — pure placement planner),
`scripts/coin_field.gd` (`CoinField` — builds the coins + runs the pickup query),
`scripts/game_config.gd` (`@export_group("Roguelike Collectables")`,
`coin_layout_params()`, `coin_render_params()`), `scripts/world.gd`
(`_build_coins`, `_on_coin_collected`), `scripts/hud.gd` (`set_coin_count`,
`_build_coin_label`), `scripts/run_session.gd` (`report_event_result`'s third
argument), `scripts/region_run_mode.gd` (`stage_money`'s fourth argument),
`scripts/lifetime_stats.gd` (`COINS_COLLECTED`).
**Tests:** `tests/headless/test_coin_layout.gd`, `tests/headless/test_coin_field.gd`,
`tests/headless/test_region_run.gd` (the "Coins" section — banking + the lifetime
ledger), `tests/headless/test_hud.gd` (`test_coin_counter_starts_hidden_and_shows_on_first_call`)

RR's coins (`todo/roguelike-pivot.md` decisions 13, 35, 36, 50 — stage 8 of
`todo/roguelike-pivot-plan.md`, the last feature stage of the pivot). Money
collectables scattered on a region-run stage, **off the racing line**, so picking
one up is a real gamble against the fixed clock: leaving the fast line costs time,
the timer is the run's only fail state (decision 4), and there is no other reason
this game would ever ask a player to swerve.

## The mechanic, end to end

```
world.gd._place_world_props
  └─ _build_coins(cfg, road_centerline, finish_len)
       ├─ skip unless RunSession.is_active() and mode_id() == RunMode.REGION
       ├─ CoinLayout.plan(...)              — WHERE the coins go (pure)
       └─ CoinField.build(layout, ...)      — the meshes + the pickup query
            └─ CoinField._physics_process   — proximity check every tick
                 └─ coin_collected(index, total) signal
                      ├─ world.gd._on_coin_collected → HUD.set_coin_count(total)
                      └─ CoinField itself → Audio.play_beep(...)  (the pickup chime)

world.gd._on_session_event_completed (stage finish)
  └─ coins_collected = _coin_field.collected_count (0 if none were built)
       └─ RunSession.report_event_result(elapsed_ms, hp_lost, coins_collected)
            ├─ Save.add_lifetime_stat(COINS_COLLECTED, coins_collected)   — ALWAYS
            └─ if the stage was NOT missed:
                 RegionRunMode.stage_money(idx, elapsed_ms, target_ms, coins_collected)
                   → completion + fast_bonus, region-scaled, PLUS
                     coins_collected * GameConfig.coin_money  (flat, unscaled)
```

A challenge run never reaches `_build_coins`'s payload — `RunSession.mode_id() !=
RunMode.REGION` short-circuits it, exactly like the opposite check
`_generate_centerline` already makes for challenge-only seed retries. A challenge
has no per-stage money to boost and no fail state to gamble against, so nothing is
placed for it.

## Placement — off the racing line, deterministically (CoinLayout)

`CoinLayout.plan(centerline, finish_len, track_width, seed_value, params)` is pure:
no scene, no car, no RNG state outside the call. It reads `GameConfig
.coin_layout_params()` — `count`, `offset_m`, `offset_jitter_m`, `start_margin_m`,
`end_margin_m` — and:

1. Splits the usable arc length (`finish_len` minus both margins) into `count` equal
   segments and draws one arc offset per segment (stratified, not pure random —
   spreads coins across the whole stage instead of letting them cluster wherever the
   RNG happens to land, the same reasoning `TreeScatter`'s grid uses).
2. For each, picks a road edge (`side` = ±1) and a lateral distance of
   `track_width / 2 + offset_m + rand() * offset_jitter_m` — **always at least
   `offset_m` beyond the visible road edge**. That floor is the whole mechanic
   (decision 35): a coin is never reachable without actually leaving the road.
3. Samples the centerline's position + tangent at that arc offset (mirrors
   `SignLayout._tangent_at`) and offsets perpendicular to it.

**No signposting, anywhere (decision 50, amending 35).** The original decision 35
wanted coins flagged ahead on the pacenote strip so a player could commit or decline
before reaching one; the user explicitly dropped that requirement. `CoinLayout` has
no notion of "ahead" — it hands back plain world positions — and nothing upstream
(pacenotes, HUD, any other UI) is told about a coin before the car is on top of it.
**Do not add a warning distance, a pacenote flag, or any other advance signal for
coins** — the cost (a first run meets a coin as a reaction, not a planned detour) is
accepted deliberately; see decision 50's own text before re-litigating it in code.

**Deterministic across a resume.** `world.gd._build_coins` seeds the planner with
`cfg.track_seed + COIN_SEED_OFFSET` — the SAME per-stage seed every other scattered
prop derives from (trees add `BUSH_SEED_OFFSET`/`ROCK_SEED_OFFSET` the same way).
`cfg.track_seed` comes from the drawn event's own authored `seed` field
(`StageConfig.apply_event_config`), and a resumed run redraws the identical event
from `RegionStagePool.draw(region_id, stage_count, run_seed)` — the persisted
`run_seed` never changes — so a resume reproduces byte-identical coins with no extra
bookkeeping. This is exactly the guarantee `TreeScatter`'s tree/bush/rock passes
already rely on; coins just add a fourth offset to the same seed.

## Pickup (CoinField)

Each coin is a small flat-lit disc (`CylinderMesh`, `ps1_models_lit.gdshader` —
mirrors `BarrierSection`'s material build), placed at the road-adjacent terrain
height plus `coin_hover_m`. **No physics body** — like `BushField`'s pass-through
bushes, a coin is a per-tick **proximity query**, not a collider, so it can vanish
the instant it's collected with no physics-frame lag and no risk of the car bogging
down on it.

`CoinField.find_pickups(car_xz, points, collected, radius)` is the pure core: which
not-yet-collected indices lie within `radius` of the car, by squared distance. Only
a handful of coins exist per stage, so this is a plain linear scan — no spatial grid
needed at that count (contrast `BushField`, which bins because there can be dozens
of bushes). `_physics_process` calls it every tick and, for each hit, marks the coin
collected, hides its mesh, plays the pickup chime (`Audio.play_beep`, pitched by
`coin_pickup_sfx_freq_hz`/`_duration_sec` — deliberately apart from the standard cue
default so it reads as its own sound), and emits `coin_collected(index,
total_collected)`. **One-shot, permanently** — unlike a bush, a spent coin never
re-arms; `collected` only ever gains bits.

**The pickup radius is read LIVE from `GameConfig.coin_pickup_radius_m` every
tick — `CoinField` never caches it.** That is what makes the `coin_magnet` perk
possible: the perk multiplies that one field through the effects funnel (decision 51,
wired in the pass after this stage — see `features/perks.md`), and a radius cached at
`build()` would leave it nothing to reach. `lucky_coins` works the same way one level
up, multiplying `GameConfig.coins_per_stage` before `coin_layout_params()` reads it —
which is why the count is fetched at build time from the config rather than passed
down from a caller. Neither perk is named anywhere in this file's code.

## HUD + audio

`hud.gd` carries a top-right `CoinLabel` (`set_coin_count(n)`), the mirror image of
the top-left speed/gear stack — hidden until first shown, change-gated like every
other HUD readout. It starts hidden in `_ready` and is revealed the first time
`world.gd._build_coins` calls `set_coin_count(0)` (i.e. only on a region-run stage
that actually placed coins); a challenge, or a region stage whose layout happened to
roll empty, never reveals it. This is a plain **direct call from world.gd**, not
routed through `StageManager`'s `_hud_can` capability gate — that gate exists for
methods `StageManager` itself calls, and `StageManager` never touches coins.

The pickup chime goes through the one legitimate path for a one-shot sound in this
project — `Audio.play_beep(frequency_hz, duration_sec)` (see
[sfx.md](sfx.md)) — called directly by `CoinField._collect`, not routed through
world.gd. `coin_pickup_sfx_freq_hz` defaults well above `sfx_beep_frequency_hz` (the
standard cue) specifically so a coin reads as a distinct, brighter cue rather than
the generic blip.

## Money + the lifetime ledger

**Banked at stage clear, never at pickup** (decision 36). `CoinField` only *counts*
coins as they're collected; `RunSession.report_event_result`'s third argument
(`coins_collected`, default `0` so every existing call site keeps compiling
unchanged) is what turns that count into anything durable, and it does two
DIFFERENT things with it:

- **`Save.add_lifetime_stat(LifetimeStats.COINS_COLLECTED, coins_collected)` —
  UNCONDITIONAL**, exactly like `DAMAGE_TAKEN` above it. A coin picked up on a stage
  that then missed its target was still a real detour the player drove; the lifetime
  counter is a driving-skill record, not a wallet, so it credits the attempt
  regardless of the stage's outcome.
- **The MONEY only banks when the stage was not missed** — `RegionRunMode
  .stage_money(stage_index, elapsed_ms, target_ms, coins_collected)` is only called
  inside `report_event_result`'s `if not missed:` branch, same as the rest of that
  stage's payout. This follows directly from decision 14 (a failed run keeps 100% of
  the money it earned) rather than being a separate rule: since decision 35 already
  makes the detour a gamble against the clock, losing the coin money too on a missed
  stage would punish the same gamble twice.

`stage_money`'s coin term is `coins_collected * GameConfig.coin_money`, added AFTER
`(completion + fast_bonus) * region_scale` rather than inside it — a coin is worth a
flat amount everywhere; the region scale's job (decision 31) is to make progressing
beat grinding on the *stage-clear* reward specifically, not on the collectable
gamble sitting on top of it. See [region-runs.md](region-runs.md) → *Money* for the
full formula in context.

## GameConfig — `@export_group("Roguelike Collectables")`

All of it is a plain tunable (CLAUDE.md — no test may pin a chosen value here):

| Field | What it controls |
| --- | --- |
| `coins_enabled` | Master switch, mirrors `signs_enabled`/`rocks_enabled` |
| `coins_per_stage` | How many `CoinLayout.plan` places (0-12) |
| `coin_offset_m` | Minimum lateral distance beyond the road edge — the decision-35 floor |
| `coin_offset_jitter_m` | Extra random spread on top of `coin_offset_m` |
| `coin_start_margin_m` / `coin_end_margin_m` | Arc-length kept clear of the start/finish |
| `coin_pickup_radius_m` | Pickup trigger radius — read LIVE by `CoinField`, the `coin_magnet` seam |
| `coin_money` | Money per coin, banked at stage clear |
| `coin_visual_radius_m` / `coin_visual_thickness_m` / `coin_hover_m` / `coin_color` | The disc mesh's look |
| `coin_pickup_sfx_freq_hz` / `coin_pickup_sfx_duration_sec` | The pickup chime |

`coin_layout_params()` bundles the placement fields for `CoinLayout.plan` (mirrors
`tree_params()`/`rock_params()`); `coin_render_params()` bundles the look/audio
fields for `CoinField.build` (mirrors `sign_render_params()`/
`barrier_render_params()`) — deliberately WITHOUT `coin_pickup_radius_m`, which
`CoinField` reads straight off `Config.data` instead of caching from a params dict.

## What this stage did not touch

- **Perk effects** (`coin_magnet`, `lucky_coins`) — wired in the pass immediately
  after this one (decision 51, `features/perks.md`). Nothing in `coin_field.gd` or
  `coin_layout.gd` mentions a perk even now: both perks land as multipliers on the two
  `GameConfig` fields this stage made sure stayed findable.
- **Signposting** — deliberately absent, not merely unbuilt. See decision 50 above.
