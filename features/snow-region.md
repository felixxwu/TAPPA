# The snow region (The Alps)

The map's NE corner, filled in after being reserved from the start. It is the one
region that does more than look different: it is the first to influence **handling**.

**Tests:** `tests/headless/test_snow_region.gd`, `tests/headless/test_deep_snow_drag.gd`, `tests/headless/test_lake_field.gd`

- **Region entry:** `scripts/region_library.gd` → `REGIONS` id `"snow"`
- **Handling seat:** `RallySession.apply_event_config`
- **Grip:** `Drivetrain.surface_tire_params`, `LapTimeModel._surface_grip`
- **Deep snow:** `shaders/ps1_terrain_snow.gdshader`, `WorldRuntime.apply_deep_snow`
  (via `world.gd._apply_deep_snow_ground` / the same wrapper in `overworld.gd`),
  `car.gd._apply_deep_snow_drag`
- **Frozen lakes:** `LakeField.build` / `_add_ice_collider`
- **Snowfall:** `WeatherLibrary` id `"snow"`, `WeatherField.spawn_snow`
- **Rallies:** the six `region: "snow"` entries in `RallyLibrary.RALLIES`
- **Art:** `tools/gen_snow_textures.py` (ground/sky), `tools/gen_snow_trees.py` (conifers)
- **Design:** `docs/superpowers/specs/2026-08-16-snow-region-design.md`

## Four mechanisms, in rising order of novelty

1. **The look** is pure existing machinery — `LOOK_KEYS` only, no code.
2. **Snowfall** is one `WeatherLibrary` entry plus one particle kind.
3. **Grip** is the new axis: a region may now override per-surface μ.
4. **Deep snow and frozen lakes** are the genuinely new mechanics.

## Grip is a region property, not a weather one

The corner is a deliberate **mix of dry and snow stages**, and a *dry* alpine stage must
still be slippery — the ground is frozen whether or not anything is falling on it.
Weather is per-event; "this corner is frozen" is per-region. Routing grip through
`WeatherLibrary` would have forced every Alps event to carry `weather: "snow"`, throwing
away the variety the region exists to provide.

**Nor is ice a new surface type.** There is no surface enum: `TerrainManager.surface_at`
returns continuous weights (road 0..1, tarmac 0..1) and `Drivetrain._surface_blend`
resolves them over exactly three configured values. "Snow gravel" and "snow tarmac" are
not new types, they are those same endpoints wanting **different μ**. Adding real types
would have meant a third weight axis through `surface_at`, the blend, `tire_marks`,
`wheel_particles`, `road_markings`, `barrier_layout`, `lap_time_model`, `ghost_car` and
`car_performance` — and bought nothing, since snow-gravel and ordinary gravel never
coexist on a stage.

### The config-block indirection

A region **names GameConfig fields**; it never authors numbers. Same pattern as
`WeatherLibrary`, so all tuning stays in `config/game_config.tres`:

```gdscript
"surface_grip": {"grass": "snow_grass_grip", "gravel": "snow_gravel_grip",
                 "tarmac": "snow_tarmac_grip"},
"deep_snow":    {"depth": "snow_visual_depth_m", "drag": "snow_deep_drag"},
"frozen_water": {"grip": "ice_grip"},
```

All three are **outside `LOOK_KEYS`**, for the reason `water_level` is: they are consumed
at stage setup, not by `world.gd`'s look pass after generation. `look_from` inheritance
does not extend to them.

API mirrors `has_water_level` / `water_level_of` — a `has_*` / `*_of` **pair**, so a
caller cannot mistake "authors nothing" for a real value in a language with no null:
`has_surface_grip` / `surface_grip_of`, `has_deep_snow` / `deep_snow_of`,
`has_frozen_water` / `frozen_water_of`.

`_resolve_fields` returns values **un-coerced**. An earlier version wrapped them in
`float()` and crashed rally start with `Nonexistent 'float' constructor` the moment a
block named a `Color`. It also warns when a block names a field `GameConfig` does not
have, instead of silently yielding 0.0 — which would read as "no grip at all".

### Seating it

`RallySession.apply_event_config` resolves the region off `event["region"]`, which
`RallySession` already seats (lines 665 / 1001) for `TrackGenParams.resolve_water_level`
— so **no signature change was needed**. Because that function reloads the authored
baseline and pins every omitted field to it, a session-less caller (free roam, benchmark,
dev boot) and every non-snow rally get baseline grip and a zero deep-snow block
automatically, and one stage's slippery override cannot leak into the next.

`hq.gd._prepare_free_roam` draws its random region **before** calling the funnel and seats
it on the event, so a free-roam Alps stage drives like snow instead of looking like snow
and driving like a summer forest.

### The AI field scales with it — snow is variety, not difficulty

`LapTimeModel._surface_grip` reads the same live `gravel_grip` / `tarmac_grip`, so once
the funnel has seated them **the rival field scales for free, with no change to the
lap-time model**. A snow stage is no harder to podium; it changes how the car must be
driven. Consistent with rain and sandstorm, deliberately unlike fog. `ghost_car.gd`
computes μ the same way, so the windscreen ghost stays consistent too.

**`CarPerformance` is unaffected by construction** — it benchmarks at a frozen
`BENCHMARK_SURFACE_GRIP`, so car ratings, the rating-matched field and adaptive difficulty
cannot drift. Worth stating, because a grip change that *did* reach the rating would
silently re-pitch every field in the game.

### The region override is no longer the only snow lever

Seating `snow_*_grip` scales the ground for every car equally, which is what makes snow
*variety*. What the player brings now matters too: the **tyre compound is
surface-specialised** ([drivetrain-and-tires.md](drivetrain-and-tires.md) → *Surface-specialised
compounds*), and Snow Tires buy a real bonus on snow ground for a penalty on tarmac — so
fitting winter rubber before an Alps event, and taking it off again for an asphalt stage,
is a genuine per-rally decision rather than a one-way upgrade. The snow side of the rule is
keyed off `GameConfig.ground_is_snow()`, which is simply `deep_snow_depth_m > 0.0` — i.e.
"this region seated a deep-snow block", so there is no second snow flag to keep in sync.
The AI field tracks it: `LapTimeModel._surface_grip` runs the same
`GameConfig.tire_surface_mult_for`, off the rival's own meta.

## Relief: deliberately gentle

The Alps are authored **flat for their altitude** — `terrain_layer1_amplitude` 14-18, the
flattest band on the map, under its highest ground, where the eastern foothills run 34-44.
This is the one place the roster's "high ground is hilly" rule is broken on purpose.

Relief and grip MULTIPLY. A climb costs a fixed `G*sin(theta)`, subtracted from a drive
budget that this region's grip has already shrunk: on snow road grip a FWD car tops out
around a 22% grade and a RWD car around 33%. The corner first shipped at ~34-52, whose
steepest pitches measured 31-38% — at or past that ceiling, so the car sat and spun while
the field drove away. At 14-18 the steepest pitch on any Alps stage is 19.2% and the RMS
gradient roughly halved (9-17% -> 5.3-8.1%), leaving most of the drive budget for actually
accelerating. For scale, the rest of the map has a median worst pitch of 19.2% and reaches
32.2% — so the Alps' WORST hill is now the median hill everywhere else.

Altitude is carried by **`cliffiness` (0.7-1.0, the highest on the map)** instead. Cliffs
drop the ground away BESIDE the road without touching the lengthwise profile the car has
to climb, so the corner still reads as a high massif while staying drivable. If the Alps
ever need more drama, reach for cliffiness, not amplitude.

Consequence worth knowing: less relief means fewer deep hollows for the waterline to fill,
so **frozen lakes are rarer here than they were**. The waterlines were left at -12/-13
(the "up in the foothills" rung of the roster's ladder) rather than raised to chase the
ice back, because a high sea over low relief floods the track — the pairing constraint in
[rally-roster.md](rally-roster.md).

The Alps also feel the lap-time model's **road gradient** term more than anywhere else
(see [rally-roster.md](rally-roster.md) -> the QSS model). `G*sin(theta)` is a fixed
subtraction from a drive budget that low grip has already shrunk, so 14 of the region's
18 stages get slower once hills are modelled, up to about +2%. That term exists precisely
so the rival field pays for a climb the player is paying for; before it, a 2WD car
scrabbling up an icy opening straight watched a ghost that had no weight walk away.

Residual: the deep-snow drag is **player-only** (no drag term exists in the lap-time
model, and a rival never leaves the road), so the corner is slightly harder in practice
than a matched field implies — the same asymmetry storm's crosswind has. Mild, named, and
a fraction of fog's, since the dominant effect *is* scaled.

Off-road wheel spray is square here, not blade-shaped: the region authors
`grass_particle_square` (see [wheel-dust.md](wheel-dust.md)). Colouring the grass blade
white was not enough — a snowfield throws clods of powder, and the slim tall sliver read
as white grass being torn up.

## Deep snow

Two effects doing two different jobs: low μ makes the car **slide**, drag makes it
**bog**. Neither alone reads as deep snow.

### The sink — a separate shader, not a uniform

`shaders/ps1_terrain_snow.gdshader` is `ps1_models.gdshader` plus one vertex stage:

```glsl
VERTEX.y += snow_depth * (1.0 - (blend_road ? COLOR.a : 0.0));
```

`COLOR.a` is the baked road weight the fragment stage already blends with, so the road is
never lifted and the existing smoothstep feather turns the step into a ramp — which reads
as a plough bank at the verge. Collision is a separate `HeightMapShape3D` and is
untouched, so the wheels rest at true ground level and the car sits *in* the snow.

**Why a variant shader.** `ps1_models` is the shared terrain shader, terrain is the
heaviest geometry in the game, and this renderer targets low-end phones — so it is
deliberately kept free of any vertex stage, enforced by
`test_render_smoke.gd::test_terrain_shader_has_no_vertex_stage`. The established answer
here is a variant, exactly what `ps1_models_lit.gdshader` already is for the car. Only
snow stages pay. **Keep the two fragment stages in sync.**

It is also not done in `terrain_chunk_builder`: chunk data is cached with a prebuilt
`HeightMapShape3D`, so a region-dependent vertex offset would have to be keyed into that
cache and agree across every LOD subsample.

⚠️ `world.gd._apply_deep_snow_ground` → `WorldRuntime.apply_deep_snow`
(`scripts/world_runtime.gd`, shared with `overworld.gd`) runs **unconditionally every stage boot**, including
the else-branch that restores the base shader. The floor material is a shared
sub-resource of `main.tscn` with no `resource_local_to_scene`, so it survives every scene
instantiation in the process — the same trap that once left the ground at
`rain_road_darken²`. Without the restore, one snow stage would leave every later stage's
ground floating.

**Accepted cost:** props (trees, signs, spectators, barriers) are placed from collision
heights, so off-road they sit buried by `snow_depth`. Correct-looking for trees, shin-deep
for spectators, and tunable with the one value. Lifting props to the visual surface would
cost a second height query each and get barriers wrong (a barrier must sit where the car
actually hits it).

### The bog

`car.gd._apply_deep_snow_drag`, alongside the lake soft hazard, feathered on the same road
weight the visual raise uses so the bog appears exactly where the snow is drawn rising.
`cfg.deep_snow_drag` is `0.0` elsewhere, so the cost off a snow stage is one float compare.

**It is applied PER WHEEL, not as one central force.** Each grounded contact is dragged by
how buried *that* corner is, and the force is applied *at* that contact — so clipping a
drift with one side produces a real yaw torque that pulls the nose round, which a central
force could never express however lopsided the snow was.

The rule itself is `Drivetrain.deep_snow_force` (pure + static; it lives there rather than
on `car.gd`, which has no `class_name`, so it is testable without a physics scene). Three
things about it are load-bearing:

- **The velocity damped is the velocity at the CONTACT POINT** (`linear + angular × offset`),
  not the chassis centre's. That is what makes it genuinely per-tyre: a car already
  slewing has its rotation damped too, so deep snow both starts a slide and eventually
  arrests it rather than spinning it forever.
- **The coefficient is divided by the WHEEL COUNT**, so with all four wheels equally buried
  the total is identical to the single central force this replaced — `snow_deep_drag`
  keeps its meaning and needed no re-tuning. Dividing by the number of *live* contacts
  would be wrong: lifting a wheel would make the remaining ones bog harder.
- **No new terrain queries.** Each contact already carries the road weight
  `surface_tire_params` sampled for it (`Drivetrain.WheelContact.road_weight`), so this
  reads what the tyre solver has already paid for. Airborne wheels have no contact and so
  cannot bog, which is correct; a contact **on the ice** reports road weight `1.0`, because
  a frozen lake is something you slide on rather than bog in.

Tested in `tests/headless/test_deep_snow_drag.gd` (the force rule: feather, magnitude
conservation, left/right yaw symmetry, spin damping) and `test_drivetrain.gd` (that the
road weight is actually reported, including the no-terrain and ice branches).

## Frozen lakes

In the Alps the lake is **solid** and driven on, not the soft drag hazard it is elsewhere.

`LakeField._add_ice_collider` adds a **`WorldBoundaryShape3D`** — an infinite half-space
plane at the waterline. There is no lake geometry in this game (one plane, terrain
occludes it by depth test), so there is no outline to match; an infinite plane gives the
right answer anyway, because the terrain collider is still there. Above the waterline the
car rests on ground; where terrain dips below — exactly where a lake is drawn — it rests
on the ice. The two colliders reproduce the lake's shape for free, and it is the cheapest
collider physics has.

- **Grip** overrides the surface blend in `Drivetrain.surface_tire_params` rather than
  scaling it: what is under the ice is irrelevant. Gated on `frozen_water_grip > 0.0`, so
  elsewhere it is one float compare on a hot path. It uses the same cache-first height
  query the collider is positioned against, so the grip boundary and the solid surface
  agree exactly. The fitted tyre's surface term is still applied on top, and a frozen lake
  takes the **snow** side of that rule (see below) — a lake is only ever authored by a
  snowy region, so winter rubber is exactly what should pay off out on the ice.
- **The water-drag query is not wired** on a frozen stage — dragging a car down on a
  surface it is meant to slide across is the opposite of the feature.
- **Look** reuses the water shader with ice colours and `scroll_speed = 0`. Ice does not
  flow, and stopping the scroll is what separates it from water at a glance. No second
  shader.
- Accepted side effect: nothing can fall below the waterline on a frozen stage. On these
  stages that reads as landing on ice.

The track still routes around water, so the frozen lake is an off-road hazard (or
shortcut), and rival times are unaffected.

## Snowfall

One `WeatherLibrary` entry naming a `snowfall_*` config block — prefixed that way so it
cannot collide with the region's `snow_*_grip` fields, the same reason fog's are `mist_*`.

It **authors no `grip_mult`**. The region already owns grip in this corner; a weather
multiplier on top would be a second, redundant lever over the same variable and would make
a snowfall stage arbitrarily slipperier than a dry stage on the same frozen ground. It
therefore names nothing in `physics_fields` and never re-keys the opponent cache — correct,
since it changes no lap time.

`road_tint.color` already generalises to a lerp toward a colour (sandstorm's mechanism), so
snow settling white on the road needed no `world.gd` change. The one code addition is
`WeatherField.spawn_snow`: slow fall, wide spread, small near-square quads, and
`BILLBOARD_ENABLED` rather than the velocity-aligned billboarding the other kinds use —
streaking a flake to its own motion is exactly what makes cheap snow look like rain.

## Art

Generated by two committed tools so it can be re-rolled rather than hand-painted once.

`tools/gen_snow_textures.py` — snow ground, packed-snow road, overcast sky. The ground
tiles are deliberately **not** flat white: the renderer is unshaded with baked vertex
lighting, so a dead-flat albedo has no form at all.

`tools/gen_snow_trees.py` — the two conifers, cut from a **CC0** pack ("high-res tree
textures" by rubberduck, OpenGameArt; public domain, no attribution needed, no credits
entry). Photographic on purpose: the game's existing `tree.png` / `tree-greece.webp` are
photographic cutouts, so a flat vector fir was the one asset that clashed.

Two species because the pack's densest spruce has the best silhouette but almost no snow,
while the one that genuinely carries snow is shorter and scruffier.

### Three traps that cost real bugs, all guarded now

The billboard is an **opaque cutout** — `TreeSilhouette` traces a polygon from the alpha
and there is no alpha test at draw time — which makes the source photo's properties
load-bearing in non-obvious ways:

1. **Fragmented alpha traces to nothing.** A photographed conifer's alpha is hundreds of
   disconnected needle islands. The tracer skipped them all as degenerate and emitted
   **12 vertices, 0.004 units tall** — invisible in game while looking perfectly fine as a
   texture. Fixed by a morphological close (`_consolidate_alpha`). *Verify with vertex
   counts, never by eye.*
2. **Transparent pixels carry garbage RGB.** Closing the alpha promotes them, and the
   opaque mesh then draws them — cyan fringe, then black. Fixed by flooding real colour
   outward first (`_BLEED_PASSES`), and by keeping only the largest island.
3. **Crushed shadows read as floating specks.** The photos are shot against bright sky, so
   shadow between the needles clips to near-black — 4% and 17% of opaque pixels. Against
   snow those render as black dots hanging in the air. Fixed by `_lift_shadows`; both
   trees now sit at 0.00% near-black, matching `tree.png`'s 0.01%.

## Rallies and the moved unlocks

Six rallies tagged `region: "snow"`, pinned in the NE massif, difficulty 1–4, weather
mixed dry/snow. They form a **chain** rather than a cluster: `sn_glacier_run` is the only
pin reachable from outside (from `sp_woodland_trial`, "Upgrade: Snow Tires"), and the two
specials are the deepest pins.

Two part unlocks moved north so the corner is worth working toward:

| part | was | now |
| --- | --- | --- |
| Race Tires | `gr_showdown` | `sn_showdown` |
| Sequential Gearbox | `hc_showdown` | `sp_summit_trial` |

The grip part belongs to the grip corner. Both source rallies were named after their
prize and were renamed; their `id`s stay put because they key saved progress.

**Snow Tires at the gateway.** The `tires` slot has since gained a second part —
`snow_tires`, awarded by `sp_woodland_trial`, the ONLY pin that lights the way in here.
So the player arrives in the frozen corner with winter rubber rather than earning it
afterwards, and Race Tires still waits at the far end of the chain. That
rally used to gate the engine-swap capability, which moved to `front_runners` beside HQ
to make room; see [engine-swap.md](engine-swap.md).

**Save migration v4 → v5.** A player who already won the old rally keeps the part, via
`Save.KEY_LEGACY_PART_UNLOCKS` — an early-out in `UpgradeLibrary.rally_gate_met`.
Marking the new rally completed would have been wrong: it would also light its map-reveal
circle and pay its placement stars. `Save.MOVED_PART_UNLOCKS` is the data the migration
reads, so a future move is a row plus an arm.

**Save migration v5 → v6.** The follow-up move of the engine-swap capability off
`sp_woodland_trial` (so it could carry Snow Tires) uses the same pattern for the same
reason: a career that completed that rally is granted the capability directly via
`Save.KEY_LEGACY_ENGINE_SWAP`, which `RallyLibrary.engine_swaps_unlocked` checks first.

Verified with `./report_eligibility.sh` (2/2/2/3 eligible cars on the four restricted
rallies) and `./sim_career.sh`.

> **`sim_career` note.** It reports ~3% of careers hitting a frontier with no enterable
> rally. That is **pre-existing and not caused by the Alps**: at 1500 runs the pre-Alps
> roster strands 52 times and this one 40 — adding rallies slightly *reduced* it. The
> signature is always the same three rallies (`hc_v12_promenade`, `gr_mountain_pass`,
> `gc_island_gp`) and a player who never won the GB / high-cylinder prize cars. Worth
> fixing separately; do not attribute it to this region.
