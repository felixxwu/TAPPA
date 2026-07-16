# Aero parts (spoilers & splitters)

Spoilers and front splitters are the **visual** half of the `aero` upgrade slot
([upgrade-catalogue.md](upgrade-catalogue.md)) — the downforce effect and
aero-balance tuning ([tuning.md](tuning.md)) already exist; this is only the
mesh reveal.

## Authoring (Blender)

- Model the wing as a **separate mesh object inside the car's existing body**
  (in-context on the car), in the same `.blend`. Export the one glb as usual.
- Name the object so it contains the substring **`_aero`** and **no `.`** (glb
  import sanitizes `.`→`_`), e.g. `wing_aero`, `splitter_aero`. glTF preserves
  object names as Godot node names — verified: `blender/charger/charger.glb`
  ships an object literally named `body`.
  - ⚠️ It is a **suffix / substring `_aero`, not an `aero_` prefix**. The match
    is `find_children("*_aero*", …)`, so `aero_wing` does **not** match (no
    underscore *before* `aero`) and the part would never hide/show. Use
    `wing_aero`, `splitter_aero`, etc.
- **Bake modifiers + transforms before export.** Godot imports only the geometry
  in the glb — it has no concept of Blender modifiers. A Mirror (or any) modifier
  is baked only if the glTF exporter's *Data → Mesh → Apply Modifiers* is on
  (default), otherwise Godot sees only the un-mirrored half. Do it explicitly, in
  order: apply the modifier stack, then *Object → Apply → All Transforms* (so a
  mirror mirrors about the true centre and vertices bake to final position at an
  identity object transform, like the car body). Un-applied scale/rotation or
  parenting to helper empties otherwise exports as node transforms that land the
  wing in the wrong place/size.
- **Material:** aero parts keep their **own** authored glb material (e.g. flat
  black) — the body-texture pass (`_apply_model_material`) skips `*_aero` meshes,
  because the body texture atlas has no UVs for a bolt-on wing. Give the wing
  whatever material you want in Blender. (Note: that material is the imported
  glb material, so it is NOT in the PS1 lit/dither/fog shader the body uses —
  if you want a wing that matches that pipeline, say so and the skip can become
  a dedicated PS1 wing material instead.)
- No separate model, no second export, no editor wiring — the mesh is toggled
  purely in code.

## Runtime (`scripts/car.gd`)

- `AERO_TAG` (`"_aero"`) + `_set_aero_visible(body, shown)` toggle every
  `*_aero` `MeshInstance3D` under a body.
- Whenever a glb body is revealed (`_apply_model_visibility`), wings are hidden
  by default — so free-roam, opponents, and un-upgraded owned cars show none.
- `_apply_aero_visibility(owned)` re-reveals them on the active body iff
  `UpgradeLibrary.aero_tuning_unlocked(owned)` (aero kit fitted **and** enabled).
  It runs at the end of `apply_owned` and the live re-derive
  (`_rederive_live_config`, used by the start-line Upgrades menu), so toggling
  the aero part off in the upgrades menu removes the wing immediately.
- `set_body_hidden(false)` (debug hitbox overlay) re-applies the cached
  `_last_owned` so the wing returns after the overlay is toggled off.

## Tests

`tests/headless/test_aero_visibility.gd` — the traversal + reveal-follows-
enabled-state logic, plus that `*_aero` meshes keep their own material (uses stub
`_aero` nodes; the aero *gate* is covered in `test_upgrade_library.gd`).
`test_smoke.gd` guards any authored wing as a hidden `MeshInstance3D`.
