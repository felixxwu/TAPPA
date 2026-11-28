extends Node
# Docs: features/benchmark.md — update in the same change as this file.
# Autoload "Benchmark": the flag the Hafren replay benchmark (benchmark/level_replay.gd) raises while
# it measures, so the rest of the game holds still for it (no cloud sync, no adaptive graphics,
# a fixed engine misfire seed, a landscape frame).

# Fixed seed for the per-car engine RNG (damage misfires), so successive replays stumble identically.
# level_replay passes it to RngStreams.reseed so every replay draws the same random numbers.
const RNG_SEED := 90210

# True while a replay is measuring.
var active := false

# When > 0, DisplayStretch lays the frame out at this logical height while `active`, instead of
# the configured render height. 0 = the game's own height.
var render_height := 0

# True for a golden replay (--golden): it must play out identically on every run, so the world streams on the
# main thread and the level replay writes a per-tick trace. Perf replays leave this off.
var golden := false
