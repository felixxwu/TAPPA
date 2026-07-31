# Cloud Save (optional account)

An **optional** account backs the player's career up to Firebase and lets them
continue it on another device. Signing in is never required: a player who
ignores it sees no change at all, and every failure mode here degrades to "you
keep playing locally".

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
| `scripts/account_menu.gd` | `AccountMenu` — the UI, hosted by Settings and by the title screen. |
| `scripts/text_field.gd` | `TextField` — the project's first text input (see [menus.md](menus.md)). |
| `scripts/cloud/firestore_codec.gd` | `FirestoreCodec` — the Firestore REST value encode/decode + `update_mask()` shared by this document AND the leaderboard's, extracted out of this file (see [global-leaderboards.md](global-leaderboards.md)). |
| `firestore.rules` | Security rules, kept in git rather than only in the console. **One collection, `stage_times`, is world-readable — see below and [global-leaderboards.md](global-leaderboards.md).** |
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
[global-leaderboards.md](global-leaderboards.md) for what that collection
holds and why making it public is safe (short version: it never carries
anything from this `users/{uid}` document — no email, no profile blob, just a
chosen name/car/time).

Encoding lives in the pure statics `CloudSync.to_document` / `from_document`,
which build the document SHAPE (which five fields, in what order) and delegate
the actual value tagging/mask-building to `FirestoreCodec` (see
[global-leaderboards.md](global-leaderboards.md) for why that split exists).
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
| `revision > cloud_revision` | unsynced | **Conflict → ask the player** |
| `schema_version > SCHEMA_VERSION` | any | Refuse; do not push either |
| blob unparseable | any | Report; never overwrite the remote copy |

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
emits **`profile_replaced`**, re-emitted by `Cloud`, and `hq.gd` rebuilds on it
(`_on_cloud_profile_replaced`): it clears the car cache, rebuilds the title
lineup or the lift car depending on the current view, and refreshes the map pins
and progress meter.

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
  `show_account`, an entry in `_pages` and in the category grid).
- **Title screen → Account** (`hq_overlays.gd::build_title_overlay` →
  `hq.gd::_open_account_overlay`), directly under Start. A player reinstalling or
  moving to a new device needs it *before* starting a fresh career, so burying it
  in Settings would be the wrong place.

Signed out: Google (hidden when unconfigured) / sign in with email / create an
account. There is deliberately no "continue without an account" button — that is
what closing the page does, and the Back button already says so. Signed in:
identity, sync status, last sync, Sync now, Sign out.

Signing out needs no confirm and **never touches the local profile**: nothing is
destroyed, the career on the device carries on, and the cloud copy is reachable
again by signing back in.

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
