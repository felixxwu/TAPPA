# Release pipeline

Everything that happens between a push to `main` and the build being playable.
One workflow — `.github/workflows/deploy.yml`, named **Release** — runs on every
push to `main` (plus `workflow_dispatch`), and it is the only thing that ships:
there is no manual upload step in the normal loop.

**Tests:** `tests/headless/test_update_check.gd`

## Jobs

| Job | Name in the Actions tab | Ships to |
|-----|-------------------------|----------|
| `compile-check` | Every script and scene compiles | nothing — it's the gate |
| `export-web` | Export & deploy web build | Cloudflare Pages, https://tappa.felixwu.me (big files in R2) |
| `export-android` | Export & deploy Android APK | itch.io channel `android` (sideload) |
| `export-windows` | Export & deploy Windows .exe | itch.io channel `windows` |
| `publish-play` | Build AAB & upload to Play | Google Play, track from `env.TRACK` |
| `deploy-pages` | Deploy /docs to GitHub Pages | GitHub Pages (a redirect to the game + `version.json`, *not* the game) |
| `deploy-rules` | Deploy Firestore rules | Firebase, only when the rules changed |

`compile-check` gates the four export/publish jobs via `needs`; those four then
run in parallel. `deploy-pages` waits on the three export jobs — not because it
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

The gate loads every script and scene with the autoloads present (`tools/compile_check.tscn`), so a parse error fails the release before anything is exported.

Each export job builds through the same `build_*.sh` script you'd run locally
(`build_web.sh`, `build_android.sh`, `build_windows.sh`, `build_android_play.sh`),
so CI and a local build can't diverge. All of them check out with
`fetch-depth: 0`, because the version string (and the Android `versionCode`) is
derived from the commit count — a shallow clone would report every release as
`0.1`.

Godot is pinned to `env.GODOT_VERSION` (4.6.3) to match the local editor and to
keep the Android build template on target API 36.

## The web build on Cloudflare Pages

`export-web` runs `./build_web.sh`, then `tools/deploy_pages.sh`, which stages
`build/pages` and deploys it to the Pages project `tappa`, served at
**https://tappa.felixwu.me**. The site's own files live in `cloudflare/`:
`_headers`, `wrangler.toml` (project name and the R2 binding) and
`functions/b/[[path]].js`.

- **Cross-origin isolation.** The threaded web build needs `SharedArrayBuffer`, so
  `cloudflare/_headers` sends `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp` on every path. Pages doesn't apply
  `_headers` to Function responses, so the Function sets them itself.
- **Files over 25 MiB go to R2.** Pages rejects bigger files, and `index.wasm` and
  `index.pck` (which holds the level bake) are bigger. `deploy_pages.sh` uploads
  every engine file over 25 MiB to the R2 bucket `tappa-builds` with
  `wrangler r2 object put`, and the Function on `/b/*` streams them from the
  `BUILDS` binding on the same origin, so COOP/COEP need no CORS or CORP. Anything
  under `/b/` not in R2 falls through to Pages' static files.
- **The R2 files are stored gzipped** (`--content-encoding gzip`; the wasm 37 MB →
  9 MB). Cloudflare doesn't compress a Function's streamed R2 body or
  `application/octet-stream`, so the Function sends the stored bytes as they are
  (`encodeBody: "manual"`) and the browser unzips them. Godot's progress bar uses the
  uncompressed sizes in `GODOT_CONFIG.fileSizes`, which still match.
- **No stale builds.** Every engine file (`index.js`, the audio worklets, the wasm,
  the pck) sits under `/b/<build-id>/` (a UTC timestamp plus the short SHA, new on
  every run) with `Cache-Control: public, max-age=31536000, immutable`.
  `deploy_pages.sh` rewrites `index.html` to load from there (`executable` and
  `fileSizes` in `GODOT_CONFIG`, and the `index.js` script tag) and fails loudly if
  Godot's shell no longer matches. `index.html` and the sign-in page are
  `Cache-Control: no-cache`. R2 uploads go first, so a live `index.html` never
  names a missing file. A `404.html` is staged so Pages doesn't answer unknown
  paths with `index.html` (which would then be cached forever under `/b/`).
- **Other pages.** `docs/sign-in.html` (the email-link landing page, served at
  `/sign-in`; see [cloud-save.md](cloud-save.md)) and `docs/privacy-policy.html`
  are copied in. Pages serves `/x.html` as a redirect to `/x`, query kept.
  GitHub Pages still publishes both from `docs/` too, so their old URLs keep working.
- **Try it locally.** `tools/deploy_pages.sh --dry-run` stages `build/pages` and
  prints the upload and deploy commands instead of running them. To serve it, from
  `cloudflare/`: `npx wrangler@4 r2 object put tappa-builds/b/<id>/index.wasm --file
  ../build/pages-r2/index.wasm --content-encoding gzip --local` (and the pck), then
  `npx wrangler@4 pages dev`.

### One-off Cloudflare setup (by hand, once)

Run with a logged-in wrangler (`npx wrangler@4 login`) or the same token CI uses:

```sh
npx wrangler@4 r2 bucket create tappa-builds
# Old builds are only needed by tabs left open; drop them after 30 days (R2's free tier is 10 GB).
npx wrangler@4 r2 bucket lifecycle add tappa-builds expire-old-builds b/ --expire-days 30
npx wrangler@4 pages project create tappa --production-branch main
```

Then in the dashboard: Workers & Pages → `tappa` → Custom domains → add
`tappa.felixwu.me` (Cloudflare creates the CNAME if `felixwu.me` is on the same
account; otherwise add `tappa CNAME tappa.pages.dev` at the DNS host). Create an
API token with **Cloudflare Pages: Edit** and **Workers R2 Storage: Edit** and add
it and the account ID as the `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`
repository secrets. Finally add `tappa.felixwu.me` to Firebase Auth's authorised
domains ([cloud-save.md](cloud-save.md) → setup).

## `install-butler` — why it's a composite action

Two jobs push to itch, and both need `butler`. That install lives in
`.github/actions/install-butler/action.yml` rather than being copy-pasted per
job, so there's one place to fix when itch's CDN misbehaves — which it does.

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
   restored copy isn't pointlessly re-saved. A key collision when both jobs
   download at once is a warning, not a failure.

It only fails hard when broth is unreachable *and* nothing was ever cached.

There is deliberately **no third mirror**: broth is the only source itch
publishes, so any other URL would put an unverified third party in the release
path.

butler ends up on `PATH` (via `$GITHUB_PATH`), so the push steps can call
`butler` by name.

## `butler_push.sh` — retry while itch is still processing

The itch push steps go through `.github/scripts/butler_push.sh` rather than
calling `butler push` directly. itch keeps processing a channel's build for a
while after butler returns, so when pushes to `main` land a few minutes apart
the next run can reach the same channel first and get a 400 "channel X's latest
build is still processing, try again later" (runs #743, #744, #747 and #749 on
2026-10-23, all on the Windows `.exe`). The script retries on that error only,
up to 10 times 30 s apart; any other butler failure still fails the job at once.

## Secrets

All under Settings → Secrets and variables → Actions; the workflow header lists
them too.

| Secret | Used by |
|--------|---------|
| `BUTLER_API_KEY` | the two itch push steps |
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` | `export-web` (Pages deploy and R2 uploads) |
| `ANDROID_KEYSTORE_B64` / `ANDROID_KEYSTORE_PASSWORD` | `export-android`, `publish-play` |
| `PLAY_SERVICE_ACCOUNT_JSON` | `publish-play` |
| `FIREBASE_SERVICE_ACCOUNT` | `deploy-rules` (a *different* project + far narrower role) |

`export-android` falls back to an ephemeral keystore when the secret is absent
(with a warning — the APK signature then changes every build, forcing an
uninstall before update). `publish-play` refuses to, because Play App Signing
verifies every upload against the same upload key.

## `publish-play`'s upload step — fastlane `supply`, not `r0adkll/upload-google-play`

`publish-play`'s final step uploads `rally.aab` to Play via `fastlane supply`
(`gem install fastlane -NV` then `fastlane supply --package_name ... --aab ...
--track ... --release_status completed`, with the metadata/image/screenshot
uploads skipped since this project doesn't maintain Play store listing assets
through the API), reading `PLAY_SERVICE_ACCOUNT_JSON` via the `SUPPLY_JSON_KEY_DATA`
env var fastlane's `supply` expects.

Previously used `r0adkll/upload-google-play@v1`, replaced 2026-09-11 after it
failed twice in a row (runs #648, #651) with `This edit has expired, please
create a new Edit.` ~39s into the `.aab` upload, in both cases *after* the
build itself had already succeeded — i.e. the build/signing pipeline was never
the problem. That action opens a Play "Edit" session and performs the upload
as a separate call against the googleapis JS client; the Edit has a short
server-side TTL, and a sluggish upload can lapse it mid-transfer with no retry
built into the action. `fastlane supply` is the actively-maintained tool most
teams migrate to for this exact failure mode. There is no drop-in official
Google Actions replacement — `google-github-actions/upload-google-play` does
not exist, despite sounding like it should.

## Gotchas

- **The first Play upload must be done by hand.** The Play Developer API rejects
  the very first upload for a brand-new app; `publish-play` uploads the `.aab` as
  a workflow artifact *before* the Play step precisely so you can grab it when
  that step fails.
- **`deploy-pages` does not publish the game.** `docs/index.html` is a redirect to
  https://tappa.felixwu.me/; the playable web build is what `export-web` deploys to
  Cloudflare Pages. It *does* publish one thing the game reads:
  `docs/version.json`, generated in the job (not committed — its build number is
  the commit count of the commit being released), which is why that checkout uses
  `fetch-depth: 0` like the export jobs. See [update-check.md](update-check.md).
- **Pages needs its source set to "GitHub Actions"** (Settings → Pages), not the
  legacy `/docs` branch build.
- **CI imports one file at a time.** Every "Import project" step appends
  `editor/import/use_multiple_threads=false` to the runner's `project.godot` (never
  committed): on the GitHub runners, compressing a VRAM texture (`grass.jpg`,
  `gravel.jpg`, `sky_field.png`) on an import worker thread sometimes never returns,
  and the import hung for hours. It has to go in `project.godot` because the editor
  (`--import`) ignores `override.cfg`. `timeout 600` stays as a backstop.
