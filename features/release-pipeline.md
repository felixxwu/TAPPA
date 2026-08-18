# Release pipeline

Everything that happens between a push to `main` and the build being playable.
One workflow — `.github/workflows/deploy.yml`, named **Release** — runs on every
push to `main` (plus `workflow_dispatch`), and it is the only thing that ships:
there is no manual upload step in the normal loop.

**Tests:** `tests/headless/test_track_cache.gd`, `tests/headless/test_update_check.gd`, `tests/headless/test_overworld_cache.gd`, `tests/headless/test_lineup_cache.gd`

## Jobs

| Job | Name in the Actions tab | Ships to |
|-----|-------------------------|----------|
| `verify-caches` | Verify track + opponent lockfiles are fresh | nothing — it's the gate |
| `export-web` | Export & deploy web build | itch.io channel `html5` |
| `export-android` | Export & deploy Android APK | itch.io channel `android` (sideload) |
| `export-windows` | Export & deploy Windows .exe | itch.io channel `windows` |
| `publish-play` | Build AAB & upload to Play | Google Play, track from `env.TRACK` |
| `deploy-pages` | Deploy /docs to GitHub Pages | GitHub Pages (a redirect page + `version.json`, *not* the game) |
| `deploy-rules` | Deploy Firestore rules | Firebase, only when the rules changed |

`verify-caches` gates the four export/publish jobs via `needs`; those four then
run in parallel. `deploy-pages` waits on the three **itch** jobs — not because it
ships anything, but because it publishes `docs/version.json`, the document the
native builds' update check reads, and announcing a build whose itch upload failed
would point players at a page still serving the old download (see
[update-check.md](update-check.md); `publish-play` is deliberately excluded — Play
players are prompted too, but that job's slow/manual failure modes must not mute
the notification for itch players). It
stays `continue-on-error`, so a Pages outage still can't turn a good release red,
and it was never in the path that ships the game. `deploy-rules` has no `needs` at
all, so a rules failure can't hold up a game release — see
[cloud-save.md](cloud-save.md) → *Deploying the rules* for why `deploy-rules`
lives here and how its change-detection works.

The gate re-checks the committed track lockfile (`data/track_cache.json`) by
**hash only** — it never regenerates it, so a stale lockfile fails the release rather
than being silently papered over. (The opponent lockfile and its verifier job are gone:
the rival field is drawn against the player's car rating, so it is generated live.) See
[track.md](track.md) → *Turn cache*.

Each export job builds through the same `build_*.sh` script you'd run locally
(`build_web.sh`, `build_android.sh`, `build_windows.sh`, `build_android_play.sh`),
so CI and a local build can't diverge. All of them check out with
`fetch-depth: 0`, because the version string (and the Android `versionCode`) is
derived from the commit count — a shallow clone would report every release as
`0.1`.

Godot is pinned to `env.GODOT_VERSION` (4.6.3) to match the local editor and to
keep the Android build template on target API 36.

## `install-butler` — why it's a composite action

Three jobs push to itch, and all three need `butler`. That install lives in
`.github/actions/install-butler/action.yml` rather than being copy-pasted three
times, so there's one place to fix when itch's CDN misbehaves — which it does.

itch publishes butler **only** through "broth", over two hostnames
(`broth.itch.ovh`, `broth.itch.zone`) that share a backend and therefore fail
together. Both of these were real, and both threw away fully-built signed
releases over a ~6 MB download:

- run **#438** — all three butler jobs died: `.ovh` failed DNS resolution,
  `.zone` answered `500` to every retry.
- run **#444** — `export-windows` died the same way, `.zone` answering `502`.

The action is built around that failure mode:

1. **Cache first.** `actions/cache/restore` is tried before any network call, so
   the normal path doesn't touch broth at all. butler is a stable upload client,
   so last week's copy pushes today's build fine.
2. **Weekly refresh with a fallback.** The key is `butler-linux-amd64-<ISO year>-<ISO week>`
   with `restore-keys: butler-linux-amd64-`. A new week misses the exact key and
   re-downloads; if that download fails, the newest older entry is already
   restored and gets used with a `::warning::` instead of failing the release.
3. **Alternate hosts across attempts.** Six attempts with backoff
   (`0 5 10 20 40 60` seconds), switching host each time, so each host gets
   three tries spread over ~135s. The old inline step burned six near-instant
   retries on `.ovh`'s DNS failures and then six retries 3s apart on `.zone` —
   roughly 15 seconds of real coverage.
4. **Stage before swapping.** The archive is unpacked into a scratch dir and only
   moved into place once `butler` is confirmed present, so a truncated or
   HTML-error-page "zip" can't clobber a good cached copy. A bad archive counts
   as a failed attempt and moves to the other host.
5. **Only cache what works.** `actions/cache/save` runs after `butler -V` has
   passed and only for a fresh download, so a broken binary is never cached and a
   restored copy isn't pointlessly re-saved. A key collision when all three jobs
   download at once is a warning, not a failure.

It only fails hard when broth is unreachable *and* nothing was ever cached.

There is deliberately **no third mirror**: broth is the only source itch
publishes, so any other URL would put an unverified third party in the release
path.

butler ends up on `PATH` (via `$GITHUB_PATH`), so the push steps call
`butler push`, not `./butler`.

## Secrets

All under Settings → Secrets and variables → Actions; the workflow header lists
them too.

| Secret | Used by |
|--------|---------|
| `BUTLER_API_KEY` | the three itch push steps |
| `ANDROID_KEYSTORE_B64` / `ANDROID_KEYSTORE_PASSWORD` | `export-android`, `publish-play` |
| `PLAY_SERVICE_ACCOUNT_JSON` | `publish-play` |
| `FIREBASE_SERVICE_ACCOUNT` | `deploy-rules` (a *different* project + far narrower role) |

`export-android` falls back to an ephemeral keystore when the secret is absent
(with a warning — the APK signature then changes every build, forcing an
uninstall before update). `publish-play` refuses to, because Play App Signing
verifies every upload against the same upload key.

## Gotchas

- **The first Play upload must be done by hand.** The Play Developer API rejects
  the very first upload for a brand-new app; `publish-play` uploads the `.aab` as
  a workflow artifact *before* the Play step precisely so you can grab it when
  that step fails.
- **`deploy-pages` does not publish the game.** `docs/index.html` is a redirect to
  the itch page; the playable web build is what `export-web` pushes. Pages
  headers are therefore irrelevant to load time — itch's are what matter. See the
  header comment in `build_web.sh`. It *does* publish one thing the game reads:
  `docs/version.json`, generated in the job (not committed — its build number is
  the commit count of the commit being released), which is why that checkout uses
  `fetch-depth: 0` like the export jobs. See [update-check.md](update-check.md).
- **Pages needs its source set to "GitHub Actions"** (Settings → Pages), not the
  legacy `/docs` branch build.
