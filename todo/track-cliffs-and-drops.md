# Track cliffs & drops

**Status:** DONE / implemented. The cliff/drop height offsets are driven from
`GameConfig` (`scripts/game_config.gd`, `cliff_enabled`, `cliff_wavelength_m`,
etc.) through the terrain-height pipeline and documented in `features/terrain.md`.

Sculpt artificial **cliffs** and **drops** into the terrain along the sides of
the generated track, so a rally stage can run along a ledge — a wall rising on
one side, the ground falling away on the other — instead of over uniformly
rolling hills. The height/shape is driven by a 1-D noise signal along the
track, so it varies smoothly as you drive and needs no hand-authoring.

This is a **terrain-height feature**: it adds a per-vertex offset to the
existing height pipeline. It changes both the render mesh and the
`HeightMapShape3D` collision (they share the same height array), so the cliffs
and drops are real, drivable geometry.

## Read first

- [features/terrain.md](../features/terrain.md) — the chunked terrain, the road
  flatten (`road_heights` / `road_blend`), `bake_track`, `height_at`, the
  precomputed corridor, and the `DistantTerrain` backdrop.
- [features/track.md](../features/track.md) — the generated centerline, road
  width/transition band, `track_clearance`, hairpins.

## The model

Every terrain vertex height today (`scripts/terrain_chunk_builder.gd:108`,
`_vertex_row`) is:

```gdscript
h = noise_height(x, z)                                        # stacked Perlin layers
if road_blend.has(v): h = lerp(h, road_heights[v], road_blend[v])   # flatten under road
```

Cliffs add **one more term**, a signed offset that is zero under the road and
grows into a cross-slope beyond the shoulder:

```gdscript
h += cliff_offset[v]
```

The offset for a vertex is:

```
cliff_offset = side(d) · camber(s) · cliff_max_height_m · profile(|d|) · (1 − contested(v))
```

where, taken from the **nearest** centerline sample to the vertex:

- `s` — arc-length distance along the track to that nearest point.
- `d` — **signed** perpendicular distance from the centerline (sign = which side).
- `side(d)` — +1 on one side, −1 on the other (from the sign of the tangent ×
  offset cross product).
- `camber(s)` — the 1-D noise value in `[-1, 1]` (below).
- `profile(|d|)` — the cross-section shape: 0 under the road, up to 1, then back
  to 0 at the influence radius (below).
- `contested(v)` — the hairpin/loop-back flatten mask in `[0, 1]` (below).

Because `side` flips across the centerline and `camber` carries the sign, one
side rises by exactly what the other side falls — **"a cliff is always as tall
as the drop is deep"** falls out for free, and at `camber(s) = 0` the slice is
level. As `camber(s)` slides smoothly through zero along the track, a
left-cliff/right-drop becomes level becomes a right-cliff/left-drop with no
seam.

### The camber signal — `camber(s)`

A 1-D value in `[-1, 1]` sampled along the track's arc length `s`, from a
`FastNoiseLite` (`get_noise_1d`, or `get_noise_2d(s, 0)`), analogous to how
`TrackSurface.tarmac_weight(dist, …)` is a pure function of distance along the
track:

```
camber(s) = clamp(noise_1d(s / cliff_wavelength_m) · cliff_gain, -1, 1)
```

- `cliff_wavelength_m` — the along-track period; how quickly cliffs swap sides.
- `cliff_gain` — scales the raw noise before clamping. Higher gain → the signal
  spends more time saturated at ±1 (frequent full-height cliffs); lower gain →
  mostly gentle. The clamp is what makes `±1` a hard ceiling.
- Seed derives from `track_seed` (e.g. `track_seed` xor a constant) so the whole
  stage — track shape, surface split, cliffs — is one deterministic function of
  `track_seed`.

Evaluated directly per cliff-bake centerline sample (no stored 5 m table needed
— the bake already walks the centerline; cliffs can walk it coarser than the
road, see *Performance* → `CLIFF_SAMPLE_STEP_M`).

### The cross-section — `profile(|d|)`

A **localized** berm/ditch that returns to natural grade, *not* an infinite
shelf. As perpendicular distance `|d|` grows from the road:

```
inner  = track_width/2 + transition_m         # where the road has fully faded to grass — cliff starts HERE
rise   = inner + cliff_run_m                   # reaches full ±1 here
outer  = rise  + cliff_fade_m                  # back to 0 here = influence radius R

profile(|d|) = 0                               for |d| <= inner
             = smoothstep(inner, rise, |d|)     rising  (0 → 1)
             = 1 − smoothstep(rise, outer, |d|) falling (1 → 0)  (optionally hold a plateau first)
```

- **The cliff/drop does not begin until the road edge has fully met the grass.**
  `inner` is the **outer edge of the transition band** (`track_width/2 +
  transition_m`), *not* the road edge itself (`track_width/2`). Across the whole
  band — the flat road (`|d| ≤ track_width/2`) *and* the feathered grass↔road
  shoulder (`track_width/2 < |d| ≤ inner`) — `profile` is 0, so the offset is 0
  there. This matters: the road flatten (`road_blend`) ramps from 1 to 0 across
  exactly that band (`terrain_manager.gd:537`–`538`, `inner`/`outer`), so keeping
  the cliff at 0 until `inner` means the two never overlap — the feathered
  shoulder blends cleanly from flat road down to true terrain, *then* the cliff
  rises/falls beyond it. If the cliff started any earlier it would tilt the
  shoulder and lift/drop the road edge unevenly. (An optional extra flat margin
  before the cliff — `cliff_shoulder_m` added into `inner` — could push it out
  further, but the band edge is the minimum and the default.)
- `cliff_run_m` — horizontal run to full height. Small ⇒ steep (near-wall)
  cliffs; large ⇒ gentle banks. Note the terrain is a **heightfield → no true
  overhangs**; a "cliff" is a very steep slope.
- `cliff_fade_m` — run back to grade, so the feature is a wall/berm that comes
  back down (cliff side) or a ditch/gully you fall into that comes back up (drop
  side).

**Why fade to zero** — three payoffs:
1. Vertices past `R` get offset 0, computed for free (bounded work).
2. `height_at` past `R` is plain noise again, so the `DistantTerrain` backdrop
   matches automatically — **no seam, and no need for a pure `cliff_offset_at`
   fallback** (contrast the road flatten, which has none outside the corridor
   anyway).
3. It keeps the whole feature inside the play area. The off-track reset leash is
   `track_progress_max_dist_m` (default **25 m**, `game_config.gd:855`), so
   `R = inner + cliff_run_m + cliff_fade_m` sits comfortably within it. The
   meaningful cliff/drop action happens within ~the leash; the fade beyond is
   rarely seen because the car resets at 25 m lateral.

   **Invariant — `R` must fade out inside the cached corridor.** The offset is
   only baked for stamped vertices; the pure-noise fallback (backdrop/editor) has
   no cliffs. So the offset MUST reach 0 before the outermost corridor chunks, or
   there's a step where cliff terrain meets the flat backdrop. `corridor_coords`
   dilates the centerline by `RADIUS + ceil(leash_m/CHUNK_M) + 1` chunks
   (`terrain_manager.gd:428`) — **~150 m at the default 25 m leash**, so any sane
   `R` (tens of metres) is safe. But if cliff params ever push `R` beyond that
   margin, either clamp `R` or widen the corridor dilation to
   `max(leash-derived, R)`. Worth an `assert`/`push_warning` when `R` exceeds the
   corridor margin.

`smooth_ramp(d, inner, outer)` already exists for the road band
(`scripts/terrain_manager.gd`) — reuse the same smoothstep style for the two
halves of the profile.

### The contested-vertex flatten — `contested(v)`

The tricky case is the **inside crook of a hairpin** (or anywhere the road
wraps back near itself). A plain nearest-point lookup would put a hard sign-flip
seam there (the two arms disagree on which side is the cliff), and even if they
*agree* it would fill the crook with a nonsensical raised wedge. We want the
crook to just go **flat**.

Detection is **geometric, not by track piece** — a hairpin is one *continuous*
section (its arc-length runs smoothly through the apex, no gap), so an
"is this a different piece?" test misses exactly the case we care about. Instead
measure whether the road **wraps around** the vertex:

- For each vertex, over all in-range centerline samples, take the **bearings**
  (vertex → sample directions).
- **Straight / gentle or tight bend, outside of the curve:** all road is on one
  side → bearings stay within a half-plane (span ≤ 180°) → keep the cliff.
- **Inside crook of a hairpin / any pocket the road wraps around:** road is
  ahead, left and right → bearings span **> 180°** → flatten.

This cleanly separates the cases: the **outside** of a bend keeps its cliff/drop
(a bend *should* be able to have a drop on its outer edge), the **inside crook**
goes flat. It also catches genuine loop-backs (road on two sides → > 180°) for
free. Because `R` is finite, a straight's bearing span stays safely under 180°,
so it never false-fires.

**Feather it** — a boolean flag would trade the wedge seam for a step seam. Let
the span past 180° drive `contested(v)` continuously in `[0, 1]` (0 at ≤ 180°,
ramping to 1 as it approaches the full wrap, e.g. via a configurable
`cliff_pinch_angle_deg` band), and the `(1 − contested)` factor tapers the cliff
smoothly to flat as you near the crook.

`track_clearance` (`game_config.gd`, the Track group) already forces *separate*
track pieces apart, so with a modest `R` the only place the wrap test ever fires
is a single tight corner's own arms — which is exactly what we want.

## Where it plugs in

### Bake — extend `bake_track` (`scripts/terrain_manager.gd:530`)

`bake_track` already walks the tessellated centerline and, at each sample,
stamps a block of `reach` cells, keeping each vertex's **nearest** sample
(`v_best` bookkeeping, lines 564–582). Extend that same single pass:

1. Widen the stamped block for cliff vertices to `reach_cliff = ceil(R / CELL_M) + 1`
   (larger than the road `reach`).
2. At each sample compute the tangent (`b - a` of the current polyline segment,
   lines 549–550) and the arc-length `s` (`dist_m + t·seg_len`, already tracked
   for the tarmac split, lines 547–559) → `camber(s)`.
3. Per stamped vertex, using the **nearest** sample, compute signed `d`, `side`,
   `profile(|d|)`, and write `cliff_base[v] = side · camber(s) · profile(|d|)`
   into a new field (keyed in the same **global vertex index** space as
   `road_heights`, i.e. `Vector2i(roundi(p.x/CELL_M)+dx, …)` — see
   `terrain_chunk_builder.gd:127`).
4. In the **same** pass, accumulate per-vertex **bearing bookkeeping** so the
   wrap span is known at the end. ⚠️ **Bearings are circular** — do NOT use
   `min`/`max` of the angle (a cluster straddling 0°/360° would falsely read as a
   near-full span). Use a fixed set of angular **buckets** (e.g. 16 bins over the
   circle) per stamped vertex: each stamping sample sets the bucket for its
   `atan2(sample − vertex)` bearing. This is a set union → naturally
   **order-independent**. At the end, the wrap span = `360° − largest empty arc`
   (largest run of consecutive unset buckets), which is the robust circular span.
5. After the walk, fold the wrap span into `contested[v]` (0 for span ≤ 180°,
   ramping to 1 across `cliff_pinch_angle_deg` past 180°) and store the final
   `cliff_offsets[v] = cliff_base[v] · (1 − contested[v]) · cliff_max_height_m · cliff_amount`.

   The bucket bookkeeping is a transient dict over the stamped band, freed after
   the bake (a few bytes/vertex; sized like `cliff_base`, larger than the road
   `v_best` because the band is wider — measure alongside the cache, below).

New manager fields, alongside `road_heights` / `road_blend`
(`scripts/terrain_manager.gd:49`):

```gdscript
var cliff_offsets: Dictionary = {}   # global vertex index (Vector2i) -> signed height offset (m)
```

Gated on `cliff_enabled` — when off, `bake_track` skips the whole cliff pass and
`cliff_offsets` stays empty (identity behaviour, zero cost).

Plumb the cliff params from config into `set_track` /
`bake_track` the same way surface args are threaded (`world.gd:236`,
`terrain_manager.gd:530`,`:594`) — or read them off a small `GameConfig`
accessor to avoid a long arg list (see `road_marking_params()` precedent).

### Apply — `_vertex_row` (`scripts/terrain_chunk_builder.gd:126`)

After the road-flatten `lerp` (lines 128–129), before storing the height:

```gdscript
if _m.cliff_offsets.has(vidx):
    h += _m.cliff_offsets[vidx]
_heights[idx] = h
_vertices[idx] = Vector3(lx, h, lz)
```

`_heights` feeds both the render mesh and the `HeightMapShape3D` collision, so
the cliffs are collidable with no extra work.

### `height_at`, cache, backdrop

- Inside the corridor, `height_at` / spot samples are **cache-first**
  (`_cached_height_at` bilinear-samples the baked chunk heights), so car physics,
  reset, and scatter placement all get the cliffs for free.
- Outside the corridor (backdrop, editor, tests without a precompute), the
  offset is 0 by construction (past `R`), so the pure `_noise_height_at`
  fallback already matches — **no changes to the fallback path**.

## Lighting the cliffs (don't miss this)

The baked terrain light takes its normal from the **pre-flatten pure-height
halo** `_ph` (`terrain_chunk_builder.gd:100`, `_light_from_neighbours` fed from
`_halo_row`). If the cliff offset is added to `_heights` but **not** reflected in
the lighting normal, steep cliffs will be lit as if flat — they won't read as
cliffs. To make them shade correctly, the light-normal source must include the
cliff offset: derive the normal from **noise + cliff_offset**, sampling
`cliff_offset` over the `SAMPLES+2` halo grid vertices too (they're grid
vertices, so the same `cliff_offsets` lookup works). Note the road flatten stays
**excluded** from the light normal (as it is today — the near-flat road is
deliberately ignored so seams stay consistent), so the normal is
`noise + cliff`, *not* the fully-flattened render height. This is extra bake
cost — flag it and measure. **Decision to confirm:** shade the cliffs properly
(recommended — the whole point is that they're visible) vs. accept flat-lit
cliffs for cheaper bakes.

## Gameplay & reset interaction

- Drops are real: the car can fall off an edge / tumble into a ditch. Within the
  25 m leash it won't instantly reset, so it tumbles; only once it strays past
  the leash does `TrackProgress` snap it back
  ([features/progress.md](../features/progress.md)). Confirm this feels right and
  the reset doesn't fight the drops (tune `R` vs. the leash).
- Scatter (trees, bushes, signs, spectators) samples `height_at`, so props sit
  on the cliffs/plateaus for free — usually a plus; steep faces may get trees on
  them, revisit if it looks wrong.
- Road markings sit `road_marking_height_m` above the road surface via
  `terrain.height_at()` at the centerline, where the offset is 0 — unaffected.

## Edge cases & interactions

- **Track start / finish ends.** For a vertex beyond the first/last centerline
  point, the "nearest point" is the endpoint and the perpendicular `d` degrades
  into a radial distance with an ill-defined side across the centerline's
  extension — cliffs would wrap oddly around the ends. In practice the start has
  a straight lead-in and the finish a runoff ([features/track.md](../features/track.md)),
  so the ends are buried in flat lead-in road; still, decide whether to taper the
  cliff to 0 over the last few metres of `s` (a `camber` fade near both ends) so
  the start line and finish arch sit on clean ground.
- **Collision resolution limits steepness.** Collision is a `HeightMapShape3D` on
  the 1 m height grid, so a near-vertical wall is a 1 m staircase and a very steep
  face reads blocky (on-brand for PS1, but it bounds how sheer `cliff_run_m` can
  usefully go). Keep `cliff_run_m` ≳ a couple of cells for drivable banks; accept
  the staircase for walls meant only to block.
- **Signs & spectators.** Roadside signs ([features/signs.md](../features/signs.md))
  and crowds ([features/spectators.md](../features/spectators.md)) are placed at a
  lateral offset from the centerline and sample `height_at`. If their offset lands
  *inside* `inner` (the flat band) they sit on flat ground — ideal. If it lands on
  the cliff/drop, a sign could tilt on a slope or a crowd stand in a ditch. Check
  their placement offsets against `inner`; if needed, clamp roadside props to the
  flat band or the cliff-side only.
- **Editor preview.** `TerrainManager` is `@tool` and previews with no track, so
  `bake_track` (and the cliff pass) doesn't run — the editor shows bare rolling
  terrain, same as it does for the road today. Expected, not a bug.

## Configuration

New `Cliffs` group in `GameConfig` (`scripts/game_config.gd`, after the Track /
Road Markings groups) + `config/game_config.tres`:

| Field | Meaning |
|-------|---------|
| `cliff_enabled` (bool) | Master toggle; off ⇒ bake skips the cliff pass entirely |
| `cliff_wavelength_m` (float) | Along-track period of the camber noise (**global** — same for every event) |
| `cliff_gain` (float) | Noise → camber scale before the `[-1,1]` clamp (higher = more full cliffs) |
| `cliff_max_height_m` (float) | **Global ceiling**: the height at `\|camber\|=1` for a maximally cliffy event (`cliffiness=1`). Equals the drop depth. Scaled down per event (below). |
| `cliff_run_m` (float) | Horizontal run road-edge → full height (small = steep) |
| `cliff_fade_m` (float) | Horizontal run full height → back to grade |
| `cliff_pinch_angle_deg` (float) | Bearing-span band past 180° over which `contested` ramps 0→1 |
| `cliff_amount` (float, `[0,1]`) | Runtime per-event scale on `cliff_max_height_m`. Written by `RallySession` from the event's `cliffiness`; the value shipped in `game_config.tres` is only the fallback for standalone/editor `main.tscn` runs. |

All are tunables → **not** asserted in tests (per CLAUDE.md — test the logic, not
the values).

## Per-event cliffiness

Each rally **event** defines *how cliffy* its stage is — the highest highs and
lowest lows — while the noise **wavelength stays global** (`cliff_wavelength_m`).
This mirrors the existing per-event knobs (`straightness`, `surface_mix`,
`forestiness`, `width`) authored in the `RALLIES` event dicts
(`scripts/rally_library.gd:85`+) and read through `event_*` accessors
(`rally_library.gd:208`–`233`).

- Add a `"cliffiness"` key to every event dict in `RALLIES` (in `[0, 1]`).
- New accessor, alongside the others:

  ```gdscript
  # How cliffy this event's stage is, in [0, 1]: 0 = flat (no cliffs/drops),
  # 1 = the tallest cliffs/deepest drops (cliff_max_height_m). Scales the global
  # height ceiling; the noise wavelength is global. Default 0 keeps an event that
  # omits it flat.
  static func event_cliffiness(event: Dictionary) -> float:
      return clampf(float(event.get("cliffiness", 0.0)), 0.0, 1.0)
  ```

- `RallySession._load_event_scene` (`rally_session.gd:487`–`492`) writes it into
  `Config.data` before the scene loads, exactly like the others:

  ```gdscript
  cfg.cliff_amount = RallyLibrary.event_cliffiness(event)   # [0,1], scales cliff_max_height_m
  ```

  The bake then uses an **effective** max height of
  `cliff_max_height_m · cliff_amount`. (`cliff_amount` is the runtime
  per-event field on `GameConfig`; `cliff_max_height_m` is the authored global
  ceiling. Editor/standalone `main.tscn` runs — no `RallySession` — use whatever
  `cliff_amount` ships in `game_config.tres`.)

- **Balance intent** (not tested — designer territory): earlier/lower-tier events
  stay tamer; later or mountain-flavoured events crank it up. Author the values
  in `RALLIES` to taste.

- **Target times are unaffected.** Cliffs don't change the centerline, its
  length, or the flat lengthwise road profile, so `LapTimeModel` /
  `RallySession._compute_event_targets` and the opponent field do **not** take
  cliffiness (contrast `straightness` / `width` / `surface_mix`, which change the
  shape or grip and *do* feed the target path, e.g. `lap_time_model.gd:130`).
  This means cliffiness only has to reach the scene load — one write in
  `_load_event_scene` — and nothing in the sync-sensitive target derivation.
  Still, double-check nothing that bakes the corridor for target derivation
  reads it.

## Performance

- The cliff bake reuses the single `bake_track` centerline walk; the added cost
  is the wider stamp block (`reach_cliff` vs. road `reach`) and the per-vertex
  bearing bookkeeping. It runs once behind the "Precomputing terrain…" loading
  stage (`world.gd:246`), batched per frame like the rest — no runtime hot-path
  cost.
- Keep `R` modest (bounded by the ~25 m leash anyway) so the stamped band and
  the extra vertices stay in check. Measure the precompute time/MB delta against
  the baseline in [features/terrain.md](../features/terrain.md) ("204 chunks,
  46.2 MB") and the `./run_benchmark.sh` `compute_chunk_data` timing; if the bake
  regresses noticeably, cap `reach_cliff`.
- **Coarser along-track sampling for the cliff pass.** The road bake walks the
  centerline at `ROAD_SAMPLE_STEP_M = 0.25 m` (`terrain_manager.gd:15`) for a
  crisp road edge. Cliffs don't need that density — `camber(s)` varies over
  `cliff_wavelength_m` (metres+) and the mesh is 1 m cells — so run the cliff
  stamp on a separate coarser `CLIFF_SAMPLE_STEP_M` (~1 m). With a stamp block
  ~10–20× wider than the road's, that ~4× fewer samples is the main cost lever.
  If the cliff pass shares the road walk rather than running its own, sub-sample
  it (only do cliff work every Nth road sample).
- **`cliff_offsets` dict memory.** It persists on the manager for the level (read
  when chunks build/rebuild lazily), keyed per vertex over the *wide* band — so
  it's bigger than `road_heights` (narrow band). Rough order: band area ÷ 1 m²
  × dict overhead. Include it in the cache-size measurement; if it's heavy,
  consider packing offsets into the cached chunk data instead of a standalone
  dict.

## Tests (`tests/headless/`)

Logic/behaviour only — never pin a tuned value. Build against a **synthetic
straight and a synthetic hairpin `Curve2D`** with cliff params set on a stub
`TerrainManager` (no real `CarLibrary`/catalogue, no full-world generation where
avoidable — use `SceneTestHelpers.minimal_world()` / bare `bake_track` calls):

- **Zero when off/level:** `cliff_enabled=false`, or `cliff_max_height_m=0`, or a
  camber that is 0 ⇒ `cliff_offsets` empty / all zero, and `height_at` equals the
  no-cliff height.
- **Flat road surface + clean shoulder handoff:** offset is 0 for every vertex
  within `track_width/2 + transition_m` of the centerline — i.e. across the flat
  road *and* the full feathered transition band, so the shoulder isn't tilted and
  the cliff only begins where the road has fully met the grass. (Assert against
  the band-edge distance, a derived geometric quantity, not a pinned value.)
- **Antisymmetry:** for a straight, `offset(+d) ≈ −offset(−d)` at matching
  perpendicular distances (cliff as tall as the drop is deep).
- **Bounded:** `|offset| ≤ cliff_max_height_m` everywhere.
- **Fades out:** offset is 0 beyond `R`, so `height_at` past `R` equals the
  pure-noise height (backdrop continuity).
- **Hairpin crook flattens:** on a synthetic hairpin, inside-crook vertices
  (road wraps > 180° around them) have offset ≈ 0, while outside-edge vertices do
  not — and the transition is continuous (no step), not a hard cut.
- **Determinism:** same `track_seed` ⇒ identical `cliff_offsets`.
- **Cache parity:** a cached chunk's heights match a fresh `compute_chunk_data`
  with cliffs on (extend `test_cached_chunk_data_matches_fresh_compute`).
- **Seam continuity:** with cliffs on, adjacent chunks still agree on their
  shared-edge heights (extend the existing seam test in `test_terrain.gd`). This
  holds by construction because `cliff_offsets` is keyed by **global** vertex
  index, but it's the invariant most likely to break under a refactor.
- **Per-event scaling (logic, not values):** `event_cliffiness` clamps to
  `[0, 1]` and defaults to 0 when omitted; `cliff_amount = 0` ⇒ offsets all
  zero regardless of `cliff_max_height_m`. Do **not** assert any authored
  `cliffiness` value or ordering across events (moving balance number — CLAUDE.md).
  A `test_rally_library` accessor case (clamp + default) is fine, matching the
  existing `event_*` coverage.

Add a scene/structure check to `test_smoke.gd` only if a new node/material is
introduced (none expected — this is pure height data).

**Manual check (visual feature — don't ship on tests alone):** run a stage with
`cliff_amount` cranked up (`/run`, or set it in `game_config.tres`) and eyeball
it — cliffs read as cliffs, hairpin crooks are flat, the road edge is
undisturbed, and there's no seam where the detail terrain meets the backdrop.

## Docs to update (same piece of work)

- [features/terrain.md](../features/terrain.md) — the new `cliff_offsets` field,
  the `bake_track` cliff pass, the `_vertex_row` term, the lighting-normal note,
  and the `Cliffs` config group.
- [features/track.md](../features/track.md) — cliffs/drops as a track-side
  feature and the hairpin-flatten behaviour.
- [features/configuration.md](../features/configuration.md) — the `Cliffs` group
  tunables + the runtime `cliff_amount` per-event field.
- [features/rally-roster.md](../features/rally-roster.md) — the new
  `event_cliffiness` accessor and the `cliffiness` authored key on events.

## Decisions settled during design

- **Localized berm/ditch that fades to grade**, not a permanent cross-slope
  shelf — bounds work, removes the backdrop seam, keeps the feature in the play
  area. (Flip to a shelf only if a true never-ending-ledge look is wanted; that
  reintroduces the backdrop-seam and needs a pure `cliff_offset_at` fallback.)
- **Nearest-point lookup + feathered contested-flatten**, *not* normalized
  accumulation — accumulation would fill an agreeing hairpin crook with a raised
  wedge; the wrap-around flatten makes the crook go flat as intended.
- **Additive offset** on top of the natural noise (hills roll through the
  cliffs), matching "adjust each vertex accordingly".

## Open questions to confirm before/while implementing

1. **Cliff lighting:** shade cliffs via the offset-aware halo (recommended) vs.
   accept flat-lit cliffs for a cheaper bake? (See *Lighting the cliffs*.)
2. **Steepness:** target `cliff_run_m` — sheer near-walls vs. rideable banks?
3. **Reset feel:** does falling into a drop within the 25 m leash play well, or
   should `R` / the leash be retuned so drops are catchable but not reset-fighty?
