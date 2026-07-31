# Global Leaderboards (optional, per-stage)

Every driven stage can post the player's time to a **world leaderboard for that
exact stage** — one Firestore document per player per stage. Same optionality
contract as [cloud-save.md](cloud-save.md): a signed-out player, an offline
player, or a player who never picks a display name still plays the whole game
untouched. Design: `docs/superpowers/specs/2026-07-31-global-leaderboards-design.md`
— read the deviations below before trusting that file; the code won.

## Layout

| File | Responsibility |
|---|---|
| `scripts/cloud/leaderboard.gd` (`Leaderboard`) | `Cloud.leaderboard`. Submit-if-faster + a 3-call fetch (top-3 query, own entry, rank/total aggregations). Knows nothing about rallies or cars — a stage key, a time, and an identity dict in; a plain result dict out. |
| `scripts/cloud/firestore_codec.gd` (`FirestoreCodec`) | Pure Firestore REST value encode/decode + `update_mask()`. Extracted out of `CloudSync` because the two traps below were previously duplicated (once in `CloudSync.to_document`, once in its private `_int_field`). Both `CloudSync`'s user document and `Leaderboard`'s stage entries now go through this one file. |
| `scripts/global_standings.gd` (`GlobalStandings`) | Page 2 of the between-event standings interstitial — see [menus.md](menus.md). |
| `scripts/username_popup.gd` (`UsernamePopup`) | The one-field modal that captures a display name, **and** owns the `profile["username"]` read/write statics. |
| `scripts/rally_library.gd` › `stage_key` | The pure static that turns a rally + event index into the board's key. |
| `scripts/track_cache.gd` › `BOARD_EPOCH` | The manual version stamp folded into every `stage_key` — see [track.md](track.md) → *Turn cache*. |
| `firestore.rules` › `stage_times/{stage}/times/{uid}` | The one world-readable collection in the whole database. |

## The data model

One document per player per stage, at `stage_times/{stage_key}/times/{uid}`.
The parent `stage_times/{stage_key}` document need not exist — Firestore
subcollections are implicit.

| Field | Type | Meaning |
|---|---|---|
| `name` | string | The player's chosen display name (`UsernamePopup`), 1–16 chars |
| `car_name` | string | Display name of the car they drove that stage |
| `car_id` | string | The bare `CarLibrary` model id |
| `time_ms` | int | The stage time. Always `> 0` — a DNF never reaches a write (see below) |
| `updated_utc` | string | Display only; nothing branches on it |

The row is NOT keyed by rally id + event index directly — `stage_key` hashes
the event's own generation parameters (see below), so the identity of "this
stage" survives a rally being re-ordered or renamed in `RallyLibrary.RALLIES`.

### `stage_key` — a wire format, not a display string

`RallyLibrary.stage_key(rally, event_index)`:

```
"%s__%d__%s__e%d" % [rally_id, event_index, event_hash, TrackCache.BOARD_EPOCH]
```

where `event_hash` is a 12-char SHA-256 prefix over the event dict's own keys,
sorted and joined as `"key=value"` pairs with `|`. This makes the key a
**wire format identical in spirit to `TrackCache.cache_key`**: anyone who
changes what goes into the hash — reorders fields, changes a value's string
formatting, adds/removes an event field — silently produces a *different* key
for what is conceptually the same stage. Existing posted times become
permanently unreachable orphans under the old key, and the stage starts back
at zero. The only sanctioned way to force that reset on purpose is bumping
`TrackCache.BOARD_EPOCH`, exactly the same lever `CACHE_VERSION` is for the
turn cache — see [track.md](track.md).

## Submit-then-fetch

`Leaderboard.submit_and_fetch(stage_key, time_ms, identity)` is the one call
the UI makes. It:

1. Skips straight to `fetch()` (a read with no write) if the player is signed
   out, has no display name, or `time_ms <= 0` (the DNF case).
2. Otherwise reads the player's own existing entry (`_read_own`) — the only
   document that can answer "is this an improvement?", since the top-3 query
   usually won't contain them.
3. Writes only if `time_ms` beats the stored one (or there isn't one yet), via
   a `PATCH` with an explicit `updateMask` over exactly the five rule-allowed
   fields.
4. Fetches the board (`fetch`) and returns it with `posted` set.

### Diagnosing "my time didn't post" — `post_state`

Every path through `submit_and_fetch` (and the plain `fetch`) ends in exactly
one `post_state`, attached to the returned result and logged once as
`"Leaderboard: <state> stage=<key> uid=<uid> — <detail>"` (`push_warning` for
the two failure states, a plain log otherwise). This is the diagnostic trail
for a player or a developer asking "why is my time not on the board" — eight
distinguishable no-write conditions, one line each:

| `post_state` constant | Meaning |
|---|---|
| `POST_POSTED` | A document was written |
| `POST_NOT_FASTER` | Existing entry is already as good — correct, not a failure |
| `POST_SIGNED_OUT` | No account, so nowhere to write |
| `POST_NO_USERNAME` | Signed in but never chose a name |
| `POST_NO_TIME` | DNF, or no player row in the standings |
| `POST_NO_KEY` | The caller had no stage identity |
| `POST_DENIED` | The rules refused the write (401/403) — logged with `firestore.rules` named explicitly, since this is the one state that means "go check the rules," not "the network hiccuped" |
| `POST_FAILED` | Offline / 5xx / 429 / unreadable response |

**This replaces the earlier "benign 403" behaviour** (a prior revision of this
doc, and the code before it, treated a `PATCH` 403 as always benign — "another
device won the race"). It no longer is: a 403 now always resolves to
`POST_DENIED`, is named in the log, and is surfaced on the result — the board
still stays usable and nothing blocks, but the failure is no longer silently
swallowed. The old assumption (a 403 can only mean a benign write-race against
the rules' improvement-only backstop) turned out to be one failure mode among
several a 403 can mean, and the silent version made a genuine rules
misconfiguration indistinguishable from an ordinary race.

**Debugging note:** Firestore parent documents are implicit, so
`stage_times/{stage_key}` shows up in the console greyed-out/italic with no
fields of its own — the `times` subcollection needs an extra click through to
see. "I see no leaderboard collection in the console" is therefore consistent
with writes succeeding; don't take it as evidence the write failed.

`fetch()` alone (no submission) is a 3-Firestore-call read:

- `_run_query` — top `Leaderboard.PODIUM_ROWS` (3) entries by `time_ms`
  ascending, via `runQuery`. Only the automatic single-field index is needed —
  no composite index to deploy.
- `_read_own` — the player's own document (404 is the expected "never posted
  here" answer, not a failure).
- `_count` (called twice) — `runAggregationQuery` COUNT, once for "how many
  entries beat mine" (→ rank) and once unconditionally for the board total.
  COUNT comes back as an `integerValue`, i.e. a JSON string — see
  `FirestoreCodec`'s trap #2.

Every failure mode — offline, timeout, 5xx, 429, a rules denial, an
unparseable body — collapses to one `{"ok": false}` result. There is
deliberately no retry loop and no popup: **nothing here may cost a player
their rally.**

A signed-out fetch sends no `Authorization` header at all and still gets top
rows + total back, because the collection is world-readable; it just never has
a `player_row`.

## `display_rows` — where it actually lives (spec deviation)

The spec placed the display-assembly function on `GlobalStandings`. **The code
puts it on `Leaderboard` as a pure static**, `Leaderboard.display_rows(rows,
player_row)`, tested next to the fetch calls that produce its inputs rather
than inside the UI page. It takes the fetched top rows and the player's own
row and returns: the top rows verbatim; nothing extra if the player is already
on the podium (same row, not printed twice); a `{"gap": true}` marker + the
player's row if they rank below `PODIUM_ROWS + 1`; just the player's row with
no gap if they're immediately below the podium.

This is deliberately **not** `Standings.visible_rows` — that function needs
the complete ranked field to place the player inside it, and a top-N +
aggregate fetch never has one.

## Row shape — `combined_ms`, not `time_ms` (spec deviation)

`Leaderboard._row_from_document` maps a Firestore document into
`UITheme.standings_row`'s shape, which uses **`combined_ms`** as its time key
(there being one stage in it, not a sum) even though the Firestore field
itself is `time_ms`. This makes a global row render through the exact same
row widget as a local standings row with zero special-casing — the only
translation is at this one boundary.

## `GlobalStandings` — page 2 of the interstitial

Shown by `Standings._advance()` (`scripts/standings.gd`) after page 1 (the
local combined standings), as a sibling `Control` that **replaces** page 1's
content rather than living beside it — see [menus.md](menus.md) for the
navigation contract. `for_current_stage()` gathers everything the page needs
(`stage_key`, `stage_number`, `time_ms`, `car_name`, `car_id`, `dnf`) from
`RallySession` in one place so the host stays a two-line hand-off.

### States

| State | When | What's shown |
|---|---|---|
| `LOADING` | Always, first frame | "Loading…" |
| `SIGNED_OUT` | Fetch ok, `signed_in == false` | The board + "Sign in to post time" button (opens `AccountMenu` as an in-page overlay; success re-runs the fetch in place, so the just-set time posts without re-driving) |
| `NO_USERNAME` | Signed in, `UsernamePopup.current() == ""` | The board + "Choose a name to post" button (opens `UsernamePopup`) |
| `POSTED` | Signed in, has a name, fetch ok | The board with the player's own row/rank |
| `UNAVAILABLE` | `ok == false` from the fetch, OR no `stage_key`, OR headless with no test `fetcher` | One dim "Leaderboard unavailable" line — no popup, no retry |

An empty board (nobody has posted to this stage yet) renders **"No times
posted yet"** in place of any rows, in every non-loading, non-unavailable
state.

### The total line (spec deviation)

The spec described the total rendered inline, `"(of 312)"`, next to a rank.
**The code renders it as a separate dim tail line** appended after the row
list:

- `"P%d of %d times posted"` when the player has a rank this session
  (`_state == POSTED and _rank >= 1`)
- `"%d times posted"` otherwise (signed out, no name, or no rank yet)

This line is shown in **every** successful state, signed-out included — it's
the one number that tells a player whether an empty-looking board is actually
empty or just far above them.

### DNF (spec deviation / clarification)

`configure()` forces `time_ms = -1` when the host passes `dnf: true`. That
`time_ms <= 0` guard in `submit_and_fetch` means nothing is ever posted for a
DNF stage — but the page still opens and still shows the world's board for
that stage, just with no player row and nothing written on the player's
behalf.

### No Back button after the reward path (spec deviation / clarification)

`show_back` is set by the host (`Standings._show_global_page`) to
`is_instance_valid(_root_box)`. After the per-event reward reveal has run,
page 1's root VBox has already been torn down and replaced by the (now spent)
`UpgradeReveal` card — there is no page 1 left to return to — so page 2 shows
**Continue only**, no Back. `GlobalStandings._on_back` is a no-op guard
(`if not show_back: return`) rather than relying on the host to never wire the
button in that case.

### No staggered reveal (spec deviation — a real bug, fixed)

The spec (§6) asked for the same P1-downward staggered reveal page 1 uses.
The FIRST implementation built that: `_build_body` put every body node —
rows AND the total line — into a reveal list, hid them all up front, and a
`_reveal()` coroutine un-hid them one per `REVEAL_STEP` timer tick (skipped
under `Platform.is_headless()` so tests saw a populated list).

**That coroutine is the whole page's content path, and if it doesn't run to
completion the player sees nothing between the heading and Continue** — no
rows, no total line, not even "No times posted yet" or "Leaderboard
unavailable". A player hit exactly this in real play: a completely blank
page 2. The fix removed the reveal entirely rather than making it more
robust — `_build_body` now returns `void`, adds every node visible
immediately, and always adds at least one line (a row, the empty-board
message, or the unavailable message). `_reveal`, `_reveal_gen`,
`REVEAL_STEP`, and the `Platform.is_headless()` visual gate are all deleted
from `global_standings.gd`.

Justification for dropping the reveal rather than reviving it: the page is
already gated behind a multi-request network fetch (so there's already a
pause before it appears), and page 1 — one screen earlier in the same
interstitial — already delivers the staggered-reveal feel the spec wanted.
Don't re-add a reveal here without weighing that this exact failure mode is
what it costs.

**Process lesson:** the reveal was skipped under `Platform.is_headless()`,
so tests exercised a DIFFERENT code path than the one a real player's game
ran — the headless path always populated the list instantly; only the
non-headless path could go blank. A green suite therefore could not have
caught this: nothing ever ran what the player ran. Worth a wider look at
`features/testing.md` for other `Platform.is_headless()` visual gates with
the same shape — that decision is out of scope for this file (not one of
the six this doc-pass owns).

### The `fetcher` test seam

`GlobalStandings.fetcher: Callable` substitutes for
`Cloud.leaderboard.submit_and_fetch` in tests — same `(stage_key, time_ms,
identity) -> Dictionary` signature. **Headless with no fetcher set goes
straight to `UNAVAILABLE`** rather than reaching for the network
(`Platform.is_headless() or Cloud == null or Cloud.leaderboard == null`) — this
is the same "never touch the network in a test" contract the rest of cloud
save uses, so a test that wants to see `POSTED`/`SIGNED_OUT`/etc. must inject
`fetcher` explicitly.

## `UsernamePopup`

A `ConfirmPopup`-shaped modal (dim backdrop, centred house panel, `MenuNav`
wiring) built on `TextField`. Deliberately named `UsernamePopup`, not `Popup`
— Godot already has a `Popup` class.

- **Not unique.** Two players may both be `KANGAROO`. There is no reservation
  document and therefore no "name taken" state.
- **Owns the profile accessors** (`UsernamePopup.current()` / `.store()` /
  `.sanitize()`), rather than `save_manager.gd` — every caller (`account_menu.gd`,
  this popup, `GlobalStandings`) goes through one sanitiser. This is a
  spec deviation: the spec put the accessors on `Save`.
- `sanitize()`: uppercase (`UITheme.caps`), filtered to `A–Z 0–9 space`,
  interior double-spaces collapsed (so `"A      B"` can't fake a blank name),
  trimmed, capped at `MAX_LEN = 16`. Pure + static, tested with no popup built.
- The key is `Save.profile["username"]`, backfilled to `""` by `Save._migrate`
  with **no `SCHEMA_VERSION` bump** — see [cloud-save.md](cloud-save.md)'s
  `cloud_revision`/`unsynced` precedent for the same backfill-not-bump pattern.
- **Deliberately dismissable.** Cancel, Esc and gamepad B (`UsernamePopup._on_cancel`)
  close it writing nothing, and declining does NOT reopen it on the next
  rebuild — the caller's `finished` handler just re-renders with whatever
  username still is (blank or not). Reasoning, verbatim from the implementer:
  "A player who signed in for cloud save shouldn't be held hostage by a text
  field, and this would be the game's first inescapable dialog." A player who
  declines can still get back to it two ways: the global standings page's own
  fallback prompt (below), or Settings → Account.

## Capturing the display name — two tiers (design changed after real play)

The original design (and this doc, until this revision) had ONE capture
point: a button on the global standings page, offered only once the board had
successfully loaded and reported the player as signed-in-but-nameless. **That
had a chicken-and-egg trap**, found by a real player: the button's `_state`
gate (`SIGNED_OUT`/`NO_USERNAME`) is only reachable after a *successful*
fetch — a failed read lands in `UNAVAILABLE`, which offers no prompt at all.
The very first player on a brand-new board is the likeliest to hit a failing
read (an empty collection, an as-yet-undeployed parent doc, a network blip),
so exactly the player who most needs prompting would never be, would never
post, and the board would stay empty forever. The fix is now two-tier:

1. **PRIMARY — capture at sign-in.** `account_menu.gd:_maybe_prompt_username`
   opens `UsernamePopup` immediately after a SUCCESSFUL sign-in
   (`Cloud.sign_in_email`, `Cloud.register_email`, `Cloud.sign_in_google`) when
   `profile["username"]` is still blank. Wired explicitly into all three
   sign-in handlers (`_on_sign_in_pressed`, `_on_register_pressed`,
   `_on_google_pressed`) — **deliberately NOT hooked into the shared
   `_finish()`**, because `_finish()` is also the exit for Sync now, password
   reset, and conflict resolution, none of which should raise a name prompt.
   This is the kind of wiring someone "simplifies" later by hoisting it into
   `_finish()` and quietly breaks — don't. Guarded by `MenuNav.is_on_screen(self)`
   (not `is_visible_in_tree`, which misses a hidden `CanvasLayer` ancestor),
   since the popup is a layer-101 `CanvasLayer` that must never be raised from
   a page parked inside a hidden overlay.
2. **FALLBACK — the global standings page prompt.** For players who signed in
   BEFORE this feature existed, so have a blank username and no sign-in event
   ever coming their way again. `GlobalStandings._prompt_kind()` now decides
   whether to show "Sign in to post time" / "Choose a name to post" from
   **LOCAL facts alone** — `_signed_in` (captured from the last successful
   fetch's `signed_in` field, or `Cloud.is_signed_in()` if there has been
   none) and `UsernamePopup.current() == ""` — **NOT from the fetched board
   state**. That decoupling from the fetch outcome is exactly what closes the
   trap above: the prompt is offered even when the board failed to load.
   `_prompt_kind()` returns `""` (no prompt) whenever `time_ms <= 0` — a DNF
   has nothing to post, so there is nothing to prompt for.

The cursor is seated on the prompt button, not Continue, whenever one is
showing (`_build_ui`'s `seat := _action_button if _action_button != null else
cont`) — a prompt a player has to spot and aim at is one most players skip
past, and skipping it here means a silent non-post with nothing to notice.

## Security rules — the one world-readable collection

`firestore.rules` gains `match /stage_times/{stage}/times/{uid}`:

- **`allow read: if true`** — unconditional. This is the ONLY collection in
  the whole database readable without auth; `users/{uid}` and everything else
  stay pinned to `request.auth.uid == uid`. It's safe specifically because the
  document shape is minimal by design: a chosen display name, a car name/id,
  and a time — no email, no uid-derived identity beyond the document's own id
  (which is already public in the same sense a Firestore doc id always is).
- **`allow create`/`allow update`**, both gated on `request.auth.uid == uid`
  and a `validEntry()` shape check (`hasOnly` + `hasAll` on exactly the five
  fields, `time_ms` bounded `0 < time_ms < 86400000`, string length caps). The
  `update` rule additionally requires `request.resource.data.time_ms <
  resource.data.time_ms` — a **server-side improvement-only backstop**. The
  client (`Leaderboard._write_entry`) already declines to write a slower time
  itself, so in ordinary play this rule never fires; it exists for the race
  where two devices post for the same stage between one client's read and its
  write. That race is only ONE of the things a 403 can mean, though — see
  `post_state`/`POST_DENIED` above — so the client no longer assumes benign
  and swallows it; it is surfaced and logged like any other denial.
- **`allow delete` is absent.** No client, including the owning uid, can
  remove an entry — its own or anyone else's.

## Tests

- `tests/headless/test_cloud_leaderboard.gd` — submit-if-faster decision logic,
  the 3-call fetch assembly, `display_rows` trimming (podium / gap / adjacent),
  `_row_from_document` field mapping, error classification, and the full
  `post_state` matrix (all eight no-write conditions plus `POST_POSTED`).
- `tests/headless/test_rally_library.gd` — `stage_key`'s determinism and
  sensitivity to its inputs (rally id, event index, event fields, `BOARD_EPOCH`).
- `tests/headless/test_rally_session.gd` — `_player_car_name` now routes through
  `EngineSwap.display_name` — see [rally-session.md](rally-session.md).
- `tests/headless/test_save_manager.gd` — the `"username"` key's backfill onto
  older profiles.
- `tests/headless/test_menu_flow.gd`, `test_menu_nav.gd` — the page-2 hand-off
  from `Standings._advance`, and its keyboard/gamepad navigation — see
  [menus.md](menus.md).

## Manual verification (needs a human)

Nothing network-facing here is exercisable headlessly.

- [ ] Finish a stage signed out → board reads, sign-in button present.
- [ ] Sign in from the page → the just-set time posts without re-driving.
- [ ] First post prompts for a name; the name appears on the board.
- [ ] Re-drive slower → no write, board unchanged. Faster → entry updates.
- [ ] Airplane mode → "Leaderboard unavailable", Continue still advances.
- [ ] Two accounts on one stage → both appear, ranked correctly.
- [ ] Rules deployed: an unauthenticated read succeeds, a cross-uid write is
      denied.
- [ ] **The blank-page fix itself is UNVERIFIED in real play.** The bug (page
      2 rendering nothing between the heading and Continue) was found by a
      player, not by a headless probe — the probe that would have reproduced
      it hung while the test suite held the project, so the fix (deleting the
      reveal coroutine — see above) is by elimination/code-reading, backed
      only by its new test, not by having watched the bug reproduce and then
      go away. Finish a stage for real and confirm the board body — rows, the
      total line, or the empty/unavailable message — actually renders on page
      2, every time, with no blank frame.
- [ ] The exact `runQuery` / `runAggregationQuery` response envelopes
      (`_run_query`, `_count`) were coded from the REST API spec and have
      **never been exercised against a live Firestore** — only against the
      fake REST client in tests. Confirm the real response shape matches
      (array of `{document: {...}}` for an empty-collection sentinel with no
      `document` key; `[{result: {aggregateFields: {count: {integerValue:
      "N"}}}}]` for the aggregation) the first time this runs live.
- [ ] `firestore.rules`' `stage_times` block has **never been deployed or
      exercised** — it has only been read for shape by eye. Confirm the CI
      `deploy-rules` job (see [cloud-save.md](cloud-save.md)) actually pushes
      it and that the live rules match this file.
