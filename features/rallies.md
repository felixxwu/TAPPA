# Rallies

A level save's `rallies` list holds named point-to-point rallies on Hafren. Each one has a `start` and a `finish`, written as `{x, z, yaw}`, and a rally end's yaw turns its −z to the way the cars leave the line.

- **Finding spots:** `tools/rally_spots.gd` / `.tscn` scans the level for straight, level road at least 6 m wide, with under 3 m of ground rise across the start area and no junctions, buildings or shops nearby. It pairs the spots into rallies 5–7 km long and names each rally after its nearest teleport point (e.g. "Pen Rhiw Stages").
- **Ground:** every spot gets a 50 × 23 m gravel pad, and `pack_level.js` clears the trees and ground cover off it. The pads are baked into the ground and always show. Rallies are left out of the bake key, so editing a rally never forces a rebake.
- **In game:** `scripts/level_rallies.gd` (`LevelRallies`) shows only the active rally (`LevelRallies.active`; "" means none). `show_active` puts a start line at both ends, chosen from `MODELS` by `model_for`, a hash of the rally name. `crowd_groups` hands `LevelSpectators.set_extra` crowds beside each line, kept out of `CONTROL_ZONE` at the start-control end.
- **Models:** `models/start_lines/*.glb` are exported from [start-lab.md](start-lab.md) with a 7 m road and a 50 m start area. `collider` builds one `ConcavePolygonShape3D` from every triangle that reaches above `MIN_SOLID_Y`, so the arch, tents, fences and tape are solid, while flat road paint and mats get no collision.
- **Dev:** the Settings → Dev "Rally: …" button cycles through None and each rally.
- **Tests:** `tests/headless/test_level_rallies.gd`.
