"""Fit the roster's `map_pos` values so exploring the world map reveals ~2 new rallies
per wave (features/map-exploration.md).

Reveal is geometric: HQ starts lit, every completed rally lights a circle around its own
pin, and a rally opens when it falls inside one. That makes `map_pos` the progression
graph, so pin placement is a constraint-satisfaction problem rather than decoration — which
is what this tool solves. Run it after adding, removing or re-siting rallies, then paste
the result back into RallyLibrary.RALLIES and re-run the map tests.

Requires numpy + PIL (same as tools/gen_map_texture.py). Usage:

    python3 tools/fit_map_pins.py [seeds]      # prints the current + fitted wave profile

Hard constraints (a candidate position failing any of these is never considered):
  * on usable ground, with a clear disc around it — no pins in the sea;
  * a *_coast region's pin keeps open water within COAST_WATER, so the coastal corners
    still read as coastal;
  * inside the region's authored footprint, so `home` stays NW, `greece` SW and so on;
  * inside the safe map border;
  * and >= MIN_SPACING from every other pin — enforced as a hard reject at move time, not
    as a cost, so the result can never settle just under the floor.

Soft objective (the annealer minimises):
  * every wave is as close to TARGET as possible — including the first, which is an
    ordinary wave now that each starter begins INSIDE its own opening rally rather than
    sharing one intro pin beside HQ (todo/opening-rally.md);
  * the upgrade unlock chain stays satisfiable in reveal order (a part's prerequisite gate
    is reached no later than the part's own gate), and engine swapping sits on the first
    special the map reaches;
  * pins stay near where they were authored, so the map keeps its hand-made geography.

Hard constraints: every pin on usable ground with clearance, inside its own region's
authored area, inside the safe map border, >= MIN_SPACING from every other pin, and the
whole roster reachable from HQ. Soft objective: wave sizes near TARGET (with the opening
wave pinned to 1), plus a light pull toward each rally's original position so the map keeps
its authored geography.
"""
import sys, os, math, random, json, re
from PIL import Image
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
IMG = os.path.join(ROOT, "textures", "map_world.jpg")
SRC = os.path.join(ROOT, "scripts", "rally_library.gd")
UPGRADES = os.path.join(ROOT, "scripts", "upgrade_library.gd")


def load_pins():
    """(id, region, x, y) for every authored rally."""
    s = open(SRC).read()
    body = s[s.index("const RALLIES:"):]
    ent = re.findall(
        r'"id": "([a-z0-9_]+)"[^\n]*?"region": "([a-z_]+)".*?"map_pos": Vector2\(([\d.]+), ([\d.]+)\)',
        body, re.S)
    return [(i, r, float(x), float(y)) for i, r, x, y in ent]


def land_mask():
    """True where a pin may stand. The generator paints the sea in teal (C_SEA_SH/DP) and
    the snowline near-white, so both separate cleanly from the green/tan ground."""
    im = np.asarray(Image.open(IMG).convert("RGB"), dtype=np.int16)
    r, g, b = im[..., 0], im[..., 1], im[..., 2]
    return ~(((b - r) > 10) | ((r > 190) & (g > 190) & (b > 190)))


def land_clearance(mask, x, y, r_norm):
    """True when a disc of radius r_norm around (x,y) is entirely usable ground — keeps a
    pin off a one-pixel spit that would read as standing in the sea."""
    H, W = mask.shape
    rp = max(1, int(r_norm * W))
    px, py = int(x * W), int(y * H)
    if px - rp < 0 or py - rp < 0 or px + rp >= W or py + rp >= H:
        return False
    sub = mask[py - rp:py + rp + 1, px - rp:px + rp + 1]
    yy, xx = np.ogrid[-rp:rp + 1, -rp:rp + 1]
    return bool(sub[(xx * xx + yy * yy) <= rp * rp].all())


def load_order():
    """(earlier_rally, later_rally) pairs the reveal order must respect: a gated upgrade's
    prerequisite is itself gated on a rally that must be reached first. Read out of
    UpgradeLibrary rather than duplicated here, so retuning the catalogue retunes this."""
    body = open(UPGRADES).read()
    body = body[body.index("const UPGRADES:"):]
    gates, prereq = {}, {}
    for it in re.split(r"\n\t\{", body):
        m = re.search(r'"id": "([a-z0-9_]+)"', it)
        if not m:
            continue
        g = re.search(r'"unlocked_by_rally": "([a-z0-9_]+)"', it)
        p = re.search(r'"requires_upgrade_id": "([a-z0-9_]+)"', it)
        if g:
            gates[m.group(1)] = g.group(1)
        if p:
            prereq[m.group(1)] = p.group(1)
    return [(gates[prereq[i]], gates[i]) for i in gates
            if prereq.get(i) in gates]

R = 0.16              # GameConfig.map_reveal_radius
# HQ LIGHTS NOTHING (RallyLibrary.lit_sources). It used to seed the map with a circle of
# its own; the player now starts inside their own opening rally instead, so the only
# starting light is that rally's circle — see OPENING_FOR and STARTS.
# Any rally that authors its own wider reveal_radius, so the link rule below matches the
# game's rather than assuming every pin reaches the same distance.
_SRC_TEXT = open(SRC).read()
_RALLIES_TEXT = _SRC_TEXT[_SRC_TEXT.index("const RALLIES:"):]
AUTHORED_RADIUS = {
    m.group(1): float(m.group(2)) for m in re.finditer(
        r'"id": "([a-z0-9_]+)"(?:(?!"id":).)*?"reveal_radius": ([\d.]+)',
        _RALLIES_TEXT, re.S)
}
HQ = (0.5, 0.5)
# New rallies per wave. NOT independent of DEPTH_TARGET: 32 rallies over N waves averages
# 32/N each, so these two must be set together or they simply fight — a target of 2 against a
# depth of 5 is unreachable by construction, and every wave pays a penalty it can do nothing
# about. Kept at roughly 32 / DEPTH_TARGET.
TARGET = 6.0
SPREAD_TARGET = 1.2   # radians (~70 deg) a wave's pins should span, seen from HQ
SPREAD_WEIGHT = 1.5   # how hard to push for that spread against the wave-size objective
# A SECOND, larger floor between two PRIZE pins. Ordinary pins may sit at MIN_SPACING
# without harm — they are small flags and the player reads them one at a time — but two
# prizes that close read as a single cluster, which defeats the point of spreading rewards
# so that every direction offers something distinct to aim at. Their markers are also the
# biggest objects on the table (a car model, a trophy), so they crowd visually well before
# their hit spheres do.
# 0.11, NOT the 0.16 first tried. 0.16 was exactly the reveal radius, which made two of the
# things asked of this map mutually impossible: prizes had to sit a full circle-radius apart,
# so a single circle could hold about two of them — and four beginner prizes therefore could
# not all be one win from the opening rally, however hard the link objective pushed. Sitting
# just above the general MIN_SPACING keeps prizes visibly clear of one another while letting
# several share a circle.
PRIZE_MIN_SPACING = 0.11
MIN_SPACING = 0.10    # rally-roster.md floor is 0.05; held wider so pins never crowd
                      # (at 0.05 neighbours ended up ~24 cm apart on the table, close
                      # enough that two prizes read as one cluster)
BORDER = (0.06, 0.94)
CLEARANCE = 0.010     # disc of usable ground required around a pin
REGION_REACH = 0.22   # how far a pin may roam from its region's authored footprint
# Coverage: the map should not have large stretches of usable ground with nothing on them.
# A band of empty table reads as unfinished rather than as wilderness, and it is dead space
# the player pans across on the way to somewhere else. Sampled on a coarse grid over the
# usable ground; any sample further than COVERAGE_REACH from every pin costs.
# The NE snow corner holds no region and no rallies by design (regions.md — the alpine
# corner's content is deferred), so no pin may stand there. It used to stay clear only as a
# side effect of tight region footprints; once REGION_REACH grew to reach the southern gap,
# home_coast could drift up into it. An explicit exclusion says the rule out loud instead of
# relying on another constraint to imply it.
SNOW_CORNER = (0.60, 1.01, -0.01, 0.40)   # x_min, x_max, y_min, y_max
COVERAGE_GRID = 12
COVERAGE_REACH = 0.17
COVERAGE_WEIGHT = 8.0
COAST_WATER = 0.06    # a *_coast pin must have open water this close, or the region
                      # stops reading as coastal (every shipped one is within 0.04)

mask = land_mask()
H_PX, W_PX = mask.shape
pins = load_pins()
ids = [p[0] for p in pins]
region = {p[0]: p[1] for p in pins}
orig = {p[0]: (p[2], p[3]) for p in pins}
by_region = {}
for i, r, x, y in pins:
    by_region.setdefault(r, []).append((x, y))


def water_within(x, y, r):
    rp = int(r * W_PX)
    px, py = int(x * W_PX), int(y * H_PX)
    x0, x1 = max(0, px - rp), min(W_PX, px + rp + 1)
    y0, y1 = max(0, py - rp), min(H_PX, py + rp + 1)
    return bool((~mask[y0:y1, x0:x1]).any())


def valid(rid, x, y):
    if not (BORDER[0] <= x <= BORDER[1] and BORDER[0] <= y <= BORDER[1]):
        return False
    sx0, sx1, sy0, sy1 = SNOW_CORNER
    if sx0 <= x <= sx1 and sy0 <= y <= sy1:
        return False
    if rid in ANCHORS:
        ax0, ax1, ay0, ay1 = ANCHORS[rid]
        if not (ax0 <= x <= ax1 and ay0 <= y <= ay1):
            return False
    if not land_clearance(mask, x, y, CLEARANCE):
        return False
    # A coastal region must stay on the shoreline, or it stops looking like one.
    if region[rid].endswith("_coast") and not water_within(x, y, COAST_WATER):
        return False
    # Stay inside the region's authored footprint: near at least one of its original pins.
    return any(math.dist((x, y), p) <= REGION_REACH for p in by_region[region[rid]])


def candidates(rid, n=4000):
    out = []
    while len(out) < n:
        if rid in ANCHORS:
            ax0, ax1, ay0, ay1 = ANCHORS[rid]
            x, y = random.uniform(ax0, ax1), random.uniform(ay0, ay1)
        else:
            cx, cy = random.choice(by_region[region[rid]])
            a, d = random.uniform(0, 2 * math.pi), REGION_REACH * math.sqrt(random.random())
            x, y = cx + d * math.cos(a), cy + d * math.sin(a)
        # ROUND FIRST, then validate. Rounding afterwards silently moves a point by up to
        # half a thousandth — which is enough to push one that passed a boundary check back
        # over it. That is exactly how a pin ended up at x=0.600 inside a snow corner
        # starting at 0.60, and how another landed a hair inside the clearance radius.
        # Validating the value that will actually be USED closes the whole class of bug.
        x, y = round(x, 3), round(y, 3)
        if valid(rid, x, y):
            out.append((x, y))
    return out


def radius_of(rid):
    """This rally's reveal radius — its authored `reveal_radius` if it has one, else the
    GameConfig default. Same resolution RallyLibrary.reveal_radius_of does in game."""
    return AUTHORED_RADIUS.get(rid, R)


def waves(pos):
    """Closure from the OPENING RALLIES: repeatedly light everything reachable and complete it.

    Lit sources are (position, radius) pairs, because each one lights its OWN circle. This
    assumed a single shared radius for every source, which silently ignored any rally
    authoring a wider `reveal_radius` — so the tool would report a rally as many waves deep
    while the game lit it immediately, and every pacing objective was optimising against a
    reveal graph the game does not have. RallyLibrary.lit_sources resolves per-source; so
    must this.

    Seeded from every starter's opening rally at once, matching
    RallyLibrary.reveal_depths: this is the geometry-only question, and whichever car the
    player picks their start is one of these. career() below asks the per-starter version,
    which seeds only the one."""
    lit = [(pos[i], radius_of(i)) for i in STARTS if i in pos]
    done, out = set(STARTS), [list(STARTS)]
    while True:
        fresh = [i for i in ids if i not in done
                 and any(math.dist(pos[i], c) <= rad for c, rad in lit)]
        if not fresh:
            return out, done
        out.append(fresh)
        for i in fresh:
            done.add(i)
            lit.append((pos[i], radius_of(i)))


# The unlock chain the geometry must respect: a part's prerequisite is gated on a rally
# that has to be REACHED no later than the rally gating the part itself. Extracted from
# UpgradeLibrary rather than hardcoded, plus the design rule that engine swapping is on the
# first special the map reaches. Constraining the pins is the right way round — the authored
# upgrade chain is design intent, the pin positions are what should bend to it.
ORDER = load_order()


def load_prize_value():
    """rally_id -> a 0..1 "how good is this reward" rank, for the radial ordering below.

    Cars rank on POWER-TO-WEIGHT (hp/tonne, from data/eligibility.json), so the map's outward
    gradient is literally "faster cars further away". reward_tier was tried first and is the
    wrong measure: it is a curated slot in the reward ladder, not a measure of pace, so cars
    of similar tier but very different speed sorted together and a quick one could land on
    HQ's doorstep.
    Parts rank on how deep they sit in their prerequisite chain, since a ladder's later rungs
    are strictly better than its earlier ones. Both are read from the libraries rather than
    listed here, so retuning a car's tier or re-pairing a part moves its pin next re-fit."""
    tier = json.load(open(ELIGIBILITY_PATH)).get("power_to_weight", {})
    ups = open(UPGRADES).read()
    ups = ups[ups.index("const UPGRADES:"):]
    gates, prereq = {}, {}
    for chunk in re.split(r"\n\t\{", ups):
        m = re.search(r'"id": "([a-z0-9_]+)"', chunk)
        if not m:
            continue
        g = re.search(r'"unlocked_by_rally": "([a-z0-9_]+)"', chunk)
        pr = re.search(r'"requires_upgrade_id": "([a-z0-9_]+)"', chunk)
        if g:
            gates[m.group(1)] = g.group(1)
        if pr:
            prereq[m.group(1)] = pr.group(1)

    def depth(item, seen=()):
        if item in seen or item not in prereq:
            return 0
        return 1 + depth(prereq[item], seen + (item,))

    raw = {}
    body = open(SRC).read()
    body = body[body.index("const RALLIES:"):]
    for m in re.finditer(r'"id": "([a-z0-9_]+)"', body):
        rid = m.group(1)
        seg = body[m.start():m.start() + 400]
        c = re.search(r'"prize_car": "([a-z0-9_]+)"', seg)
        if c:
            raw[rid] = float(tier.get(c.group(1), 0.0))
    # Normalise the CAR family on its own scale (hp/tonne) before folding in the parts,
    # which rank by ladder depth — merging the two raw is meaningless, since 349 hp/tonne and
    # "rung 4" are not comparable numbers.
    out = {}
    if raw:
        lo, hi = min(raw.values()), max(raw.values())
        span = max(hi - lo, 1e-6)
        out = {k: (v - lo) / span for k, v in raw.items()}
    part_depth = {gates[i]: 1.0 + depth(i) for i in gates}
    if part_depth:
        lo, hi = min(part_depth.values()), max(part_depth.values())
        span = max(hi - lo, 1e-6)
        for gate, v in part_depth.items():
            out[gate] = max(out.get(gate, 0.0), (v - lo) / span)
    return out


# --- Eligibility: can the player actually DRIVE what the map reveals? ---------
# Reaching a pin is only half of progression; the garage has to hold something that can
# enter it. Geometry alone cannot see that, so a layout can look perfectly paced and still
# soft-lock every player at wave two.
#
# The matrix comes from data/eligibility.json, generated by ./export_eligibility.sh with the
# game's REAL RallyLibrary.is_eligible. It is safe to compute once and reuse for the whole
# anneal because eligibility depends on restriction bands and cars — never on map_pos, which
# is the only thing being varied here. Regenerate it after retuning a band.
ELIGIBILITY_PATH = os.path.join(ROOT, "data", "eligibility.json")
try:
    _elig_raw = json.load(open(ELIGIBILITY_PATH))
except FileNotFoundError:
    raise SystemExit("missing %s — run ./export_eligibility.sh first" % ELIGIBILITY_PATH)

CAR_BIT = {c: 1 << n for n, c in enumerate(_elig_raw["cars"])}
STARTERS = _elig_raw["starters"]
# rally_id -> bitmask of the cars that can enter it, so "can the garage drive this?" is one
# AND. At ~60k annealing steps per seed the closure below runs constantly; sets or list
# comprehensions here were the difference between minutes and hours.
ELIGIBLE = {r: sum(CAR_BIT[c] for c in cars if c in CAR_BIT)
            for r, cars in _elig_raw["eligible"].items()}
PRIZE_CAR = {r: c for r, c in _elig_raw["prize_car"].items() if c}
# An unreachable rally is content no player can ever see — by far the worst thing a layout
# can do, so it dwarfs every pacing term.
UNREACHED_WEIGHT = 400.0

PRIZE_VALUE = load_prize_value()


def career(pos, starter):
    """Waves of rallies a player starting in `starter` can reach AND enter, and what is left
    over. The same closure sim_career.solve_reachability runs in-game, in bitmask form."""
    owned = CAR_BIT.get(starter, 0)
    lit = []                                # per-source radii — see waves()
    done = set()
    waves_out = []
    # THE OPENING RALLY IS ALREADY DONE (todo/opening-rally.md). The player is dropped into
    # the event awarding their starter straight from the picker, and it completes whatever
    # the result — so a walk that starts from HQ alone is modelling a state no player is
    # ever in, and would score a layout on whether the opening rally can be REACHED when in
    # fact it is where they begin.
    opening = OPENING_FOR.get(starter)
    if opening:
        done.add(opening)
        lit.append((pos[opening], radius_of(opening)))
    while True:
        fresh = [i for i in ids
                 if i not in done
                 and ELIGIBLE.get(i, 0) & owned
                 and any(math.dist(pos[i], c) <= rad for c, rad in lit)]
        if not fresh:
            break
        waves_out.append(fresh)
        for i in fresh:
            done.add(i)
            lit.append((pos[i], radius_of(i)))
            prize = PRIZE_CAR.get(i)
            if prize:
                owned |= CAR_BIT.get(prize, 0)
    return waves_out, [i for i in ids if i not in done]




def coverage_samples():
    """Points on usable ground the pin set should stay within reach of.

    Restricted to the ground the REGIONS actually claim: the NE snow corner holds no rallies
    by design, so leaving it empty is correct and must not be penalised as a gap."""
    out = []
    step = 1.0 / COVERAGE_GRID
    for gy in range(COVERAGE_GRID):
        for gx in range(COVERAGE_GRID):
            x = (gx + 0.5) * step
            y = (gy + 0.5) * step
            if not land_clearance(mask, x, y, 0.01):
                continue
            if not any(math.dist((x, y), p) <= REGION_REACH
                       for region_pins in by_region.values() for p in region_pins):
                continue
            out.append((x, y))
    return out


COVERAGE = coverage_samples()
# How far out the WEAKEST and STRONGEST prizes should sit, in normalised map units from HQ.
# Better rewards further out is the map's difficulty curve: the long drive to a corner is
# what makes the car at the end of it feel earned.
# The BEGINNER cluster: the three starter cars and the cheap kei runabout. These sit in a
# tight ring right by HQ regardless of where their power-to-weight would otherwise put them.
#
# They are not "the slowest prizes", they are the prizes a player is meant to collect while
# still learning the map, so they belong within a short drive of the garage. Ranking them on
# pace alone put the MX-5 a third of the way out — mid-pack by hp/tonne, but one of the first
# cars anybody should own. A separate band says the intent directly instead of hoping the
# speed curve happens to express it.
NEAR_GROUP_CARS = ["mx5", "focus", "twingo", "acty"]
PRIZE_RADIUS_NEAR = 0.13      # where the beginner cluster sits
# Everything else starts from MID, leaving a visible gap between the beginner ring and the
# rest — the map should read as "these four, then the world".
PRIZE_RADIUS_MID = 0.24
PRIZE_RADIUS_FAR = 0.42
# The rallies awarding a beginner-cluster car, resolved from the roster so re-pairing a prize
# moves the ring with it.
NEAR_GROUP_RALLIES = {r for r, c in PRIZE_CAR.items() if c in NEAR_GROUP_CARS}
# ...and they must be near in the GRAPH, not merely on the map. Distance from HQ turned out
# to be the wrong thing to optimise on its own: a beginner car parked 0.166 from HQ sits just
# outside HQ's 0.16 reveal circle, so it looks close and is still a long chain of rallies
# away. What the player experiences is DEPTH — how many wins until this opens — so the
# objective has to talk about links.
#
# The rule: every beginner prize should be lit by HQ itself or by the opening rally, i.e.
# reachable by the player's first or second win.
# Weighted hard enough that the gradient actually survives contact with the branching and
# spacing terms. At 30 it did not: a mid-pack car sat at 0.16 from HQ against a 0.23 target,
# which is exactly the "why is a fast car next to the garage" complaint.
PRIZE_RADIUS_WEIGHT = 120.0
# Prizes should also fan out AROUND the map rather than bunching. Each prize is pushed off
# every other prize's bearing from HQ; below this angular gap it costs.
PRIZE_BEARING_GAP = 0.55      # radians (~31 deg)
PRIZE_BEARING_WEIGHT = 12.0
# BRANCHING of the reveal graph. The failure this exists to stop is the single chain:
# A unlocks B unlocks C unlocks D, each pin with one way in and one way out. However
# elegantly it is drawn, that is a corridor — the player is walked down it with no decision
# to make, which defeats the whole point of an explorable map.
#
# The measure is NODE DEGREE, not geometry. An earlier attempt penalised the ANGLE at each
# joint, on the theory that a straight-looking line was the problem; it was not. A chain is
# just as much a chain when it curves, and the fitter dutifully produced a winding one. What
# makes a map explorable is that pins have SEVERAL neighbours, so completing one opens a
# choice.
#
# Watch the edge count in the report: 31 edges over 32 pins is a tree — minimally connected,
# average degree under 2, i.e. chains almost everywhere.
# --- Proposal moves ----------------------------------------------------------
# The annealer originally had ONE move: teleport a pin to a random legal spot anywhere in
# its region. That explores well and refines not at all — late in the run, when the
# temperature is low, virtually every proposal is a big disruptive jump that gets rejected,
# so the search stalls long before it finishes.
#
# So most proposals are now a LOCAL JITTER whose radius shrinks with temperature: broad
# nudges early, fine ones at the end, which is what lets a good arrangement settle into its
# own floor instead of only ever being found whole. A minority stay teleports, because a
# purely local search cannot cross the map to a better basin.
JITTER_SHARE = 0.75            # fraction of proposals that are a nudge rather than a jump
JITTER_START = 0.07            # nudge radius at full temperature (map units)
JITTER_END = 0.005             # ...and at the end, roughly the authoring precision
# How deep in the GRAPH a rally may sit — hops from HQ, not distance across the table.
# Those are different things, and depth is the one the player feels: a pin can look close and
# still be eight wins away because nothing lights the ground between. A roster where the last
# rallies sit ten hops out means the final third is only reached by grinding a long chain,
# whichever direction you picked.
#
# A PREFERENCE, not a limit: it is squared past the target, so being a hop over is cheap and
# being five over is not.
# The two objectives are arithmetically COUPLED: 32 rallies over N waves averages 32/N per
# wave, so a shallow map is necessarily a wide one. 6 waves means ~5.3 rallies per wave,
# which is well above TARGET (2) — that trade is deliberate here, because a rally ten hops
# out is reached only by grinding one long thread, whichever direction the player chose.
# TARGET above is kept in step with this — see the note there.
#
# Set this ABOVE the map's natural depth and the term never fires: at 10 the deepest rally
# was exactly wave 10, so the penalty contributed 0.0 and the objective was silently inert.
# Check it is actually biting before trusting a result.
DEPTH_TARGET = 5
# Was 12, the weakest term in the cost — it lost to branching and coverage even when it did
# fire. Depth is a headline property of the map, so it is weighted to match.
DEPTH_WEIGHT = 30.0
DEGREE_TARGET = 3              # neighbours a pin should have, so finishing it opens a choice
DEGREE_WEIGHT = 10.0
ENGINE_SWAP_RALLY = "front_runners"
# Wave 1 is exactly ONE rally: the opening event beside the garage. That works because
# "Upgrade: Engine Swap" (id front_runners) is fully open-class — no class field and an
# empty restriction, since a special must never gate on what it unlocks — so a single lit
# rally strands nobody. It used to take TWO — an RWD intro
# and an FWD one — purely because each opening rally admitted only one kind of car.
# test_every_starter_car_can_enter_something_on_a_fresh_profile enforces the guarantee;
# this constraint is how the geometry gets there.
# Each starter's opening rally: the event awarding that car, the one it begins inside.
# Inverted from PRIZE_CAR rather than listed by hand, exactly as the game derives it
# (RallyLibrary.opening_rally_id_for), so a re-paired prize moves both together.
#
# This replaced OPENING_RALLIES — a single intro every starter had to be able to enter on
# turn one. There is no such rally now: each starter has its own opening, so the layout no
# longer has to reserve a universally-enterable pin beside HQ.
OPENING_FOR = {car: rid for rid, car in PRIZE_CAR.items()}
# The map's starting lights: one opening rally per starter the game offers. Nothing else
# is lit on a fresh profile, HQ included.
STARTS = [OPENING_FOR[c] for c in STARTERS if c in OPENING_FOR]
# Hand-placed rallies: a box (x_min, x_max, y_min, y_max) a specific pin must stay inside.
#
# For when the LAYOUT wants something the objectives cannot express — here, filling the
# stretch of table directly south of HQ, which read as an empty band. Pinning them and
# re-running is the right move rather than moving them by hand afterwards: they are load-
# bearing connectors, so relocating them in isolation strands half the roster, and only a
# re-fit can rebuild the chain around their new homes.
ANCHORS = {
    "hm_forest_gt": (0.30, 0.50, 0.56, 0.72),   # Win: Rondel Twist  — south-west of HQ
    "hm_hatch_cup": (0.50, 0.70, 0.56, 0.72),   # Win: Honcho Actus  — south-east of HQ
}
SPECIALS = [i for i in ids if i.startswith("sp_") or i.endswith("showdown")]


def cost(pos):
    # PACING IS MEASURED ON THE ELIGIBILITY-AWARE WALK, not the geometric one.
    #
    # These used to read waves(), which assumes the player can drive anything they can see.
    # That is a model of the map, not the map: measured against it this roster was 5 waves
    # deep, while a Twingo player actually took 8 and reached one rally six waves later than
    # geometry claimed. Tuning depth or wave size against the optimistic number means tuning
    # something nobody experiences.
    #
    # The representative walk is the WORST starter's — the map has to be decent whichever
    # car you picked, so optimising the average would let one starter's career stay bad while
    # the others carried the score.
    #
    # It costs: career() runs once per starter instead of one shared closure, so this is the
    # expensive part of the cost function now.
    c = 0.0
    careers = {}
    for starter in STARTERS:
        careers[starter] = career(pos, starter)
        c += UNREACHED_WEIGHT * len(careers[starter][1])
    worst = max(STARTERS, key=lambda st: len(careers[st][0]))
    ws, stuck = careers[worst]
    done = set(ids) - set(stuck)
    # Geometric reachability still counts: a pin no circle can reach is broken for reasons
    # that have nothing to do with cars, and career() cannot distinguish that from "no car
    # fits it yet".
    geo_ws, geo_done = waves(pos)
    c += 500.0 * (len(ids) - len(geo_done))
    # The unlock chain is constrained on BOTH walks. The career walk is what a player
    # experiences, but RallyLibrary.reveal_depths — the geometric one — is what the game
    # itself reports and what the roster tests assert on, so a layout satisfying only the
    # career order still fails the suite. They genuinely disagree: eligibility can hold a
    # rally back for waves after geometry has lit it, reordering pairs in the process.
    geo_depth = {}
    for n, w in enumerate(geo_ws, 1):
        for i in w:
            geo_depth[i] = n
    for a, b in ORDER:
        if a in geo_depth and b in geo_depth and geo_depth[a] > geo_depth[b]:
            c += 120.0 * (geo_depth[a] - geo_depth[b])
    depth = {}
    for n, w in enumerate(ws, 1):
        for i in w:
            depth[i] = n
    # The upgrade chain must be satisfiable in reveal order.
    for a, b in ORDER:
        if a in depth and b in depth and depth[a] > depth[b]:
            c += 120.0 * (depth[a] - depth[b])
    # Engine swapping opens on the first special the map reaches.
    if ENGINE_SWAP_RALLY in depth:
        earliest = min(depth[i] for i in SPECIALS if i in depth)
        c += 120.0 * (depth[ENGINE_SWAP_RALLY] - earliest)
    if ws:
        c += 40.0 * (len(ws[0]) - TARGET) ** 2 / TARGET  # wave 1 is an ordinary wave now
        for w in ws[1:]:
            c += (len(w) - TARGET) ** 2                 # every later wave near TARGET
    # DIRECTIONAL SPREAD. A wave whose new rallies all sit the same way from the frontier
    # is not a choice — the player is being handed a corridor and told to walk it. Penalise
    # waves whose pins share a bearing (measured from HQ), so unlocking two rallies means
    # two directions worth considering.
    for w in ws[1:]:
        if len(w) < 2:
            continue
        angles = [math.atan2(pos[i][1] - HQ[1], pos[i][0] - HQ[0]) for i in w]
        widest = 0.0
        for a in range(len(angles)):
            for b in range(a + 1, len(angles)):
                d = abs(angles[a] - angles[b]) % (2 * math.pi)
                widest = max(widest, min(d, 2 * math.pi - d))
        # Full credit once a wave spans SPREAD_TARGET radians; short of that it costs.
        c += SPREAD_WEIGHT * max(0.0, SPREAD_TARGET - widest) ** 2
    # Spacing is NOT scored here — it is a hard constraint enforced at move time
    # (see `spaced`), so no arrangement the annealer can reach ever violates it.
    # PRIZE LAYOUT. Two objectives, both only over the prize pins:
    #
    #   RADIAL — a prize's distance from HQ should track how good it is, so the map reads as
    #   a difficulty gradient outward rather than a scatter.
    #
    #   ANGULAR — prizes should fan out around HQ instead of bunching, so that whichever way
    #   the player heads there is something worth reaching that way. This is what makes
    #   "choose a direction" a real choice rather than a formality.
    # (The beginner prizes used to carry a LINK term pulling them within one win of the
    # shared opening rally. They are the openings now — each is where its own starter
    # begins — so being close to a rally the player may never drive means nothing. Their
    # RADIAL term below still keeps them near HQ.)

    prizes = [i for i in ids if i in PRIZE_VALUE]
    for i in prizes:
        want = (PRIZE_RADIUS_NEAR if i in NEAR_GROUP_RALLIES
                else PRIZE_RADIUS_MID + (PRIZE_RADIUS_FAR - PRIZE_RADIUS_MID) * PRIZE_VALUE[i])
        c += PRIZE_RADIUS_WEIGHT * (math.dist(pos[i], HQ) - want) ** 2
    bearings = {i: math.atan2(pos[i][1] - HQ[1], pos[i][0] - HQ[0]) for i in prizes}
    for a in range(len(prizes)):
        for b in range(a + 1, len(prizes)):
            d = abs(bearings[prizes[a]] - bearings[prizes[b]]) % (2 * math.pi)
            d = min(d, 2 * math.pi - d)
            if d < PRIZE_BEARING_GAP:
                c += PRIZE_BEARING_WEIGHT * (PRIZE_BEARING_GAP - d) ** 2

    # COVERAGE. Penalise usable ground left far from every pin, so the map fills out instead
    # of ringing HQ and leaving a bare band the player pans across for nothing.
    for sx, sy in COVERAGE:
        nearest = min(math.dist((sx, sy), pos[i]) for i in ids)
        if nearest > COVERAGE_REACH:
            c += COVERAGE_WEIGHT * (nearest - COVERAGE_REACH) ** 2

    # DEPTH. Penalise rallies buried far down the chain, so the map stays broad rather than
    # long — reachable by spreading out from HQ instead of by walking one thread to its end.
    for n, wave in enumerate(ws, 1):
        if n > DEPTH_TARGET:
            c += DEPTH_WEIGHT * len(wave) * (n - DEPTH_TARGET) ** 2

    # BRANCHING. Build the link graph (the same "within reveal radius" rule the map draws
    # its dotted lines from) and penalise every pin that falls short of DEGREE_TARGET
    # neighbours. Squared, so one badly isolated pin costs more than several slightly thin
    # ones — a lone pin on the end of a thread is the worst case, being a dead end.
    links = {i: 0 for i in ids}
    for a in range(len(ids)):
        for b in range(a + 1, len(ids)):
            ia, ib = ids[a], ids[b]
            if math.dist(pos[ia], pos[ib]) <= max(radius_of(ia), radius_of(ib)):
                links[ia] += 1
                links[ib] += 1
    for i in ids:
        if links[i] < DEGREE_TARGET:
            c += DEGREE_WEIGHT * (DEGREE_TARGET - links[i]) ** 2

    # Light pull home, so the map keeps its authored shape where it can.
    c += 1.5 * sum(math.dist(pos[i], orig[i]) ** 2 for i in ids)
    return c


def spaced(cand, placed, rid):
    """Is `cand` far enough from every OTHER pin in `placed`? MIN_SPACING in general, and
    the wider PRIZE_MIN_SPACING when both pins are prizes.

    A HARD constraint, checked before a move is ever scored, rather than a penalty in the
    cost. As a cost term the annealer would trade a spacing breach against a better wave
    profile and settle just under the floor — it did exactly that, landing at 0.0498 against
    a 0.05 rule. Two pins closer than this overlap their hit spheres and their readouts, so
    "nearly far enough" is not a thing: the constraint either holds or the map has a pin the
    player cannot reliably select."""
    rid_is_prize = rid in PRIZE_VALUE
    for other, p in placed.items():
        if other == rid:
            continue
        floor = PRIZE_MIN_SPACING if (rid_is_prize and other in PRIZE_VALUE) else MIN_SPACING
        if math.dist(cand, p) < floor:
            return False
    return True


def anneal(pos, iters=60000, t0=6.0, t1=0.02, seed=0):
    rng = random.Random(seed)
    pool = {i: candidates(i) for i in ids}
    # Start from a state that already SATISFIES spacing, since the move rule below can only
    # preserve it, never repair it. Each pin keeps its authored spot when that spot is legal
    # (valid ground, and clear of everything placed so far) and otherwise takes the nearest
    # candidate that is — so the run starts from the authored map wherever it can.
    cur = {}
    for i in ids:
        here = pos[i]
        if valid(i, *here) and spaced(here, cur, i):
            cur[i] = here
            continue
        ok = [q for q in pool[i] if spaced(q, cur, i)]
        if not ok:
            raise SystemExit(
                "no position for %s satisfies spacing (%.3f, prizes %.3f) — the map is too "
                "crowded for its constraints; loosen REGION_REACH or reduce the floors"
                % (i, MIN_SPACING, PRIZE_MIN_SPACING))
        cur[i] = min(ok, key=lambda q: math.dist(q, here))
    cc = cost(cur)
    best, bc = dict(cur), cc
    for k in range(iters):
        t = t0 * (t1 / t0) ** (k / iters)
        rid = rng.choice(ids)
        old = cur[rid]
        # Cooling fraction, 1 at the start falling to 0 — the same curve the acceptance
        # test uses, so the moves get finer exactly as the search gets pickier.
        cool = (t - t1) / max(t0 - t1, 1e-9)
        if rng.random() < JITTER_SHARE:
            reach = JITTER_END + (JITTER_START - JITTER_END) * cool
            ang = rng.uniform(0, 2 * math.pi)
            dist = reach * math.sqrt(rng.random())
            cand = (round(old[0] + dist * math.cos(ang), 3),
                    round(old[1] + dist * math.sin(ang), 3))
            # A nudge is not drawn from the pre-validated pool, so it has to be checked.
            if not valid(rid, cand[0], cand[1]):
                continue
        else:
            cand = rng.choice(pool[rid])
        # Reject rather than score: a proposal that stacks pins is not a worse arrangement,
        # it is not an arrangement.
        if not spaced(cand, cur, rid):
            continue
        cur[rid] = cand
        nc = cost(cur)
        if nc <= cc or rng.random() < math.exp((cc - nc) / t):
            cc = nc
            if nc < bc:
                best, bc = dict(cur), nc
        else:
            cur[rid] = old
    return best, bc


def report(pos, label):
    ws, done = waves(pos)
    sizes = [len(w) for w in ws]
    print("\n--- %s ---" % label)
    print("waves: %s" % sizes)
    # Edge count and degree say whether the map BRANCHES or is one long chain — the thing
    # wave sizes alone cannot show, since a chain and a fan can produce identical waves.
    deg = {i: 0 for i in ids}
    for a in range(len(ids)):
        for b in range(a + 1, len(ids)):
            ia, ib = ids[a], ids[b]
            if math.dist(pos[ia], pos[ib]) <= max(radius_of(ia), radius_of(ib)):
                deg[ia] += 1
                deg[ib] += 1
    thin = sum(1 for i in ids if deg[i] < DEGREE_TARGET)
    print("links: %d edges, mean degree %.2f, %d pin(s) under %d neighbours"
          % (sum(deg.values()) // 2, sum(deg.values()) / len(ids), thin, DEGREE_TARGET))
    print("reached %d/%d, %d waves, mean after the first %.2f"
          % (len(done), len(ids), len(ws),
             (sum(sizes[1:]) / max(1, len(sizes) - 1))))
    for n, w in enumerate(ws, 1):
        print("  %2d (+%d): %s" % (n, len(w), " ".join(sorted(w))))
    return sizes


if __name__ == "__main__":
    report(orig, "current roster")
    best, bc = None, 1e18
    for s in range(int(sys.argv[1]) if len(sys.argv) > 1 else 3):
        p, c = anneal(orig, seed=s)
        print("seed %d -> cost %.1f" % (s, c))
        if c < bc:
            best, bc = p, c
    report(best, "optimised (cost %.1f)" % bc)
    print("\n--- paste into RallyLibrary.RALLIES ---")
    for i in sorted(best):
        print('  %-24s "map_pos": Vector2(%.3f, %.3f),' % (i, best[i][0], best[i][1]))
