# Map Exploration

**Source:** `RallyLibrary` (`scripts/rally_library.gd`) — `HQ_MAP_POS`, `lit_sources`,
`rally_revealed`, `position_revealed`, `position_lit_by`, `reveal_radius_of`,
`reveal_link_pairs`, `distance_beyond_frontier`, `reveal_depths`, `opening_rally_id_for` —
plus `GameConfig.map_reveal_radius` and the
`map_pos` / `reveal_radius` fields authored on every `RallyLibrary.RALLIES` entry.

The world map is **dark except where the player has driven**. Every rally the player
completes lights a circle around its own pin; a rally becomes enterable when it falls
inside any lit circle. The player pushes the frontier outward and **chooses which
direction to go**, rather than being handed a wave of unlocks.

**HQ lights nothing, and is not drawn on the map.** The starting light is the player's
**opening rally** — the event awarding the car they picked, which they are dropped into
before the map is ever shown ([opening-rally](../todo/opening-rally.md)). It is lit
whether or not it has been completed, both because that is where their career begins and
because it is what stops a player who quits mid-run coming back to a map with nothing lit.
Everything else, including the pins nearest the middle, unlocks the ordinary way.

## The rule

```
revealed(rally) := any lit circle contains rally.map_pos

lit circles := { (r.map_pos, reveal_radius_of(r)) for every COMPLETED rally r }
             ∪ { the profile's OPENING rally, completed or not }
```

- Distances are in **normalised map units** — the same 0..1 space as `map_pos` — so the
  radii are independent of the map plane's metre size (`hq_map_plane_size`).
- `reveal_radius_of` returns the rally's authored `reveal_radius` if it has one, else
  `GameConfig.map_reveal_radius`. Authoring one lets a headline event open a wider
  frontier; the default is where pacing is actually tuned.
- **Only COMPLETED rallies light anything** (`completed` = a top-3 finish, the existing
  save semantics). Entering one and failing lights nothing, or the frontier would run
  away from the player.
- A completed rally is trivially inside its own circle, so completing a rally always
  keeps it revealed. This matters when reasoning about the closure — see the note in
  `test_a_rally_beyond_every_circle_stays_dark`.
- **Pure function of `(profile.rallies, RALLIES)`.** No fog state is stored, so there is
  nothing to persist, nothing to migrate, and nothing that can drift out of sync. Move a
  pin and its whole neighbourhood re-derives for free.

`position_revealed(pos, profile)` is the same predicate over an arbitrary point, so the
HQ table's fog shading uses the EXACT rule that gates entry rather than a lookalike.

## `map_pos` is the progression graph

A pin's POSITION now decides what it opens and what opens it. This is the single biggest
consequence of the design: `map_pos` used to be pure UI data with "no effect on the sim",
and it is now load-bearing content. Nudging a pin for visual spacing can disconnect a
branch of the map.

**Pin placement is a constraint-satisfaction problem, and `tools/fit_map_pins.py` solves
it.** Run it after adding, removing or re-siting a rally. It reads the land/sea palette
straight out of `textures/map_world.jpg`, holds every pin on usable ground inside its own
region's authored footprint (with coastal regions kept within reach of open water), and
anneals the positions so the opening wave is a single rally beside the garage and every
later wave reveals about two. It also enforces the upgrade-chain ordering below, reading it
out of `UpgradeLibrary` rather than duplicating it.

The shipped roster is fitted: **17 waves, averaging 1.94 new rallies each**, against the
`[1, 1, 1, 3, 3, 1, 2, 3, 3, 3, 4, 5, 2]` the old wave-counter layout produced. Two
rallies per wave is deliberate — it is the smallest number that is still a CHOICE, which is
the whole point of exploring outward in a direction you pick.

Two shipped-content guards cover this (`test_rally_library.gd`):

- `test_every_shipped_rally_is_reachable_by_exploring_from_hq` — the closure from HQ must
  cover the whole roster. A stranded pin is content the player can never see, and it fails
  **silently**: the rally simply never appears.
- `test_every_starters_opening_rally_leads_somewhere_but_not_everywhere` — the opening
  rally's circle must light
  at least one rally (else the game cannot start) and not the whole map (else there is
  nothing to explore).

Neither pins a number; both re-derive from whatever is authored.

## The graph on the table (dotted links)

The HQ map table draws that graph under the pins: a dashed line between two rallies
whenever completing either would light the other. `RallyLibrary.reveal_link_pairs(profile)`
decides the pairs — **one unordered entry per pair**, emitted when the link works in either
direction, since `reveal_radius` is per-rally and A can reach B without B reaching A.
`hq._build_reveal_links` is only the geometry: ids in, dashes on the table top, laid by
`hq._dash_line` at a fixed metre pitch so a long link and a short one read as the same kind
of line.

**The dashes are RIBBONS, not line primitives.** They were originally
`Mesh.PRIMITIVE_LINES`, which is one *pixel* wide however far away the camera is — on a
400-px-tall render target that made the graph a hairline that aliased into a shimmer and
disappeared against the lit map, so the table still read as an unconnected scatter of pins.
`hq._add_link_ribbons` now emits each dash as a quad with a real width in metres, extruded
in the table's **XZ plane** (not toward the camera, so it stays drawn *on* the map as the
view orbits) and extended by half a width at each end so consecutive dashes don't notch.
A darker, slightly wider ribbon is drawn underneath as an outline — the map plane is a
full-colour texture at full brightness where explored, so a light line needs its own edge
to separate it from pale terrain. Both live on one `ImmediateMesh` as two surfaces with
their own materials (outline first), so the pair can't be split or drawn out of order;
`hq.MAP_LINK_CORE_LIFT` is the second, smaller separation that stops the two coplanar
ribbons z-fighting each other.

Look values live in `GameConfig` and are authored in `config/game_config.tres`:
`map_link_alpha` (0 turns the graph off entirely), `map_link_color`, `map_link_width_m`
(the knob that actually governs readability), `map_link_dash_m`, `map_link_gap_m`, and the
`map_link_outline_width_m` / `map_link_outline_color` pair (outline width 0 drops that pass).
All of them are in `hq._map_pins_stamp`, so retuning any one rebuilds the map rather than
leaving a stale cache.

**Both ends must already be REVEALED.** An edge drawn across the dark hands the player the
shape of a roster they have not explored, which is exactly what the fog is there to
withhold, and 30-odd unreached pins webbed together makes the unexplored map the busiest
thing on the table. Restricted to lit pairs, the graph GROWS as the player explores: it
draws the route they actually made rather than the one they will be given. `_refresh_map_pins`
rebuilds it, so a link appears mid-parade at the moment its far pin lights.

Covered by `test_rally_library.gd` →
`test_the_reveal_graph_links_only_pairs_that_are_both_revealed` (the pairing rule, on a
synthetic roster) and `test_menu_flow.gd` →
`test_the_map_draws_no_reveal_link_out_into_the_dark` (the geometry the table actually
builds — asserted on the link mesh's vertices, because the drawn line is the point).

## Reachability order (`reveal_depths`)

`reveal_depths()` returns `rally_id -> wave`, computed by repeatedly lighting everything
currently reachable and completing it. Wave 1 is what a fresh profile can enter, wave 2 is
what those unlock, and so on. A rally no amount of exploring can reach is **absent from
the dict** — that absence is what the reachability guard above checks.

**This — not distance from HQ — is what "opens before" means.** The two genuinely
disagree, because reveal spreads as a *corridor* along the chain of pins rather than as
one growing circle: on the shipped roster `sp_woodland_trial` is reached at wave 2 while
`sp_lakeshore_trial` needs wave 16, a gap no straight-line distance predicts, because what
matters is whether anything lights the ground in between. Anything asserting authored order must read `reveal_depths`.

That ordering is a real content constraint, because upgrade gating chains through it: a
part's `requires_upgrade_id` prerequisite must be reachable no later than the part itself
(`UpgradeLibrary.unlocked_by_rally` names the gating rally), and engine swapping must sit on
the first special the map reaches. Note which side bends: the authored upgrade chain is
design intent, so **the pins conform to it**, not the other way round — `fit_map_pins.py`
takes those orderings as constraints. See
`test_a_gated_parts_prerequisite_is_reached_no_later_than_the_part_itself`,
`test_engine_swapping_is_the_first_special_the_map_reaches` and
[upgrade-catalogue.md](upgrade-catalogue.md).

`reveal_depths` deliberately **ignores cars**: it answers "is the map connected, and in
what order", which is the authored-geometry question. Whether the player has something
eligible to drive at each step is a separate, garage-dependent question.

`distance_beyond_frontier(rally, profile)` is the other direction — how far a rally sits
outside the CURRENT lit region (0.0 once revealed). It is progress-dependent, so it drives
live player-facing readouts (which event to head for), not authored-order assertions.

## What the retired mechanism was

Two global wave counters, both read through a `completions_required` shim:

- `reveal_after` (int) on ordinary rallies — reveal once N ordinary rallies were completed
  **anywhere** on the roster.
- `requires_completions` (int) on specials — the "special ladder", rungs authored
  2/4/6/…/16, quoted on the map as "N/M rallies".

Both fields, plus `completions_required`, `completions_needed`, `next_locked_special_id`,
`_completed_count` and `engine_swap_completion_requirement`, are **deleted**. The problem
was that the rally you unlocked had no relationship to the rally you had just won — a win
in one corner opened a rally in another for no reason the player could see — and every
authored rung had to be re-checked by hand whenever the roster changed.

Surfaces that used to quote a count now name a destination instead:

- The garage's **carrot line** is **deleted** (`hq._carrot_line` /
  `_refresh_carrot_line` and their widgets are gone). With no count to quote it fell back
  to naming the nearest locked special, and a part-unlock special is titled after its own
  reward, so it read as a bare "UPGRADE: SUPERCHARGER" over the garage explaining nothing.
  The teaser below survives because on the MAP the name is placed where the player has to
  reach it.
- The map's **locked-special teaser** (`hq._build_special_teaser_label`) shows the event's
  NAME over what it unlocks, with no progress fraction: there is no counter to show, and a
  distance readout would be noise. The dark map around it already says "not yet".
- The **engine-swap locked hint** (`hq`'s car-park confirm popup) names the rally via
  `RallyLibrary.engine_swap_unlock_rally_name()`. In the upgrades grid the same lock reads
  as a `"Locked"` reason on the `engine` tile (`UpgradeOptions.engine_swap_blocked_reason`; the
tile lists no engine catalogue — `options_for` returns an empty array for `SLOT_ENGINE` and hands
off to the car picker, since a swap trades engines with another owned car).

## Testing

Reveal depends on authored `map_pos` values, which are tunable content, so logic tests use
**synthetic rosters** and express "open" / "locked" as pin positions rather than as
counters:

- the profile's opening rally is open from the start;
- a pin offset far beyond every circle never opens;
- a near pin with a wide authored `reveal_radius` is how a fixture models "complete this to
  open that" — see `tests/headless/rally_fixtures.gd` (`fx_open` → `fx_gated`), whose pin
  positions are load-bearing and documented as such.

Coverage lives in `test_rally_library.gd` (the predicate, the closure, the two
shipped-content guards), with the fixture-roster consumers in `test_reward_system.gd`,
`test_save_manager.gd` and `test_sim_career.gd`.

## Related

[rally-roster.md](rally-roster.md) (the `map_pos` authoring rules — land, palette, spacing),
[regions.md](regions.md) (the four map corners), [menus.md](menus.md) (the HQ table, pins
and the reveal parade), [upgrade-catalogue.md](upgrade-catalogue.md) (gating that chains
through reveal order).
