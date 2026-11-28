# Cloud Save (optional account)

An **optional** account backs the player's career up to Firebase and lets them
continue it on another device. Signing in is never required: a player who
ignores it sees no change at all, and every failure mode here degrades to "you
keep playing locally".

**Tests:** `tests/headless/test_cloud_auth.gd`, `tests/headless/test_cloud_sync.gd`, `tests/headless/test_account_menu.gd`, `tests/headless/test_save_manager.gd`, `tests/headless/test_firestore_rules.gd`

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
| `scripts/cloud/firebase_config.gd` | `FirebaseConfig` — project id, API key, endpoint builders. With `FIREBASE_AUTH_EMULATOR_HOST` / `FIRESTORE_EMULATOR_HOST` set (as `firebase emulators:exec` does), every endpoint points at the local emulators instead. |
| `scripts/cloud/rest_client.gd` | `RestClient` — the ONLY `HTTPRequest` in the project. The test seam. |
| `scripts/cloud/auth_service.gd` | `AuthService` — session adoption (`_identity_call`), token refresh, credential storage, error mapping. |
| `scripts/cloud/cloud_sync.gd` | `CloudSync` — Firestore document encoding, the conflict model, debounce/backoff. |
| `scripts/account_menu.gd` | `AccountMenu` — the UI, hosted by the Settings page. |
| `scripts/text_field.gd` | `TextField` — the project's first text input (see [menus.md](menus.md)). |
| `scripts/cloud/firestore_codec.gd` | `FirestoreCodec` — the Firestore REST value encode/decode + `update_mask()`. |
| `firestore.rules` | Security rules, kept in git rather than only in the console, and deployed by CI. Only `users/{uid}` is reachable, owner-only. `stage_times`, `challenge_runs` and the two `lobby_*` collections went with their features; the file grants them nothing now. Structurally guarded by `tests/headless/test_firestore_rules.gd` — see below. |
| `firebase.json` / `.firebaserc` | Point the Firebase CLI at `firestore.rules` and the `tapparally` project, and set the emulator ports (Auth 9099, Firestore 8080). |
| `.github/workflows/deploy.yml` › `deploy-rules` | Deploys the rules on change (and on manual dispatch). |

**Dependency direction: `Cloud` → `Save`, never the reverse.** `Save` emits
`profile_changed` / `flushed` and knows nothing about who is listening, so the
save layer and its tests behave identically whether or not cloud save exists.

## Authentication

**Email-link sign-in is the only method** (steps 0.2–0.3 of
`todo/2026-11-27-rust-native-migration.md`; Google and email + password were removed on
2026-11-28, read the old code from git history). No password, no OAuth client:

1. `AuthService.send_sign_in_link(address)` posts `accounts:sendOobCode`
   (`requestType: EMAIL_SIGNIN`, `canHandleCodeInApp: true`, `continueUrl` from
   `FirebaseConfig.sign_in_continue_url`) and stores the address as `pending_email` in
   `auth.json`, so the code can be finished after a restart.
2. Firebase emails a link to the continue URL with `?oobCode=` appended.
   - **Web:** the link opens the game itself (`FirebaseConfig.WEB_GAME_URL`,
     `https://tappa.felixwu.me/`).
     `Cloud._take_code_from_page_url` reads `oobCode` at startup through JavaScriptBridge
     and strips it with `history.replaceState`, so a reload doesn't retry a spent code.
   - **Native:** the link opens `docs/sign-in.html`, which Cloudflare Pages serves at
     `https://tappa.felixwu.me/sign-in` (`FirebaseConfig.SIGN_IN_LANDING_URL`),
     which shows the code with a copy button; the player pastes it on the Account page.
     `AuthService.code_from` also accepts a whole pasted link.
3. `AuthService.sign_in_with_link(code, address)` posts `accounts:signInWithEmailLink`
   and adopts the session through `_identity_call`. The address falls back to
   `pending_email`; if that's missing (link opened on another device or browser) the page
   asks for it again — on web the code waits in `Cloud.link_code` meanwhile.

Both continue URLs are **constants in `firebase_config.gd` and nowhere else**. They point
at the Cloudflare Pages site (see [release-pipeline.md](release-pipeline.md)); if
`tappa.felixwu.me` is missing from Firebase Auth's authorised domains, `sendOobCode` fails
with `UNAUTHORIZED_DOMAIN`, which the page reports plainly.

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

### Credential storage — the trap

Tokens live in **`user://auth.json`**, never in the profile.

`profile["settings"]` is *inside the blob uploaded to Firestore*. A refresh token
parked there would publish a long-lived credential into the database and
replicate it to every other device on the account. `auth.json` holds the refresh
token, uid, email and the pending sign-in address; the short-lived `id_token` is kept in memory
only and never written. `test_cloud_auth.gd` asserts both.

## Deleting the account

Settings → Account → **Delete account** (a confirm popup first), in this order
(`Cloud.start_account_deletion` / `confirm_account_deletion` / `_finish_account_deletion`):

1. **Stop sync** — `CloudSync.stop()` sets `enabled = false` (`_can_sync` then refuses
   every push and pull, and a pull already in flight re-checks it and abandons its upload)
   and waits out any `_busy` / `_pulling` call, so nothing can recreate the document later.
2. **Re-authenticate if needed.** `accounts:delete` refuses a sign-in older than about five
   minutes (`CREDENTIAL_TOO_OLD_LOGIN_AGAIN`). The game tracks `AuthService.signed_in_at`
   (in memory, never restored) and, when it's older than `RECENT_SIGN_IN_SEC`, emails a
   fresh link to the account's address and shows a code field
   (`Cloud.deletion_needs_link`). The link always goes to the landing page, even on web, so
   the code comes back to this tab. That sign-in does **not** pull or push. A code for a
   different account aborts without deleting anything.
3. **Delete the Firestore document** (`CloudSync.delete_document`; a 404 counts as done).
4. **`accounts:delete`** (`AuthService.delete_account`).
5. **Clear `auth.json`** (`auth.sign_out()`), which turns sync back on for whoever signs in next.

A failure before step 3 cancels the deletion and turns sync back on. A failure at step 4
leaves sync off (pushing would bring the document back) — but only until the game restarts;
the player retries from the same page. Back or Cancel on the code form cancels.
The local profile is never touched.

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
this document but its own owner. No other collection is reachable.

Encoding lives in the pure statics `CloudSync.to_document` / `from_document`,
which build the document SHAPE (which five fields, in what order) and delegate
the actual value tagging/mask-building to `FirestoreCodec`.
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
immediately. `Save.save(false)` writes to disk WITHOUT setting `unsynced` or emitting `profile_changed`,
for state that is not progress, so it rides up with the next real change instead of costing an
upload. Nothing calls it since free roam's periodic world save was deleted.

| Cloud | Local | Action |
|---|---|---|
| No document (404) | any | Push local |
| `revision <= cloud_revision` | clean | Nothing |
| `revision <= cloud_revision` | unsynced | Push |
| `revision > cloud_revision` | clean | Download and apply |
| `revision > cloud_revision` | unsynced, **world never driven** | **Auto-restore the cloud** (see below) |
| `revision > cloud_revision` | unsynced | **Conflict → ask the player** |
| `schema_version > SCHEMA_VERSION` | any | Refuse; do not push either (`_remote_refused` holds off later background pushes until a pull reads a doc this build can replace) |
| `schema_version < SCHEMA_VERSION` | any | **Overwrite with local** at `revision + 1` (state `obsolete`): an old profile resets whatever its version (decision 34), so it is no side of a conflict |
| blob unparseable | any | Report; never overwrite the remote copy (same `_remote_refused` hold) |

### The one case that is resolved automatically: a wiped local save

If both sides moved on but **this device's world has never been driven**, there is no
dilemma to put to the player — the local "progress" is a blank save (a reset, a clear, a
reinstall), and taking the cloud costs them nothing.
Asking there is actively harmful: it presents a fresh blank profile as an equal
alternative to a real career, and one mis-tap on "keep this device" uploads the
blank straight over it. So `CloudSync.pull` takes the cloud copy itself
(`_local_is_wiped() and _remote_has_progress(remote)` → `apply_remote(remote, true)`),
still writing the `profile.json.conflict.bak` backup.

**Keyed on more than 2 lit stops or more than 1 car (`CloudSync.has_progress`), not ground driven
or `drive_time`.** A new player's first drive covers hundreds of metres in one car and lights
spawn's stop and one cabin, so it must not count: a returning player signing in on a new device
would otherwise be offered their intro save over their career. The prompt's cursor starts on
"Decide later", and "Keep this device" writes the overwritten cloud copy to the same
`.conflict.bak` first.

Both guards matter. A wiped local against a wiped **cloud** is a genuine
nothing-to-choose-between and still prompts, and if `apply_remote` fails the code
falls through to the normal prompt rather than leaving sync silently blocked.

### The progress wipe must clear the cloud too

`push_wipe` first waits out any upload in flight, since that upload still carries the wiped career.

A pull that would upload a blank local world over a cloud copy with progress asks instead (`_pull_inner`), even when the local profile claims to be level with or ahead of the cloud: a wipe or New World made while signed out keeps the old `cloud_revision`, so it would otherwise read as a continuation of the cloud career.

`Settings -> Reset progress -> Wipe all progress` calls `Save.reset_new_game()`, which only
clears THIS device (keeping `cloud_revision` / `cloud_uid`, so the wipe's push lands at the next
revision above the old cloud copy rather than at revision 1 under it). On its own that wipe silently undoes itself: the next pull sees
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
`CloudSync.describe_profile` ("2 cars, 5 checkpoints, 40 min driven") rather than raw
revision numbers:

- **Keep this device** — push at `remote.revision + 1`, so the other device sees
  a clean "cloud is ahead" next time. It also seats `cloud_uid`: on a first sign-in or an
  account switch the revision would otherwise count from 0.
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
`Save.flush_and_sync()`. Both debounces are max-waits: a stream of saves while
driving doesn't restart the timer, and `CloudSync` runs with
`PROCESS_MODE_ALWAYS` so its timers keep going under the pause menu, rest stops
and the title. A change made while an upload is in flight (`_changes` moved on
since the copy was taken) keeps `pending` and re-arms the debounce rather than
being marked synced. Debounced, retried and flushed uploads go through `pull()`
(`CloudSync._upload_pending`), so a newer cloud save raises the conflict prompt instead of being
overwritten; only the small gap between that read and the upload is unguarded. Signing out clears
any conflict and refusal (`reset_for_account`), so they can't reach the next account. A token refresh that gets a 429 or 5xx keeps the session,
like a transport failure; only a 4xx rejection signs out. The web
`visibilitychange`/`pagehide` listeners and the native close/pause notifications
all funnel through `Save.flush_and_sync()`, so the cloud path inherits tab-close and app-pause
handling on every platform.

Pull happens at sign-in and on `NOTIFICATION_APPLICATION_RESUMED`. A pull first waits out any
upload still in flight (`_busy`), so it never compares against this device's own half-landed
PATCH and calls the difference a conflict.

**Nothing syncs during a benchmark.** `CloudSync._can_sync()` is false while `Benchmark.active`
(its throwaway world sits in `Save.profile`), which covers every path at once — a debounced push,
a retry, a resume pull, the exit flush — and `_push_inner` re-checks it after its token await,
since it copies the profile only then.

Failures back off exponentially (2 s → 60 s, jittered from `RngStreams.make("cloud_sync")`). The retry queue is a
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
the web build and surfaced to the player as
"No connection", which sent the investigation towards CORS for some time. If web
requests ever start failing on a 200 again, check this first.

Native keeps gzip enabled: there the engine owns the transfer and handles it
correctly.

### Refreshing live UI after a download

A pull that REPLACES the local profile (first sign-in on a new device, or "Use cloud" on a
conflict) changes the save out from under the running game. `CloudSync` emits
**`profile_replaced`**, re-emitted by `Cloud`. `LevelView._on_profile_replaced` reloads the level on
it, first clearing `_driving` so leaving doesn't save this device's spot over the downloaded one.
`Save.adopt_profile` emits `Save.replaced`, which moves `WorldSession.generation` on
([world-session.md](world-session.md)).

## Error handling

| Failure | Behaviour |
|---|---|
| Offline / timeout / 429 / 5xx | Queue, back off, "not synced". No popups mid-race. |
| Refresh rejected (auth) | Sign out locally, one notice, local play untouched |
| Refresh failed (network) | Retry; **do not** sign out |
| 401 / 403 | Named plainly with the code — a rules misconfiguration, not a player error |
| Cloud schema newer | Refuse to apply *or* overwrite; "update the game" |
| Cloud schema older | Overwrite it with this device's profile |
| Cloud blob unparseable | Report; leave the remote copy alone |
| `Save.save_disabled` | Cloud sync still runs — blocked local storage is when it matters most |

## UI

- **Settings → Account** (`settings_menu.gd`: `_build_account_page`, an entry in
  `_pages`, and the "Account" entry in `_build_list_page`'s category grid).
It is the only host: two routes into one optional form is one more than the game needs.

Signed out: a line explaining the account, an email field and "Email me a sign-in link",
then (native, or web holding a code from the page URL) a code field and "Sign in". There
is deliberately no "continue without an account" button — that is what closing the page
does. Signed in: identity, sync status, Sync now, Sign out, Delete account. While a
deletion waits for its link: a code field, Delete account, Cancel. The fields and buttons
are one `TextField.wire_column`; typed text survives the page's wholesale rebuilds
(`_typed_email` / `_typed_code`). `AccountMenu.go_back` holds Back while a cloud call is in
flight, and cancels a deletion that is waiting for its link.

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

`tests/headless/test_account_menu.gd` asserts the signed-in view stays under a
row-count bound for exactly this reason.

Signing out needs no confirm and **never touches the local profile**: nothing is
destroyed, the career on the device carries on, and the cloud copy is reachable
again by signing back in.

## Boot-time pull

`Cloud._ready` calls `auth.restore()` then defers `_kick_off_initial_pull` (one `sync.pull()`).
Nothing waits for it: the level starts immediately. The old "await the boot pull" gate
(`await_initial_sync` and friends) was deleted as it had no consumer, and
`CloudSync.has_progress` covers the race it existed for (a fresh local profile never counts as
progress, so it cannot raise a false conflict against a real cloud career).

## Waiting on the network: `CloudBusy`

Every `await Cloud.*` call site is bracketed by a shared busy state
(`scripts/cloud/cloud_busy.gd`, `class_name CloudBusy`, static — no autoload). Before
it existed each screen invented its own waiting UI or none: a player resolving a sync
conflict tapped a button and got silence for the length of a full profile upload, and
nothing at all showed while a call was in flight.

Two shapes, chosen by what the call does:

- **`CloudBusy.cover(host, title, step)`** — a blocking full-screen `LoadingScreen`,
  for calls that rewrite the profile or gate progression: conflict resolution and sign-in.
- **`CloudBusy.ambient(host, text, container)`** — non-blocking, for reads
  behind already-rendered UI (the account page's message row).

`await busy.end()` takes it down. `run_covered(...)` wraps a
`Callable` for sites that want a one-liner; sites whose `await` must stay literally
direct use `cover`/`ambient` + `end`.

Mechanics worth knowing:

- **Minimum visible duration** — `MIN_COVER_VISIBLE_SEC` stops a fast call flashing a
  cover for one frame. Applied to COVERS only (a dim ambient line blinking isn't the
  glitch being fixed),
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
  rebuild their children wholesale (`account_menu.rebuild`) skip that group. Otherwise a `Cloud.state_changed`
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

**Two hosts raise it:** the account page, while it is open, and the level (`LevelView`) for a
conflict found in the background — at boot or on coming back to the app. The level latches
`Cloud.conflict_detected` (`_conflict_due`) and `_offer_conflict` opens the prompt on its pause
menu as soon as the player is driving with nothing else on screen (no page, pause menu or other
modal), pausing the game and disarming the pause menu until the chosen action has finished,
upload included. "Decide later" clears the latch, so it is not asked again until the next
conflict or the next level load, which re-latches from `ConflictPrompt.is_blocked()` so a conflict
raised during a scene change is never lost. The prompt is a `ConfirmPopup`, so it is
`MenuNav`-navigable (keyboard + gamepad) like every modal. The account page's private copy of the resolution
handlers was DELETED rather than kept in parallel; keeping it is what let the behaviour
drift in the first place.

`ConflictPrompt.is_blocked()` is the single predicate for "is there an unsettled
conflict". Reaching into `Cloud.sync.blocked_by_conflict` directly is how a second,
drifting copy of that question starts.

Note the three resolutions are NOT symmetric: "keep this device" first re-reads the cloud
copy (a conflict left on "decide later" can be hours old; if it moved, the player is asked
again; if it's unreadable or from a newer schema, nothing is uploaded, like a pull) and then uploads the whole profile (a real round-trip, so it gets a cover, and the
game stays paused until it and any failure notice are done), "use cloud" is local-only (the
document was already downloaded when the conflict was raised), and "decide later" must
call `Cloud.resolve_later()` — sync stays paused and the account page keeps warning,
deliberately not a silent pick of either side.

## Setup prerequisites (console work)

1. Authentication → Sign-in method → enable **Email/Password** AND tick
   **Email link (passwordless sign-in)**.
   (Anonymous is deliberately unused — see above.) The Google provider and its
   OAuth clients are no longer used by the game and can be switched off.
2. Firestore → create the database (Native mode). The **rules deploy is
   automated** — see below.
3. Auth → Settings → **Authorised domains** → add `tappa.felixwu.me`, the web build's
   origin. Every continue URL must be on an authorised domain.
4. `tools/deploy_pages.sh` copies `docs/sign-in.html` into every web deploy, so it is
   served at `FirebaseConfig.SIGN_IN_LANDING_URL` (`/sign-in`; Pages redirects
   `/sign-in.html` there and keeps the query string).
5. Optionally edit the sign-in email template (Auth → Templates → Email address sign-in).

Android needs `permissions/internet=true` on BOTH presets in `export_presets.cfg`,
or every `HTTPRequest` fails as "no connection".

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
STRUCTURAL — GDScript cannot evaluate the rules language. The real semantics are checked
against the Firestore emulator by `tests/emulator/` (see Tests below).

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
- `tests/headless/test_cloud_auth.gd` — session adoption through
  `_identity_call`, mapped **and unmapped** error codes, network-vs-auth refresh
  failure, credential persistence and the "no credential in the profile" guard, the
  sendOobCode / signInWithEmailLink requests and the stored address, `code_from`,
  `signed_in_recently` and the `accounts:delete` request.
- `tests/headless/test_account_deletion.gd` — the deletion order through a private `Cloud`
  instance, re-auth by fresh link without a pull, sync unable to recreate the document
  mid-delete, failure handling and a code for the wrong account.
- `tests/headless/test_cloud_sync.gd` — document encoding (incl. the
  integer-as-string trap), every row of the conflict matrix, all three
  resolutions, the `.conflict.bak`, failure classification, backoff growth and
  cap, the update mask, that the uploaded blob is not marked unsynced, an older-schema cloud copy
  being overwritten, a pull waiting out an upload in flight, nothing syncing during a benchmark,
  and `stop()` / `delete_document()`.
- `tests/headless/test_account_menu.gd` — the sign-in form, the deletion code form, Back
  cancelling a deletion; `test_settings_menu.gd` — the Account entry's keyboard/gamepad nav.
- `tests/headless/test_text_field.gd` — the nav support (see [menus.md](menus.md)).
- `tests/headless/test_save_manager.gd` — the two new profile fields, their
  backfill onto older profiles, `profile_changed` / `flushed`, `adopt_profile`
  refusing a newer schema, and the conflict backup outliving the rolling `.bak`.
- `tests/headless/test_smoke.gd` — the `Cloud` autoload is registered and inert.

### Against the Firebase emulators — `tests/emulator/`

`tests/emulator/test_cloud_emulator.gd` runs the same flows through a private `Cloud` instance
and the real `RestClient`, against the Auth and Firestore emulators loaded with the committed
`firestore.rules`: email-link sign-in (the code comes from the Auth emulator's
`/emulator/v1/projects/tapparally/oobCodes` list, since it sends no mail), a spent code refused,
the first pull uploading, a push of local changes after a real token refresh, a newer cloud save
applied, the rules refusing one player's token on another player's document (read, write,
delete, and signed out), and both deletion paths (recent sign-in, and old sign-in confirmed by a
fresh code) leaving no document and no account. Each test starts from emptied emulators; the
Firestore emulator's `Bearer owner` token reads documents past the rules.

It is not part of `./run_tests.sh`; it skips itself when the emulator variables are unset. Run it
with `firebase emulators:exec --only auth,firestore "./run_tests.sh --emulator"` (needs
firebase-tools and Java 21). CI runs it in the `emulator` job of `.github/workflows/test.yml`.

## Manual verification (needs a human)

None of this can be exercised headlessly, so this list is the acceptance check.
Record results here as they land.

- [ ] Two-device round trip: progress on desktop → sign in on phone → it appears.
- [ ] Genuine divergence: play offline on both, reconnect, confirm the prompt.
- [ ] Airplane mode mid-session: no hang, no data loss, sync resumes.
- [ ] Email link sign-in on web (link opens the game) and native (paste the code).
- [ ] Delete account, both fresh and after five minutes (re-auth link); the document and
  the Auth user are gone in the console.

### Web persistence

The local web round-trip in `todo/web-save-persistence.md` is still
unverified. Do that one **first** — a broken local IndexedDB flush would make
the two-device check ambiguous.
