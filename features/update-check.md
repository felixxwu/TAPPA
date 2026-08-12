# Update check (native builds)

On launch, the **native** builds ask whether a newer build has shipped and — if
one has — raise a single dismissible prompt over the title shot with a link to the
download page. Nothing else about the game changes: it is one GET, off the boot
critical path, and every failure mode is a silent no-op.

| Piece | Where |
|---|---|
| The policy (parsing, the decision, the fetch) | `scripts/update_check.gd` (`UpdateCheck`) |
| Placement + the modal | `scripts/hq.gd` → `_check_for_update` |
| The published document | `.github/workflows/deploy.yml` → `deploy-pages` → *Generate docs/version.json* |
| The "this is a Play build" marker | `export_presets.cfg` → `preset.2` (`custom_features="play"`) |
| Tests | `tests/headless/test_update_check.gd` |

## Which builds check, and why the others don't

| Build | Checks? | Why |
|---|---|---|
| itch Windows `.exe` | **yes** | nothing updates a downloaded exe for the player |
| itch Android `.apk` (sideload) | **yes** | same — a sideloaded APK has no updater |
| Web | no | `build_web.sh` uploads to a build-unique itch path, so a browser player is by construction on the newest build |
| Google Play `.aab` | no | Play ships its own updates, and pointing a Play install at an off-store download is against Play policy |
| Editor / test runner | no | the version is the unstamped `0.0-dev`, which has no build number |

`UpdateCheck.applicable()` is the single gate for all of the above (`Platform.is_headless()`,
`Platform.is_web()`, `OS.has_feature("play")`, and a parseable local build number).
When it returns false **no request is made at all**.

Desktop players who installed through the **itch app** already get automatic
updates. They can't be told apart from a direct download, so they may see the
prompt for a build the app is about to fetch anyway — harmless, and not worth a
detection heuristic.

## What gets compared

Every `build_*.sh` stamps `application/config/version` as
`0.<git commit count> (<short sha>)` (e.g. `0.61 (b154d5c)`). The commit count is
already **monotonic**, so "is there a newer build?" is an integer comparison —
there is no version-string ordering to get wrong. `UpdateCheck.build_number`
drops the sha tag and reads that integer, returning `-1` for anything that
doesn't parse (which disables the check rather than guessing).

`UpdateCheck.should_prompt(current, latest, dismissed)` is the whole decision:

- `latest > current` — there is something newer, and
- `latest > dismissed` — the player hasn't already been shown *this* build.

A "Not now" therefore mutes exactly one build: the next release asks again, but
relaunching does not. The dismissal lives in the **device-local** settings bag
(`Save.get_setting` / `set_setting` under `profile["settings"]`, excluded from
cloud sync — see [save-persistence.md](save-persistence.md)), because dismissing
on a phone says nothing about the desktop install the same career syncs to.

## Where "latest" comes from

`https://felixxwu.github.io/TAPPA/version.json`, published by the release
workflow's `deploy-pages` job:

```json
{ "build": 74, "version": "0.74 (abc1234)", "sha": "abc1234", "url": "https://felixxwu.itch.io/tappa" }
```

It is **generated at deploy time, not committed** — the number it carries is the
commit count of the commit being released, which a checked-in file could never
name. That job's checkout therefore needs `fetch-depth: 0`, exactly like the
export jobs (a shallow clone would publish `1` and tell everyone they're current).

**`deploy-pages` now `needs` the three itch jobs.** That is new, and it is the
one coupling this feature adds to the pipeline: announcing a build whose itch
upload failed would send players to a page still serving the old download. It
costs nothing in release latency — Pages was never in the path that ships the
game — and the job stays `continue-on-error`, so a Pages outage still can't turn
a good release red. `publish-play` is deliberately **not** in `needs`: the Play
build never reaches the prompt, and that job's known failure modes (first-upload
refusal, review holds) must not hold the version document back. See
[release-pipeline.md](release-pipeline.md).

**Why not Firestore.** The project already talks to Firestore ([cloud-save.md](cloud-save.md)),
so a `meta/version` document is the obvious alternative. It was rejected: the
version is public, unowned data, so it would mean a `firestore.rules` change to
make a second collection world-readable *plus* a CI write credential (the release
workflow's `FIREBASE_SERVICE_ACCOUNT` is scoped to "Firebase Rules Admin" and
cannot write documents) — all for something a static file on infrastructure we
already deploy answers. GitHub's API was rejected too: no release tags exist, and
unauthenticated calls are rate-limited **per IP**, which a phone behind carrier
NAT can trip.

## The request, and the prompt

`UpdateCheck.fetch_latest_build(rest)` takes any object with `RestClient`'s
`request_json` — in the game it is handed **`Cloud.rest`**, the project's single
`HTTPRequest` owner (one in-flight request, queued callers), rather than a second
client for one GET per boot. The URL carries a `?from=<current build>`
cache-buster so a CDN can't pin a stale copy. Offline, non-2xx, a missing
document, a malformed `build` field and a null client all return `-1` = "no newer
build"; a version check must never be something the player notices going wrong.

`hq.gd._check_for_update()` is called at the end of `_ready`, **not awaited** —
boot must never wait on a network round trip. It then:

1. re-checks `_view == View.EXTERIOR` **after** the await — the fetch outlives the
   boot frame, so the player may already be in the garage or at the map table, and
   an update notice landing on top of that is an interruption. Nothing is recorded
   as dismissed, so the next boot to the title raises it instead;
2. raises a `ConfirmPopup` (already keyboard + gamepad navigable — see
   [menus.md](menus.md)) with **Not now** / **Get the update**, dismiss-left and
   proceed-right per the house button order, `default_index = 1` and Back routing
   to "Not now";
3. records the dismissal **from the action callbacks**, not before opening.
   `ConfirmPopup.open` returns `null` when another modal owns the screen, and a
   prompt the player never saw must not count as one they've been shown.

"Get the update" is `OS.shell_open(UpdateCheck.STORE_URL)` — the itch page carries
both native builds, so one link covers every platform that can reach the prompt.

## Testing

`tests/headless/test_update_check.gd` runs entirely against `FakeRestClient` (no
network). It pins the things that are invisible when they break: version strings
that must parse to a particular integer (including a sha that is all digits, and
the `0.0-dev` case), the prompt decision including the dismissal window, and that
every failure class — offline, 404, malformed document, no client — reads as "no
newer build". It asserts nothing about the current build number or the contents of
the live document, both of which move every commit.

The HQ placement is deliberately not tested through a booted HQ: `applicable()` is
false in headless, so exercising the modal would mean forcing the gate open and
paying for a full HQ build to assert what the pure functions already cover.
