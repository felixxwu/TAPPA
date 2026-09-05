# Cloud Save (optional account)

An **optional** account backs the player's career up to Firebase and lets them
continue it on another device. Signing in is never required: a player who
ignores it sees no change at all, and every failure mode here degrades to "you
keep playing locally".

**Tests:** `tests/headless/test_cloud_auth.gd`, `tests/headless/test_cloud_sync.gd`, `tests/headless/test_cloud_boot_gate.gd`, `tests/headless/test_account_menu.gd`, `tests/headless/test_save_manager.gd`, `tests/headless/test_firestore_rules.gd`

`user://profile.json` remains the **source of truth for the running session**
(see [save-persistence.md](save-persistence.md)). The cloud holds a copy.

Backend: Firebase project **`tapparally`**, using the **REST APIs** over
`HTTPRequest` — Identity Toolkit for auth, Firestore for the document. There is
no Godot Firebase SDK in use, and none is wanted: REST behaves identically on
web, Android, Windows and macOS, which is exactly the property this needs.

## Layout

| File | Responsibility |
|---|---|
| `scripts/cloud/cloud_manager.gd` | The **`Cloud` autoload** — the facade the game talks to. Owns the other four. |
| `scripts/cloud/firebase_config.gd` | `FirebaseConfig` — project id, API key, OAuth client ids, endpoint builders. |
| `scripts/cloud/rest_client.gd` | `RestClient` — the ONLY `HTTPRequest` in the project. The test seam. |
| `scripts/cloud/auth_service.gd` | `AuthService` — sign-in, token refresh, credential storage, error mapping. |
| `scripts/cloud/cloud_sync.gd` | `CloudSync` — Firestore document encoding, the conflict model, debounce/backoff. |
| `scripts/cloud/google_sign_in.gd` | `GoogleSignIn` — the OAuth dance (two platform implementations). |
| `scripts/account_menu.gd` | `AccountMenu` — the UI, hosted by the Settings page (and, as an inline overlay, by the standings page's sign-in prompt). |
| `scripts/text_field.gd` | `TextField` — the project's first text input (see [menus.md](menus.md)). |
| `scripts/cloud/firestore_codec.gd` | `FirestoreCodec` — the Firestore REST value encode/decode + `update_mask()` shared by this document AND the leaderboard's, extracted out of this file (see the deleted global leaderboards). |
| `firestore.rules` | Security rules, kept in git rather than only in the console, and deployed by CI. **One collection, `challenge_runs`, is world-readable** — a signed-out player has to be able to see the challenge board. `stage_times` (the per-stage global leaderboards) and the two `lobby_*` collections went with their features; the file grants them nothing now. Structurally guarded by `tests/headless/test_firestore_rules.gd` — see below. |
| `firebase.json` / `.firebaserc` | Point the Firebase CLI at `firestore.rules` and the `tapparally` project. |
| `.github/workflows/deploy.yml` › `deploy-rules` | Deploys the rules on change (and on manual dispatch). |

**Dependency direction: `Cloud` → `Save`, never the reverse.** `Save` emits
`profile_changed` / `flushed` and knows nothing about who is listening, so the
save layer and its tests behave identically whether or not cloud save exists.

## Authentication

Two methods, both through Identity Toolkit REST:

- **Email + password** (`accounts:signInWithPassword` / `signUp`), plus password
  reset via `accounts:sendOobCode`.
- **Google** (`accounts:signInWithIdp`) — see below.

**Anonymous ("guest") sign-in was deliberately NOT built**, despite Firebase
offering it and it being an obvious third option. It would protect against
nothing here. A guest account's only credential is the refresh token in
`user://auth.json`, which sits beside the profile it is meant to be insuring:
lose the device or reinstall, and both go together, leaving the cloud document
permanently orphaned. The one scenario cloud save exists for is the one guest
mode cannot cover. Its other supposed benefit — "link later and keep your
career" — is already what ordinary sign-up does, since the first sign-in pushes
whatever progress is on the device. Not signing in IS the no-account state; it
needs no button. Do not add it back without a reason that survives that
argument.

### Google sign-in — one native flow, one web flow

**Native (Windows, macOS, *and Android*): loopback redirect + PKCE.** Bind a
`TCPServer` on `127.0.0.1` (port 0, never `0.0.0.0`), `OS.shell_open` Google's
consent screen with `redirect_uri=http://127.0.0.1:<port>`, catch the single
inbound GET, verify the `state` nonce, and exchange the code with the PKCE
verifier. No client secret — a desktop OAuth client is a public client and PKCE
is what authenticates the exchange.

Including Android in this path is the single biggest simplification in the
design: the obvious alternative (a custom URL scheme / deep link) needs an
`AndroidManifest` intent-filter, which needs a custom Godot Android build, which
this project does not have. A loopback listener needs none of it.

**Android caveat — the player must return to the game.** Handing off to the
system browser BACKGROUNDS the game, and Godot stops running frames while
backgrounded, so `_await_callback` (which polls the listener once per frame)
cannot accept the browser's redirect. The connection is queued by the OS and
completes the instant the player switches back — nothing is lost — but until
they do, Google's "Continue" page spins forever, which reads as a hang.
Confirmed by measurement on 2026-07-31: switching back to the game completes the
sign-in immediately.

The interim answer is to say so: `GoogleSignIn.waiting_message()` returns
"Approve in your browser, then RETURN TO THE GAME to finish" on touch devices,
and the loopback page's response text says "Return to TAPPA to finish". The
proper fix is to accept the connection off the frame loop (a `Thread`), so the
browser completes on its own; that is a contained change to `_await_callback`
and is worth doing if this flow proves annoying in practice.

The `permissions/internet=true` flag on BOTH Android presets in
`export_presets.cfg` is required — without it Android blocks `HTTPRequest` *and*
binding the loopback listener, which presents as "no connection" plus
"couldn't start the sign-in listener".

**Web: a top-level popup, landing on a GitHub Pages callback.** `window.open`
to Google's auth endpoint with `response_type=id_token`, redirecting to
`docs/oauth-callback.html` (served at `felixxwu.github.io/TAPPA/` by the
`deploy-pages` job), which `postMessage`s the token back to the game window and
closes. Driven over `JavaScriptBridge` with the same `create_callback` +
member-held-handle pattern as `save_manager.gd`'s lifecycle hook.

`response_type=id_token` rather than an authorization code, because a code has
to be exchanged for tokens and Google requires a `client_secret` for **Web**
clients — which a browser cannot hold. The implicit response returns a signed ID
token directly, which is what `AuthService` needs; `nonce` guards replay and
`state` is verified before the token is accepted.

**Google Identity Services was tried first and does not work on itch.** One Tap
renders inside the calling document, which there is itch's iframe, and FedCM
refuses without an `allow="identity-credentials-get"` grant from the *embedding*
page — itch's markup, not ours. Measured with the origin correctly authorised:
`NotAllowedError: The 'identity-credentials-get' feature is not enabled in this
document`. A popup is a top-level browsing context, so none of that applies.
Do not "simplify" this back to GIS.

### Credential storage — the trap

Tokens live in **`user://auth.json`**, never in the profile.

`profile["settings"]` is *inside the blob uploaded to Firestore*. A refresh token
parked there would publish a long-lived credential into the database and
replicate it to every other device on the account. `auth.json` holds the refresh
token, uid and email; the short-lived `id_token` is kept in memory
only and never written; the password is never stored anywhere.
`test_cloud_auth.gd` asserts all three of those.

## The Firestore document

One document per user: `users/{uid}`.

| Field | Type | Meaning |
|---|---|---|
| `profile` | string | The profile JSON, verbatim |
| `schema_version` | integer | `Save.SCHEMA_VERSION` at write time |
| `revision` | integer | Monotonic; +1 per successful push |
| `updated_utc` | string | For display only — nothing branches on it |
| `device` | string | `web` / `android` / `windows` / `macos` — for the conflict prompt |

Storing the profile as **one opaque blob** is deliberate: the existing local
migration machinery (`Save._migrate`, `_sanitise`) applies to a downloaded blob
unchanged, so there is no hand-written Firestore field mapping to keep in step
with the schema forever.

**Security posture:** `users/{uid}` is pinned to `request.auth.uid == uid` for
both read and write — nobody, including another signed-in player, can read
this document but its own owner. That stays true after global leaderboards
landed. The ONE exception in the whole database is a *different* collection,
`stage_times/{stage}/times/{uid}`, which is world-readable by design so a
signed-out player can see a leaderboard — see
the deleted global leaderboards for what that collection
holds and why making it public is safe (short version: it never carries
anything from this `users/{uid}` document — no email, no profile blob, just a
chosen name/car/time).

Encoding lives in the pure statics `CloudSync.to_document` / `from_document`,
which build the document SHAPE (which five fields, in what order) and delegate
the actual value tagging/mask-building to `FirestoreCodec` (see
the deleted global leaderboards for why that split exists).
Note that Firestore encodes `integerValue` as a JSON **string** (so 64-bit values
survive JSON); decoding it as a number would silently yield 0 and break every
revision comparison. `PATCH` always carries an explicit `updateMask.fieldPaths`,
without which Firestore treats the write as a full replace.

## Conflict model — revisions, not clocks

"Newest wins" needs an ordering, and wall-clock time is not one: a phone and a
desktop routinely disagree, and one wrong clock would silently eat the other
device's career.

Two profile fields carry the state, both backfilled by `_migrate`'s key backfill
so **no `SCHEMA_VERSION` bump was needed**:

- **`cloud_revision`** (int, default 0) — the document revision this profile last
  agreed with.
- **`unsynced`** (bool, default false) — does this device hold changes the cloud
  has not accepted? **Persisted on purpose**: progress made offline must still
  read as unsynced after a relaunch, or the next pull would see "cloud ahead,
  local clean" and quietly discard a whole offline session.

`Save.save()` sets `unsynced`; `Save.mark_synced()` clears it and writes
immediately.

| Cloud | Local | Action |
|---|---|---|
| No document (404) | any | Push local |
| `revision <= cloud_revision` | clean | Nothing |
| `revision <= cloud_revision` | unsynced | Push |
| `revision > cloud_revision` | clean | Download and apply |
| `revision > cloud_revision` | unsynced, **no cars** | **Auto-restore the cloud** (see below) |
| `revision > cloud_revision` | unsynced | **Conflict → ask the player** |
| `schema_version > SCHEMA_VERSION` | any | Refuse; do not push either |
| blob unparseable | any | Report; never overwrite the remote copy |

### The one case that is resolved automatically: a wiped local save

If both sides moved on but **this device has no cars at all**, there is no dilemma
to put to the player — the local "progress" is a blank save (a reset, a clear, a
reinstall), and the only thing taking the cloud can cost them is an empty garage.
Asking there is actively harmful: it presents a fresh blank profile as an equal
alternative to a real career, and one mis-tap on "keep this device" uploads the
blank straight over it. So `CloudSync.pull` takes the cloud copy itself
(`_local_is_wiped() and _remote_has_progress(remote)` → `apply_remote(remote, true)`),
still writing the `profile.json.conflict.bak` backup.

**Keyed on CARS, not on `starter_picked`.** A car is the one thing a career cannot
exist without — the starter pick grants one before anything else can happen — so an
empty garage means the save is blank regardless of what other flags survived. It also
covers the reported case exactly: signed in, progress gone, and the game happily
offering a starter car while the real career sat in the cloud.

Both guards matter. A wiped local against a wiped **cloud** is a genuine
nothing-to-choose-between and still prompts, and if `apply_remote` fails the code
falls through to the normal prompt rather than leaving sync silently blocked.

### The progress wipe must clear the cloud too

`Settings -> Reset progress -> Wipe all progress` calls `Save.reset_new_game()`, which only
clears THIS device. On its own that wipe silently undoes itself: the next pull sees
a clean local against an ahead cloud and downloads everything back — and with the
wiped-local auto-restore above it does so without even asking. So `_wipe_progress`
follows the local reset with `Cloud.publish_local_wipe()` →
`CloudSync.push_wipe()`, which force-pushes the blank profile over the remote copy
and discards any pending conflict (the local side of that decision no longer
exists). It runs behind the shared `CloudBusy` cover and says so in the reset page's
status line, including when the cloud clear FAILED — "it may come back" is the honest
report, because it will. Signed out it is a no-op: there is no cloud copy to clear.
The confirm modal names the cloud consequence too (`_prompt_wipe_progress` appends the
"other devices" sentence only while signed in) — this is a player-facing button now,
so "will this take my cloud save with it?" has to be answered before the press, not
after.

The conflict prompt is a `ConfirmPopup` with legible summaries produced by
`CloudSync.describe_profile` ("5 cars, 12 rallies completed") rather than raw
revision numbers:

- **Keep this device** — push at `remote.revision + 1`, so the other device sees
  a clean "cloud is ahead" next time.
- **Use cloud** — apply the downloaded profile, after writing
  `profile.json.conflict.bak`. Deliberately a *separate* filename from the
  rolling `.bak`, which the next ordinary write consumes within seconds.
- **Decide later** (also the back action) — sync stays paused with a warning on
  the Account page. Explicitly **not** a silent pick of either side.

A downloaded profile goes through `Save.adopt_profile`, i.e. the same
migrate + sanitise path as a local file, so cloud data is never less validated
than disk data.

## Sync triggers

Push is debounced **~8 s** (distinct from Save's ~1 s local debounce: a disk
write is free, a network round trip is not) and flushed immediately on
`Save.flush_and_sync()`. That last point matters: the existing web
`visibilitychange`/`pagehide` listeners and the native close/pause notifications
already funnel through that one entry point, so the cloud path inherits
tab-close and app-pause handling on every platform **with no new lifecycle
plumbing**.

Pull happens at sign-in and on `NOTIFICATION_APPLICATION_RESUMED`.

Failures back off exponentially (2 s → 60 s, jittered). The retry queue is a
single "dirty" bit, not a list of operations — the payload is always the whole
current profile, so a retry can never apply stale data.

### `RestClient` is PROCESS_MODE_ALWAYS (a paused game still talks to the cloud)

`HTTPRequest` drives its transfer from an internal process callback, so it obeys
`process_mode` / `get_tree().paused`. `Cloud` is an autoload — a child of the root
with `PROCESS_MODE_INHERIT`, which at the root means *pausable* — so any request
started while the tree was paused simply stopped progressing:
`await _http.request_completed` never fired and the awaiting caller hung forever.

That is reachable from every pause screen, because `pause_menu.gd` sets
`get_tree().paused = true` and its embedded `SettingsMenu` can start real cloud
calls (the reset page's `_wipe_progress` → `Cloud.publish_local_wipe`, the account
page's sign-in/out). The symptom was `CloudBusy`'s full-screen cover going up and
never coming down — "Wipe all progress" from a mid-run pause looked *stuck*. A screen that
never paused the tree worked fine, which is why it took a while to see.

`RestClient._ready` therefore sets `process_mode = PROCESS_MODE_ALWAYS`; its
`HTTPRequest` child inherits it. Fixed at the one place that owns the socket, so
every cloud caller is covered rather than each pause screen unpausing by hand.
Covered by `test_cloud_auth.gd` →
`test_rest_client_keeps_running_while_the_tree_is_paused`.

### Web: gzip must be left to the browser

`RestClient` sets `accept_gzip = false` on the web build. The browser already
decompresses a gzip response before Godot sees it, but `HTTPRequest` still reads
`Content-Encoding: gzip` and decompresses a second time — which fails on the
already-plain body with `RESULT_BODY_DECOMPRESS_FAILED` (transport code 8) on an
HTTP **200**.

Google's endpoints gzip their responses, so this broke EVERY cloud request on
the web build — email and Google sign-in alike — and surfaced to the player as
"No connection", which sent the investigation towards CORS for some time. If web
requests ever start failing on a 200 again, check this first.

Native keeps gzip enabled: there the engine owns the transfer and handles it
correctly.

### Refreshing live UI after a download

A pull that REPLACES the local profile (first sign-in on a new device, or "Use
cloud" on a conflict) changes the career out from under a running HQ. `CloudSync`
emits **`profile_replaced`**, re-emitted by `Cloud`. The deleted `hq.gd` rebuilt on it
(`_on_cloud_profile_replaced`): clearing its car cache, rebuilding the lineup or the lift
car depending on the view, and refreshing the map pins.

**`HubShell` does not connect to it.** Its pages are rebuilt on every transition
(`_show()` frees and rebuilds), so a page opened after the download is correct — but a
page already on screen when it lands shows a stale money figure or car list until the
player navigates. Minor next to the boot-gate gap below, and the same fix would cover it.

**The handler no-ops until the HQ exists (`_hq_built`).** `_ready` connects
`profile_replaced` *before* it awaits the boot pull — it has to, since that pull is
what emits the signal — so on a signed-in boot the handler fires while `_pins_root`,
`_overlays` and the lineup are all still null. Rebuilding them there crashed
(*"Cannot call method 'get_children' on a null value"*, intermittent: only when the
cloud copy actually replaced the local profile at boot). There is nothing to do in
that window anyway — `_build_hq()` runs straight after the await and constructs every
one of those views from the profile the signal just settled. Pinned by
`test_cloud_boot_gate.gd` →
`test_a_download_landing_during_the_boot_wait_does_not_touch_an_unbuilt_hq`.

Without it the player signs in, their cars are restored *on disk*, and the car
park still shows the empty lot they started with until they relaunch — the save
worked but nothing on screen said so. Distinct from `state_changed`, which is
only about sync status.

## Error handling

| Failure | Behaviour |
|---|---|
| Offline / timeout / 429 / 5xx | Queue, back off, "not synced". No popups mid-race. |
| Refresh rejected (auth) | Sign out locally, one notice, local play untouched |
| Refresh failed (network) | Retry; **do not** sign out |
| 401 / 403 | Named plainly with the code — a rules misconfiguration, not a player error |
| Cloud schema newer | Refuse to apply *or* overwrite; "update the game" |
| Cloud blob unparseable | Report; leave the remote copy alone |
| `Save.save_disabled` | Cloud sync still runs — blocked local storage is when it matters most |

## UI

`AccountMenu` is one builder with two hosts, mirroring how `SettingsMenu`
already works:

- **Settings → Account** (`settings_menu.gd`: `_build_account_page`,
  `show_account`, an entry in `_pages` and in the category grid). This is the
  canonical route, reachable from the title screen's Settings button before any
  career is started — which is the reinstall / new-device case.
There were two other hosts, both deleted: the standings page's inline sign-in prompt
(`global_standings.gd`), which mounted the same widget so a player could sign in without
leaving the leaderboard, and — before that — a dedicated Account button on the title row
with its own modal layer. The second was removed deliberately: the Settings page already
covered the same need from the same screen, and two routes into one optional-cloud-save
form is one more than a title screen needs.

Signed out: Google (hidden when unconfigured) / sign in with email / create an
account. There is deliberately no "continue without an account" button — that is
what closing the page does, and the Back button already says so. Signed in:
identity, sync status, leaderboard name, Sync now, Sign out.

**Row budget.** A host that puts `AccountMenu` in a CENTRED `VBoxContainer` with its
Back button BELOW the widget lets any content that overflows a small screen push Back
off the bottom, where it cannot be pressed — the shape the old title-screen host had.
`AccountMenu._build_main` carries a "ROW BUDGET" comment on this account, and every row
it adds has had to justify itself against it:

- `_ready()` uses `UITheme.GAP_TIGHT` rather than `UITheme.GAP` for the page's
  own separation — this page stacks more rows than any other menu.
- Sync status and "last synced" used to be two separate lines; they are now
  one row ("UP TO DATE · 12:34 UTC"), with graceful fallback to whichever half
  exists when the other is missing.
- The leaderboard name used to be a `Label` row ("Online leaderboard name:
  FELIX") sitting above the button that changes it — two rows saying the same
  word twice. The name now rides directly on the button's own text
  ("Leaderboard name: FELIX", or "Set a leaderboard name" when unset, with a
  tooltip explaining what it does), collapsing the pair into one row.

`tests/headless/test_account_menu.gd` asserts the signed-in view stays under a
row-count bound for exactly this reason, and asserts the leaderboard name is
reachable from a *button's* text rather than a label.

Signing out needs no confirm and **never touches the local profile**: nothing is
destroyed, the career on the device carries on, and the cloud copy is reachable
again by signing back in.

## Boot-time race: the gate, and its MISSING CONSUMER

> **READ THIS FIRST: nothing waits for the boot pull any more.** Every consumer described
> below was on `hq.gd`, and the diegetic hub is deleted (decision 9). `HubShell._ready`
> awaits nothing — it builds its MAIN page immediately. The `Cloud` half of the mechanism
> is intact, live and tested (`test_cloud_boot_gate.gd`); what is gone is the caller.
>
> **The hazard is therefore real again**, in a new shape: the starter picker that made it
> concrete is deleted too (decision 28 hands a fresh profile money and sends it to the car
> shop), but the hub lets a returning player **buy a car or start a run** the instant it
> opens, and either writes the profile and marks it `unsynced` — which is exactly what
> turns an arriving download into a conflict prompt over a career they never lost.
> Re-wiring it is a small change with a UI question attached (what does the player look at
> while it waits?), which is why stage 9 flagged it rather than inventing an answer.

**The race.** `Cloud._ready` calls `auth.restore()` then defers `_kick_off_initial_pull` —
a network round trip. The game reaches an interactive screen in about a second, well before
that pull can land. A returning player on a new device could therefore act on a profile
that is about to be replaced; the write marks it `unsynced`, the pull lands with
`remote_revision > agreed_revision` and `local_moved == true`, and `CloudSync.pull` reads
that as a genuine conflict. The player is asked to choose between their whole career and
the one thing they just did, and either answer loses data.

**Waiting for the pull is not sufficient on its own.** The pull can settle as a CONFLICT
(both sides moved on), in which case the download was NOT applied and a real career may be
sitting in the cloud right now. The old gate released anyway and offered the starter pick —
and picking one WRITES to the profile, so "keep this device" stopped meaning "keep what I
had" and started meaning "keep the fresh save I was just handed". A player hit exactly
this: signed in, progress apparently lost, happily allowed to pick a starter, conflict
popup never shown. **So a consumer must check `ConflictPrompt.is_blocked()` after the
wait**, not just the wait itself.

**Gating the BUILD costs an offline player nothing**, which is the non-obvious part and
the reason the old hub gated its title too: `initial_pull_pending` is *already* false for
anyone without a stored credential, so the narrow gate is free. Without it the screen was
built from the LOCAL profile and then visibly rebuilt a second or two later, and the player
watched their garage pop in.

### The surviving mechanism (`cloud_manager.gd`)

- `initial_pull_pending: bool` — armed `true` in `_ready`, right before the deferred
  kick-off, but ONLY when there is a stored credential to restore. No credential means it
  is never set and nothing downstream waits at all.
- `initial_sync_settled` (signal), `INITIAL_SYNC_WAIT_SEC := 8.0`.
- `await_initial_sync(timeout_sec)` — polls the member `initial_pull_pending` in a loop
  and returns `not initial_pull_pending`, up to the hard cap. Never cancels the pull
  itself; it just stops waiting on it.
- `_settle_initial_sync()` — clears the flag and fires the signal. Called on EVERY pull
  outcome (success, 4xx, 5xx, transport failure) and on `sign_out`, so nothing can leave
  the gate armed forever.

**A real bug lived here first:** `await_initial_sync` originally watched a local
`settled := false` flipped by a lambda connected to the signal. GDScript lambdas capture
outer locals BY VALUE, so the lambda's write never reached the outer `settled` — every
signed-in player sat through the full 8-second cap even when their pull finished in 200 ms.
The fix deletes the closure rather than boxing it in a holder dict: polling the shared
member directly means there is nothing left to capture, so the class of bug cannot recur
here. Worth remembering elsewhere in this codebase: **a lambda closing over a plain local
to receive a signal's result is the shape to be suspicious of** — a member field or a
one-element array/dict survives value capture, a bare local does not.

### What a consumer owed, when there was one

The deleted `hq.gd` did four things, and a re-wiring owes the same four:

1. **Await before building**, so the screen is built once from the settled profile
   (`_await_boot_pull` → `_build_hq()`), re-labelling the loading screen already on screen
   rather than stacking a second cover.
2. **Await again before any profile-writing action**, and **re-check the state
   afterwards** — the pull may have delivered a real career while it waited.
3. **Check `ConflictPrompt.is_blocked()`** and block on an unsettled conflict: "decide
   later" means no new career begins, "use cloud" restores the real one.
4. **React to a download that lands anyway** (`_on_cloud_profile_replaced`) by backing out
   of whatever would double-write.

Two invariants it must not break, both still pinned in `test_cloud_boot_gate.gd`: a pull
that never lands still reveals the screen (the cap is the backstop), and a pull that
settles as a conflict still reveals it, with the conflict live for the next step to catch —
gating the build must not swallow the prompt.

Tests: `tests/headless/test_cloud_boot_gate.gd` — the guaranteed zero-wait exit, the
hard-cap timeout, settling on every pull outcome and on sign-out, and idempotent settling.
Its 15 HQ-routing tests went with the hub; see [testing.md](testing.md).

## Waiting on the network: `CloudBusy`

Every `await Cloud.*` call site is bracketed by a shared busy state
(`scripts/cloud/cloud_busy.gd`, `class_name CloudBusy`, static — no autoload). Before
it existed each screen invented its own waiting UI or none: a player resolving a sync
conflict tapped a button and got silence for the length of a full profile upload, and
the completion-reward fetch at the end of a challenge run showed nothing at all.

Two shapes, chosen by what the call does:

- **`CloudBusy.cover(host, title, step)`** — a blocking full-screen `LoadingScreen`,
  for calls that rewrite the profile or gate progression: conflict resolution, the
  boot restore, the challenge completion-reward fetch.
- **`CloudBusy.ambient(host, text, container = null)`** — non-blocking, for reads
  behind already-rendered UI (the account page's message row, the leaderboard fetches).
  With no `container` the host already draws its own waiting line and only the marker
  is added, so two lines never say the same thing.

`await busy.end()` takes it down. `run_covered(...)` / `run_ambient(...)` wrap a
`Callable` for sites that want a one-liner; sites whose `await` must stay literally
direct use `cover`/`ambient` + `end`.

Mechanics worth knowing:

- **Minimum visible duration** — `MIN_COVER_VISIBLE_SEC` stops a fast call flashing a
  cover for one frame. Applied to COVERS only (a dim ambient line blinking isn't the
  glitch being fixed, and holding a leaderboard fetch open would just slow the game),
  and never headless.
- **One answer for failure** — `failure_text()` returns the server's own words, or a
  generic message when it gave none, or `""` on success. Hosts with a message row
  render it there; hosts without one call `report_failure()`, which raises a
  dismissible popup. A call that reports nothing is NOT treated as a failure —
  inventing an error the player sees is worse than silence.
- **Headless** — the marker node is created in every environment, so
  `CloudBusy.showing(host)` is provable in tests; only the visuals are skipped. The
  rule throughout this repo: skip the animation, never the decision or the final state.
- **Rebuild survival** — everything joins group `CloudBusy.GROUP`, and hosts that
  rebuild their children wholesale (`account_menu.rebuild`,
  `global_standings._build_ui`) skip that group. Otherwise a `Cloud.state_changed`
  arriving mid-sign-in frees the busy line.

`Cloud.resolve_use_cloud()` is deliberately NOT wrapped: applying an
already-downloaded profile is local (parse, migrate, write) and never touches the
network.

## The sync-conflict prompt: `ConflictPrompt`

`scripts/cloud/conflict_prompt.gd` is the ONE place the "your progress differs"
conflict is put to the player — the copy, the three choices, and the resolution calls.

It exists because `Cloud.conflict_detected` used to have exactly one subscriber:
`account_menu.gd`, a node that only exists while the account page is open. A conflict
raised anywhere else — at sign-in on boot, or on a background sync — emitted into
nothing, and `cloud_sync` then refused every later push with "Resolve the sync conflict
first." Cloud saving silently stopped, with the only thing that could clear it hidden
behind a page the player had no reason to visit.

Three hosts used to raise the same prompt: `account_menu.gd`, `hq.gd` (always in the tree,
so a conflict reached the player wherever they were) and the boot gate. **Only the account
page is left** — the other two were on the deleted hub — so a conflict now reaches the
player only if they happen to open Settings → Account. That is the same gap the boot gate
above describes, from the other end. The account page's private copy of the resolution
handlers was DELETED rather than kept in parallel; keeping it is what let the behaviour
drift in the first place.

`ConflictPrompt.is_blocked()` is the single predicate for "is there an unsettled
conflict". Reaching into `Cloud.sync.blocked_by_conflict` directly is how a second,
drifting copy of that question starts.

Note the three resolutions are NOT symmetric: "keep this device" uploads the whole
profile (a real round-trip, so it gets a cover), "use cloud" is local-only (the
document was already downloaded when the conflict was raised), and "decide later" must
call `Cloud.resolve_later()` — sync stays paused and the account page keeps warning,
deliberately not a silent pick of either side.

## Setup prerequisites (console work)

1. Authentication → enable **Email/Password** and **Google**. (Anonymous is
   deliberately unused — see above.)
2. Enabling Google auto-creates a **Web** OAuth client → `GOOGLE_WEB_CLIENT_ID`.
3. Google Cloud → Credentials → **OAuth client ID → Desktop app** →
   `GOOGLE_DESKTOP_CLIENT_ID`, plus its **client secret** into
   `GOOGLE_DESKTOP_CLIENT_SECRET`. Google requires the secret even with PKCE,
   and the console no longer reveals an existing one — use "+ Add secret".
   Only desktop-type clients may use loopback redirects; the web client may not.
4. On the **Web** client: `https://html.itch.zone` under *Authorised JavaScript
   origins*, and `https://felixxwu.github.io/TAPPA/oauth-callback.html` under
   *Authorised redirect URIs*. Both are exact-match.
4. Firestore → create the database (Native mode). The **rules deploy is
   automated** — see below.
5. Auth → Settings → **Authorised domains** → add the itch.io origin.

Both client-id constants are **empty** until step 2/3 are done;
`FirebaseConfig.google_configured()` is false meanwhile and the UI hides the
Google button rather than offering an option that cannot work.

### Deploying the rules

### The rules file is deployed by CI, and a broken one fails SILENTLY

`firestore.rules` is deployed by the `Deploy Firestore rules` job on every push to `main`.
Nothing in the game reads it, no test used to touch it, and a rejected deploy leaves the
console **still serving the last good rules** — so a malformed file does not break
anything visible. The game keeps working while the deployed policy quietly drifts from the
committed one.

That is not hypothetical. Deleting the multiplayer lobby removed its
`match /lobby_state/{doc} {` header line and left the block's BODY behind — a
`validState()` function and four `allow` lines with no `match` around them, and one extra
`}`. The compiler rejected the file (`Unexpected '}'`) and the deploy job failed on every
push from 2026-09-02 until someone read the log.

`tests/headless/test_firestore_rules.gd` now guards the class of damage a deletion causes:
the braces balance, no `allow`/`function` sits outside a `match` block, the deny-all
catch-all is present, and no deleted collection still has a rule. It is deliberately
STRUCTURAL — GDScript cannot evaluate the rules language, and real semantics need the
Firebase emulator, which is CI's job.

`firestore.rules` is deployed by CI, not by hand, so the committed file is the
single source of truth for who can read a player's save rather than something
that silently drifts from whatever was last pasted into the console.

The `deploy-rules` job in `.github/workflows/deploy.yml` handles it. It runs on
pushes to `main` and on **workflow_dispatch** — the latter is how you do the
*first* deploy, since the workflow may land before the secret exists.

It lives in the Release workflow rather than a workflow of its own purely to
keep the Actions tab to one entry. Two consequences are worth knowing:

- It has **no `needs`**, so it runs alongside the export jobs rather than behind
  the cache gate, and a rules failure cannot stop a game release going out.
- GitHub's `paths:` filter is workflow-level, not job-level, so the "only when
  the rules changed" check is done in the job itself by diffing the push range.
  It deliberately errs towards deploying whenever it can't tell what changed
  (force push, new branch, shallow miss): a redundant deploy costs ~30 seconds,
  a wrongly skipped one leaves the live rules behind `main`, which is the exact
  failure this automation exists to prevent.

**One-time setup**: create a service-account key in the `tapparally` GCP project
with the **Firebase Rules Admin** role (`roles/firebaserules.admin`), and put the
whole JSON in the `FIREBASE_SERVICE_ACCOUNT` repository secret. This is a
different key from `PLAY_SERVICE_ACCOUNT_JSON` — different project, different
permissions — so do not reuse that one. The workflow fails with a clear message
if the secret is missing.

Until the first deploy runs, a new Firestore database denies everything, and
sign-in will succeed while every sync fails with the 403 that `CloudSync`
reports as "Check the Firestore rules".

The **API key is public by design** and safe to commit — it identifies the
project, it does not authorise anything. `firestore.rules` is what protects the
data.

## Tests

- `tests/headless/fake_rest_client.gd` — the stand-in for `RestClient`. A real
  coroutine (it awaits a frame), so code under test takes the same await path it
  takes against a live network.
- `tests/headless/test_cloud_auth.gd` — each sign-in path's endpoint and body,
  local validation short-circuits, mapped **and unmapped** error codes,
  network-vs-auth refresh failure, credential persistence and the three
  "no credential in the profile / no password on disk" guards.
- `tests/headless/test_cloud_sync.gd` — document encoding (incl. the
  integer-as-string trap), every row of the conflict matrix, all three
  resolutions, the `.conflict.bak`, failure classification, backoff growth and
  cap, the update mask, and that the uploaded blob is not marked unsynced.
- `tests/headless/test_text_field.gd` — the nav support (see [menus.md](menus.md)).
- `tests/headless/test_save_manager.gd` — the two new profile fields, their
  backfill onto older profiles, `profile_changed` / `flushed`, `adopt_profile`
  refusing a newer schema, and the conflict backup outliving the rolling `.bak`.
- `tests/headless/test_smoke.gd` — the `Cloud` autoload is registered and inert.

## Manual verification (needs a human)

None of this can be exercised headlessly, so this list is the acceptance check.
Record results here as they land.

- [x] **Google sign-in on macOS (loopback + PKCE)** — passes, 2026-07-31. Getting
      there needed one fix: Google requires the Desktop client's `client_secret`
      in the token exchange (its docs exempt only Android, iOS and Chrome
      clients), so a PKCE-only exchange failed with
      `invalid_request: client_secret is missing`.
- [x] **Google + email sign-in on the itch web build** — both pass, 2026-07-31.
      Took four separate fixes: the itch origin authorised, SharedArrayBuffer
      (COOP) turned off so the popup could talk back, the game's origin carried
      through OAuth `state`, and — the one that broke everything — `accept_gzip`
      disabled on web.
- [x] **Google sign-in on Android (loopback)** — passes, 2026-07-31, with the
      INTERNET permission and the threaded callback listener.
- [ ] Email register → sign out → sign in, on desktop.
- [ ] Email sign-in on Android (retest — the INTERNET permission should have
      fixed it, unverified).
- [ ] Two-device round trip: progress on desktop → sign in on phone → it appears.
- [ ] Genuine divergence: play offline on both, reconnect, confirm the prompt.
- [ ] Airplane mode mid-session: no hang, no data loss, sync resumes.

### Google sign-in on the web build (itch) — known to be fragile

The itch build serves the game from **`https://html.itch.zone`** (measured via
`location.origin` inside the game iframe, 2026-07-31), which must be listed in
the **Web** OAuth client's *Authorised JavaScript origins* — otherwise GIS
answers `GET /gsi/status … 403` and the prompt never renders. Note that origin
is shared by every HTML game on itch, so authorising it is a wider grant than a
domain you own; that is inherent to the shared CDN, not something tightenable.

**A second blocker is not fixable from this repo.** itch embeds the game in an
iframe, and Google's FedCM requires the *embedding* page to grant
`allow="identity-credentials-get"`. It does not, so FedCM fails with
`NotAllowedError: The 'identity-credentials-get' feature is not enabled in this
document`. The legacy non-FedCM path may still work, but Google's own console
warnings say it is being retired — at which point web Google sign-in on itch
stops working regardless of what we do.

If that happens, the options are: hide the Google button on web (email/password
works fine there), build a popup-based OAuth flow (a top-level popup escapes the
iframe policy, but needs an exact registered redirect URI), or host the web
build on a domain we control. Native (desktop/Android) is unaffected — the
loopback flow has no iframe and no FedCM involvement.

Related: the local web round-trip in `todo/web-save-persistence.md` is still
unverified too. Do that one **first** — a broken local IndexedDB flush would make
the two-device check ambiguous.
