# Multiplayer lobby

**Source:** `scripts/multiplayer/round_clock.gd`,
`scripts/multiplayer/lobby_round.gd`,
`scripts/multiplayer/lobby_standings.gd`, `scripts/cloud/lobby_board.gd`,
`scripts/multiplayer/lobby_session.gd`

**Tests:** `tests/headless/test_round_clock.gd`,
`tests/headless/test_lobby_round.gd`,
`tests/headless/test_lobby_standings.gd`, `tests/headless/test_lobby_clock_offset.gd`,
`tests/headless/test_lobby_board.gd`

A drop-in, round-based multiplayer mode. One global lobby; every player races the
same seeded stage in the same loaner car, round after round. Joining at any moment
is legal and **racing immediately is the default** — a round awards nothing, so
start-line fairness is not worth parking a new arrival; spectating is offered, not
imposed. A round ends when everyone still racing has finished (or DNF'd), or at a
wall-clock ceiling, whichever comes first.

Design spec: `docs/superpowers/specs/2026-08-18-multiplayer-lobby-design.md`.

## There is (almost) no server

Every value clients must agree on is a pure function of the wall clock — with ONE
deliberate exception, `lobby_state/current` (below), which lets rounds end early.
Everything else is computed independently on each device. `RoundClock` is that function: `round_index(unix)`
says which round is running, `round_key(i)` names it, `seed_for(key)` turns the
name into the content seed, and `bounds(i)` gives the half-open interval the round
occupies. Nothing here does I/O.

This is the same trick `ChallengeLibrary` uses for the Daily/Weekly/Monthly
challenge, and it is why the lobby needs no host, no matchmaking and no lobby code.

`LOBBY_EPOCH` is **permanent once shipped**. Changing it renumbers every client's
rounds, so two builds would disagree about which round is running while both
believed they agreed.

`ROUND_SECONDS` is a tunable and no test pins its value — the tests assert that the
derivation holds for whatever it is set to.

## The round's content

`LobbyRound.stage_for(key)` rolls the stage off one RNG seeded from the round seed —
the same one-advancing-stream structure as `ChallengeLibrary.stages_for`, so the
whole dict is a deterministic function of the key. **The draw order is part of the
contract:** reordering those lines changes every round's content, so new fields go
at the end.

`LobbyRound.car_id_for(key)` picks the loaner car by seeding into a **sorted** list
of catalogue ids. Sorting is deliberate — `CarLibrary.CARS`'s authored order is not
a contract, so indexing it raw would silently re-roll every round's car the first
time someone reordered the table.

## Clock skew

Every round boundary and every timestamp is only as good as the device's clock, so a
phone twenty seconds fast races a *different round* than everyone else while believing
it shares theirs. It produces no error — just a player alone in a lobby that looks
broken.

`RestClient` therefore surfaces the HTTP `Date` header as `date_ms` on every response
(0 when absent), `RoundClock.offset_from(server_ms, local_ms)` turns that into a
correction, and `LobbySession` applies it to **both** the round-boundary maths and
every timestamp it reads or writes. An absent `Date` yields an offset of 0 rather than
a correction back to 1970.

## Extrapolating the field

Nobody's position is known exactly — every racer is a progress sample up to three
seconds old. `LobbyStandings.extrapolate` carries a sample forward by its own posted
speed and clamps it to the track. Carrying **speed** in the sample is what makes the
3-second cadence look live; differentiating two samples instead would leave every
client a full interval behind and blind to a racer's first update.

**Units are the hazard.** `progress_m` is metres, `speed_mms` is mm/s. Metres / mm/s
yields *kilo*seconds, so `gap_ms` multiplies by `1_000_000`, not `1000` — a 1000x slip
still looks almost right on a slow car, which is how it would ship. The arithmetic is
done in floats: `speed_mms * elapsed_ms / 1e6` in integers truncates to zero for
anything under about a metre of travel, freezing slow racers on the spot.

**The sort key is composite** — finishers first by `finish_ms`, then racers by
extrapolated distance, then DNFs. Distance alone cannot work: extrapolation clamps at
the finish line, so every finisher ties, and the standings would freeze wrong in the
last thirty seconds of a round.

Note that a lobby `dnf` means **"did not finish before the round boundary"** — a
round-clock outcome, not a damage one. Cars can no longer be wrecked, so there is no
wreck signal to hang it on.

## The collection, and what it does not promise

`lobby_rounds/{round_key}/racers/{uid}` — one document per player per round, seven
fields, all int or string. That type restriction is not incidental: `FirestoreCodec`
supports only string/int/bool, and the shape was chosen so no new encoder is needed.

World-readable so a signed-out player can spectate; owner-only write; no delete. The
rules validate **shape**, never truth — there is no server-authoritative simulation to
check claimed progress against, so a client can post any position it likes. That is
acceptable only because a lobby round awards nothing. Attaching a reward here later
needs a trusted server path first, not a config change.

## Reading and writing the field

`LobbyBoard.post(round_key, sample, identity)` PATCHes one document — the player's own
— with an `update_mask`, because a Firestore PATCH without one is a full replace that
succeeds silently while clobbering. `LobbyBoard.fetch(round_key)` runs one
**descending** `runQuery` limited to `FIELD_LIMIT` rows. The direction is load-bearing:
ascending returns the slowest racers, so on a busy lobby the leader would never appear.

`POST_*` enumerates every no-write outcome, so a player who is not appearing can always
be told why. `POST_SIGNED_OUT` costs zero requests — spectating without an account is a
supported state, not a failure.

Speeds and distances are clamped non-negative **at the write**, so the rules' guard
stays a backstop. A car reversing after a crash would otherwise have its write rejected
and freeze on every other player's screen.

## The tick

`LobbySession` (autoload) runs one timer at `TICK_SECONDS`. Each tick is **two REST
calls**: a PATCH of the player's own document and one descending `runQuery` for the
field. No aggregation counts and no own-document GET — the client already knows what
it last wrote. That is half the cost of a `Leaderboard.fetch`.

States are `idle -> spectating -> racing`, plus `offline`. Offline is not an exit: the
mode keeps running on the last known field, so a network blip mid-round does not throw
someone out of a race they are winning. **Signed-out is a flag, not a state** — such a
player traverses the same states with posting disabled; modelling it as a state would
duplicate every transition.

**Nothing in the lobby reads the system clock directly.** `now_ms()` is the only clock,
and it carries the server offset learned from response `Date` headers.

Note the autoload convention: like `RallySession` and `ChallengeSession`, this script
declares **no `class_name`** — a `class_name` matching the singleton name collides with
the autoload in Godot 4. Tests reach it via
`preload("res://scripts/multiplayer/lobby_session.gd")`.

## The loaner car

The car is fielded in `world.gd`'s fielding chain, **not** in `DrivingContext`. This is
worth knowing because the obvious guess is wrong: `driven_car()` is only consulted by
`start_line.gd`'s repair/refit paths, so branching there alone would field the default
library car while reporting the loaner.

The lobby branch copies the free-roam one — `CarLibrary.index_of(id)` ->
`$Car.apply_car(idx)` — fielding a bare catalogue model. No owned-car dict, no `Save`
read, no instance id, nothing written back, so a lobby round cannot corrupt or inflate
a career profile and a player with an empty garage can race immediately.

`DrivingContext.session_active()` counts a lobby round, so it gets stage config and dev
cheats rather than being mistaken for free roam. `active_car_instance_id()` still
returns `-1` and `driven_car()` still returns `{}` — deliberately. You cannot repair a
loaner.

## Round identity: the one shared document

`lobby_state/current` holds `{round_index, started_at_ms}` — the single piece of
shared mutable state in the mode. It exists for two player-facing reasons: a round
**ends early** once every live racer has settled, and a **dead lobby restarts the
moment someone walks in** instead of making them wait out a phantom round.

The write race between clients advancing the same round is settled in
`firestore.rules`, not client code: an update must **strictly increase**
`round_index`. Both racers write the same next index, the second is rejected, and
the loser adopts the winner's round on its next read (`POST_REJECTED` is a normal
outcome, never retried blindly). Monotonicity also means nobody — confused or
malicious — can wind the round counter back.

`RoundClock` remains the **bootstrap** (the first player ever creates the document
from the clock-derived index) and the **fallback** (a failed read, or a signed-out
player, still yields a drivable round). `LobbySession.poll_round()` is the local
failsafe: a round can never outlive `MAX_ROUND_MS` on any client, which is what
unwedges a lobby whose last racer quit without posting.

Known consequence, accepted: a signed-out player cannot write, so a lobby holding
only signed-out spectators sits on a finished round until the ceiling fires or
someone who can write arrives. That is inherent to having no anonymous auth.

## Joining

`LobbySession.enter(spectate := false)` applies a join table — every path except
an explicit spectate choice starts the player racing with no wait:

| Lobby state on entry | Result |
|---|---|
| No state document has ever existed | Bootstrap it from the clock, race now |
| Stored round older than the ceiling | Advance to a fresh round, race now |
| Round live | Join it now (`joined_late()` marks entries past `LATE_JOIN_FRACTION`) |
| State read failed | Fall back to the clock-derived round, race now, write nothing |

`joined_late()` is informational — the standings can flag a provisional entrant so
their placing is explainable, but a late join is never refused.

Liveness feeds all of this: `LobbyStandings.live_racers(rows, now_ms, stale_ms)`
drops a RACING row silent past the threshold (a quit, a crash, a dead network) while
exempting finishers, whose silence is completion. `all_finished(live)` is then the
early-end condition — deliberately false for an empty field, so an empty lobby does
not advance itself round after round for no one.
