class_name LoadingTips
extends RefCounted
# Flavor text for the loading screen (features/loading.md). A fresh tip is drawn every
# LoadingScreen._TIP_CYCLE_SEC for as long as the overlay is up (a long load no longer
# sits on one sentence), and random() never repeats the previous draw.
#
# Each tip is read in ISOLATION: the player only ever sees one, never its neighbors, so
# every entry must stand alone. No "instead", "also", "the other way", "as above", or any
# wording that assumes context from a tip that isn't there. Verified against the mechanic
# it names when written — re-verify against the relevant features/*.md before editing one,
# the same rule CLAUDE.md applies to code comments.

const TIPS: Array[String] = [
	# --- Tuning / parts (Tune car and Parts at a checkpoint) ---
	"Aero balance helps tune understeer and oversteer at speed.",
	"Grip balance helps tune oversteer against understeer.",
	"Brake bias helps tune understeer and oversteer during braking.",
	"All-wheel drive gives the most grip and the least drama.",
	"Big turbos hit harder but take longer to spool up.",
	"A fitted turbo drags on the engine even when it isn't boosting.",
	"Superchargers deliver full power instantly, with no spool-up lag.",
	"An engine swap shifts a car's front-to-rear weight balance.",
	"Nitrous boosts power for as long as its tank lasts.",
	# --- Damage ---
	"Damage depends on how hard you decelerate, not how fast you were going.",
	"A hard impact can bend a wheel out of alignment until it's repaired.",
	"Heavy damage makes an engine misfire long before the car gives up.",
	"An overheating engine slowly drains the car's health.",
	# --- Free roam ---
	"Driving past a checkpoint lights it. Stay there and your car repairs itself.",
	"Stop at a checkpoint and press Enter or A to open its page: parts, garage, map and tuning.",
	"If your car gives up, you respawn at the last checkpoint you passed.",
	"A wreck drops all your money where it happened. Drive back to the crystal to pick it up.",
	"A second wreck loses the money the first one dropped, so spend what you carry.",
	"Travelling from anywhere but a checkpoint leaves your money behind.",
	"Open the map to travel to any checkpoint you have lit.",
	"Light a checkpoint in a new biome to put that biome's cars and parts on sale.",
	"Each biome has its own weather and its own grip.",
	"Press R to put the car back on the nearest road.",
	"A car that is stuck or flipped is put back on the road by itself.",
	"Drive past the coins beside the road to collect them.",
]


# The last tip handed out, so consecutive draws don't repeat — both across loads
# (a fresh LoadingScreen is built per load) AND within one, since the tip now
# cycles every _TIP_CYCLE_SEC. This has to live at the class level rather than
# on the instance.
static var _last := ""


# One tip, drawn uniformly and never equal to the previous draw (when the pool has more
# than one entry to pick from). Global RNG rather than a seeded RandomNumberGenerator —
# this is pure flavor text with no determinism requirement (no cache, no replay, nothing
# reads it back), the same convention used for cosmetic jitter elsewhere (engine_smoke.gd,
# wheel_particles.gd).
static func random() -> String:
	_last = _pick_avoiding(TIPS, _last)
	return _last


# Pure draw-without-repeat, split out of random() so the no-repeat rule (including the
# single-entry degrade case) is testable against a small synthetic pool rather than the
# real TIPS const, which cannot be swapped out (const, not a Registry.Seam — this is
# flavor text, not authored game data).
static func _pick_avoiding(pool: Array[String], avoid: String) -> String:
	if pool.is_empty():
		return ""
	var pick := pool[randi_range(0, pool.size() - 1)]
	while pick == avoid and pool.size() > 1:
		pick = pool[randi_range(0, pool.size() - 1)]
	return pick
