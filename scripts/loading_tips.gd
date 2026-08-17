class_name LoadingTips
extends RefCounted
# Flavor text for the loading screen (features/loading.md), shown in place of the
# generation-stage name that used to sit there ("Placing signs…", "Generating track…").
# world.gd::_stage still print()s the stage name for perf debugging — that is unchanged —
# it just no longer forwards it to the visible label. One tip is drawn per load and shown
# for its whole duration.
#
# Each tip is read in ISOLATION: the player only ever sees one, never its neighbors, so
# every entry must stand alone. No "instead", "also", "the other way", "as above", or any
# wording that assumes context from a tip that isn't there. Verified against the mechanic
# it names when written — re-verify against the relevant features/*.md before editing one,
# the same rule CLAUDE.md applies to code comments.

const TIPS: Array[String] = [
	"Aero balance helps tune understeer and oversteer at speed.",
	"Grip balance helps tune oversteer against understeer.",
	"Brake bias helps tune understeer and oversteer during braking.",
	"All-wheel drive gives the most grip and the least drama.",
	"Big turbos hit harder but take longer to spool up.",
	"A fitted turbo drags on the engine even when it isn't boosting.",
	"Superchargers deliver full power instantly, with no spool-up lag.",
	"An engine swap brings its own gearbox and shift feel with it.",
	"An engine swap shifts a car's front-to-rear weight balance.",
	"Detuning an engine lowers its torque, and with it the car's performance rating.",
	"Ballast adds weight, which lowers a car's performance rating.",
	"Once engine swapping is unlocked, swapping is free and you can do it as often as you like.",
	"Damage depends on how hard you decelerate, not how fast you were going.",
	"The pit repair between events is free, but only a paid repair restores a car fully.",
	"A hard impact can bend a wheel out of alignment until it's repaired.",
	"Heavy damage makes an engine misfire long before the car gives up.",
	"Rain lowers tire grip across the whole stage.",
	"Cutting across a corner triggers an automatic time penalty.",
	"A Special Event's upgrade reward unlocks for any car in your garage.",
	"Rival cars can be running their own engine swaps.",
	"Wheel styles are purely cosmetic and free to swap.",
]


# The last tip handed out, so consecutive draws don't repeat — a fresh LoadingScreen
# instance is built per load (world.gd, hq.gd, hq_challenge.gd all `LoadingScreen.new()`),
# so this has to live here, at the class level, rather than on the instance.
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
