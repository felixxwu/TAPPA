# Car Cargo

**Source:** `scripts/car_cargo.gd` (`CarCargo`), `tools/cargo_lab.html`, `models/car_cargo.json`.

**Tests:** `tests/headless/test_car_cargo.gd`

Cardboard boxes held down by orange straps, shown on the player's car while a delivery's cargo
is aboard (`LevelView.delivery` has `cargo_hp`; see the deliveries part of
[level-editor.md](level-editor.md)). The look depends only on the car, never on what is being
delivered or how heavy it is.

## Authoring: the cargo lab

`tools/open_cargo_lab.sh [car_id]` serves the repo and opens `tools/cargo_lab.html` (it needs HTTP
to load the car models). The lab reads the roster from `scripts/car_library.gd` and each body's
glb and transform from `car.tscn`, so it works in the game's car-local space (metres, +Y up,
−Z forward). `?car=all` visits every car once so each gets a first-guess layout.

- **First guess** (`autoLayout`): Roof, Back (rear deck) or Bed (a pickup's floor between its
  rails, found by ray-casting the body; the default for `BED_CARS`, the Acty and F-150). 2–5
  boxes by the patch's area (or the Boxes field), with two straps across them.
- **Boxes** are `{x, z, w, h, d, yaw, lift, shade}`; their height is not authored: each rests on
  the highest point under its footprint, the body or a box listed before it (`settleBoxes`),
  plus `lift`.
- **Straps** are `{z, yaw, span, width}`: a vertical slice through (0, z) at a heading, always centred on the car's middle line,
  pulled taut `span` either side over whatever lies under it: it bridges gaps and dips and only
  touches the outermost edges, never bending inward (`drapeStrap`, an upper convex hull). Moving a strap re-drapes it.
- Drag an item to slide it over the car; arrows / Q E / PgUp PgDn nudge it (help in the panel).
- **Save** writes `models/car_cargo.json` via the browser's file picker (Download as a fallback);
  unsaved edits survive reloads in localStorage until saved or reverted.

## In the game

The file stores the lab's knobs plus what the game draws: each box's resting `y` and each
strap's draped `points`, `side` axis and `color`. `CarCargo.build(car_id)` turns one car's entry
into a single vertex-coloured mesh with the car-body shader (lit through
`GameConfig.apply_car_light`); a car with no entry carries nothing. `LevelView._add_effects`
parents it to the car and `_process` shows it only while cargo is aboard. It has no collider
and adds no mass (the cargo's `kg` does that, separately). `models/car_cargo.json` is in every
export preset's `include_filter`.
