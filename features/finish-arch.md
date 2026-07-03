# Finish / Start Arches

**Sources:** `scripts/finish_arch.gd` (`FinishArch`, a self-building `Node3D` used
for **both** gates), placed by `scripts/world.gd._place_arch` (which reads the live
event off `RallySession`). Iterated visually with `tools/render_model.gd`.

The fat inflatable **rally gates** that bookend a stage — Dakar-style orange
portals that span the road, with a `FINISH` / `START` wordmark across the top beam,
info boards down each leg, and guy ropes anchored to ground stakes on both sides.
Built entirely from code (like [signs.md](signs.md) / [trees.md](trees.md)) so it
fits the procedural-asset style and the PS1 flat-shaded look. The same `FinishArch`
model serves both gates; the `is_start` flag picks the FINISH vs START wording, and
the `info` dict carries the **live event data** the banners display (see below).

## Placement in the world

`world.gd._generate_track` calls `_place_arch(...)` twice after the roadside signs:

- **Finish** — at the **finish offset** (the end of the *generated* track,
  captured before the post-finish runoff is appended), i.e. exactly **100% track
  progress**. `stage_complete_percent` is 100 and TrackProgress reaches 100% at
  that offset (see below), so crossing the finish arch ends the stage immediately.
  The rendered road continues a short straight **runoff** past the arch
  ([track.md](track.md)) so the car has room to stop — the arch does NOT move to
  the runoff end. Co-located with the finish sign pair ([signs.md](signs.md)).
- **Start** — at `start_pos` / `start_heading`, the **car's real spawn pose** (the
  start line). For a staged run this is the launch point ahead of the lead-in stub;
  for a dev boot it is centerline offset 0. This is exactly where track progress
  reads **0%**: the start-line sequence snaps the car onto the line at the off
  (`StartLine._release_player` → `Car.reset_to`), and `StageManager` then re-anchors
  `TrackProgress` to 0% there ([progress.md](progress.md)). The old A-frame start
  boards are gone — the arch is the start marker now ([signs.md](signs.md)).

Shared placement details:

- **Position** — at the centerline (road-surface) height (`terrain.height_at`),
  like the signs.
- **Orientation** — the arch is built in its local XY plane and extruded along
  local Z (depth), so `Basis.looking_at(heading, UP)` aligns the depth axis with
  the road: the node's −Z points down-track and **+Z (the banner face) turns to
  meet the driver**.
- **Width** — the clear opening is `track_width + 2 × finish_arch_road_margin_m`,
  so the legs stand off the road on both sides and the car drives through cleanly.
  With the defaults (6 m road, 1.5 m margin) the opening is 9 m, the arch ~12.4 m.

Config (`GameConfig` › *Finish Arch*): `finish_arch_enabled`, `start_arch_enabled`
(build each gate), `finish_arch_road_margin_m` (gap between each road edge and a
leg's inner face, shared by both). The arches are visual-only (no collision); the
legs sit clear of the racing line.

## Reaching 100% progress

The finish-line gate relies on `TrackProgress` actually reaching 1.0. Its
`_local_closest_offset` steps the curve at `SEARCH_STEP_M` (1 m), which would stop
~1 m short of the baked length and cap progress below 100%, so it now also samples
the window's far edge exactly — letting `_best_offset` hit the baked length as the
car crosses the finish, which trips the `stage_complete_percent = 100` edge
([stage.md](stage.md)).

## Geometry (`FinishArch`)

The arch is one extruded mesh plus a few primitive props, rebuilt by `build()`
(called from `_ready()`; `build()` clears its children first, so it is
idempotent):

- **Profile** — `_arch_profile()` traces a single closed 2D outline of an
  inverted U (open at the bottom): up the outer edges, around the two top-outer
  rounded corners (`outer_radius`), down to the ground, then up the inner edges
  and across the beam underside via the two top-inner fillets (`inner_radius`).
  `_append_arc()` tessellates each corner into `corner_segments`.
- **Extrusion with a bulge** — `_build_arch_mesh()` triangulates the profile for
  the **flat** front (+Z) and back (−Z) caps (kept flat so the banners read
  cleanly), then sweeps a **barrel side wall**: each boundary point is pushed out
  along its 2D normal by `bulge·cos θ` while `z = (depth/2)·sin θ` walks
  front→back over `depth_segments` rings — giving the inflated, rounded-tube
  silhouette from the side. Normals are generated; no UVs/tangents on the body
  (it is flat-coloured, not textured). **Cap winding:**
  `Geometry2D.triangulate_polygon` emits CCW triangles, but Godot's back-face
  culling treats CW (as seen by the viewer) as the front face, so each cap
  triangle is reversed when emitted — otherwise both flat caps point inward, get
  culled, and the arch reads as see-through / concave.
- **Seams** (`_add_inflatable_seams`) — thin dark quads ringing each leg to sell
  the inflated-baffle look.
- **Banners** (`_add_banners`) — the live event text (see *Banners* below).
- **Guy ropes + anchors** (`_add_guy_ropes`, `_add_anchors`) — four thin cylinders
  (two per side, fore/aft) from near the top of each leg out to two box stakes.

Key `@export`s (metres): `span`, `leg_width`, `height`, `top_height`, `depth`,
`bulge`, `inner_radius`, `outer_radius`, `corner_segments`, `depth_segments`,
`leg_taper`. Look: `arch_color`, `seam_color`, `sun_direction`.

## Material & banners

Tubes use `shaders/ps1_models_lit.gdshader` (the car's flat fake-lit shader) so
the arch catches the same hemisphere+sun shading as the car; `_make_material()`
sets the light params.

The banners show the **live event** the player is driving, not placeholder art.
`world.gd._arch_event_info()` reads `RallySession` into an `info` dict — `rally_name`,
`stage_index`, `stage_count`, `target_ms` (the time-to-beat) — and sets it (plus
`is_start`) on the gate before `build()`. The rally's `difficulty` is a **hidden**
tier and is deliberately **not** included or rendered. `_add_banners()` renders the
info as `Label3D` text laid just proud of the orange faces (no baked textures, so
it always matches the event):

- **Top beam** (front approach + back down-track) — the `START` / `FINISH`
  wordmark followed by the rally name, in bright text on the orange cap. Long
  names auto-wrap to the beam width.
- **Legs** (a cream board on each leg's front face) — `STAGE n/3` at the top and
  the `TIME TO BEAT m:ss.ss` (start gate only, from the fastest rival's time for
  this event) below it. No difficulty tier is shown (it's hidden). `_fmt_time()`
  matches the HUD / standings clocks.

Empty/zero `info` fields are skipped, so a dev boot or direct play with no active
rally shows just the `START` / `FINISH` wordmark — no misleading stage text.

## Visual iteration (`tools/render_model.gd`)

Headless rendering uses the dummy renderer and can't read back pixels, so the
arch is eyeballed by rendering a real GL frame offscreen under `xvfb`:

```
xvfb-run -a -s "-screen 0 1280x1024x24" godot --path rally \
    --rendering-driver opengl3 --script tools/render_model.gd
```

It drops the arch onto a road/desert ground (at the real `track_width`) in a
`SubViewport`, with a sample `info` dict so the banners render real-looking text,
and writes PNGs for five camera angles (front, three-quarter, side, hero-low,
through-the-gate) plus a `start_front` shot of the START gate variant to
`tools/render_out/`. Pure tooling — not shipped in the game.

## Tests

`tests/headless/test_finish_arch.gd` — the arch builds a solid body mesh, spans
its configured opening/height and stands on the ground, has the expected banner
boards + ropes + stakes, `build()` is idempotent (rebuild replaces rather than
appends), the flat front/back caps are wound to face outward (guarding the
back-face-culling bug above), and the banners render the live event info (rally
name / stage / time-to-beat / tier) — falling back to just the wordmark when no
rally is active. `tests/headless/test_smoke.gd` —
`test_finish_arch_straddles_the_road_at_the_stage_end` checks `world.gd` builds the
finish gate at the centerline end (100% progress), and
`test_start_arch_straddles_the_road_at_the_start_line` checks the start gate sits
at the start line; both assert the opening is wider than the road and the gate
stands upright across it.
