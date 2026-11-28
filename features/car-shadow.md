# Car Shadow

**Source:** `scripts/car_shadow.gd` (`CarShadow`, `extends MeshInstance3D`).

**Tests:** `tests/headless/test_car_shadow.gd`

The GL-Compatibility renderer here runs no lights or real shadows (see [rendering.md](rendering.md)),
so the player's car gets a fake one: a soft-edged rectangle the size of the car's body
(`shaders/car_shadow.gdshader`, a rounded-box distance blurred by `car_shadow_soft_m` either
side of the outline) on the ground under it.

- Every physics frame it rays straight down from the car (excluding the car's own body), lies on
  the hit point tilted to the hit normal, and turns with the car's heading.
- Its outline is the car's body footprint (`half_width()` / `half_length()`), scaled along the
  car's own axes, so it matches the body's width, length and heading; a car change resizes it.
- It darkens to `car_shadow_alpha` and fades linearly with the car's height above the ground,
  vanishing at `car_shadow_fade_height_m` (also the ray length) — so jumps read as airtime.
- Wired like `CarLamps` in `level_view.gd` (`_add_effects`).
