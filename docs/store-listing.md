# TAPPA — store & description copy

**This file is the single source of truth for how the game is described.** When the
pitch changes, change it here first, then push it out to every surface in the
[checklist](#where-this-copy-has-to-go) at the bottom. Everything below reflects the
post-pivot game (run-based roguelike, not the old rally career) — see
[`../PIVOT-CHANGES.md`](../PIVOT-CHANGES.md) and [`../gameplay.md`](../gameplay.md).

Nothing here should describe a rival field, placements, a world map, a star economy
or a career — all of that is deleted.

---

## Tagline

> **Eight stages, one clock, no second chances.**

## One-liner (≤ 80 chars — Google Play "short description", itch tagline)

> A rally roguelike: eight stages, one clock, no second chances.

(61 chars.)

Alternates, same length budget:

- `Drive eight rally stages against the clock. Miss one and the run is over.` (72)
- `A rally roguelike. Beat every stage timer, or the run ends where you stopped.` (76)

## Short paragraph (GitHub About, link previews, press blurb)

> A rally roguelike built in Godot. Pick a region, pick a car, and drive eight
> point-to-point stages back to back against a fixed target time. Beat a stage and
> you bank money and take a boost; miss one and the run ends on the spot. Lose the
> run, keep the money — and come back faster.

## Medium (itch.io page intro, ~100 words)

> **Eight stages, one clock, no second chances.**
>
> TAPPA is a rally roguelike. Pick a region, pick a car out of your garage, and
> drive eight point-to-point stages back to back. Every stage carries a target
> time — the same target for everyone, whatever car you brought. Beat it and you
> bank the money and pick a boost. Miss it and the run is over, however many
> stages you had left.
>
> There is no rival field and no placement. There's the clock, the car you
> brought, and how much of that car is still working by stage six — because
> damage never destroys a car, but it always slows it.

## Full description (Google Play, ≤ 4000 chars — itch.io long body too)

> **Eight stages, one clock, no second chances.**
>
> TAPPA is a rally roguelike. Pick a region, pick a car, and drive eight
> point-to-point stages back to back. Every stage carries a target time: beat it
> and you bank money and take a boost, miss it and the run ends on the spot.
>
> There is no rival field, no championship table, no placing. There is the clock,
> the car you brought, and how much of that car is still working by stage six.
>
> **The run**
> Eight drawn stages, one car, one clock. Stages come from a hand-authored pool
> per region, so no two runs recite the same eight. Between stages you get one
> choice and it always costs you something: repair the damage you've picked up,
> or take one of a few random boosts. You can't have both.
>
> **Damage that slows you, never stops you**
> Nothing you do to the car ends the run by itself. Bent steering, a tired engine,
> a wheel that won't hold a line — the car keeps going, just slower, and slower is
> how the clock catches you.
>
> **Lose the run, keep everything else**
> A failed run costs you the run and nothing else. Money you've already earned,
> the cars you own, the skills you've bought, your boost levels and your lifetime
> stats all survive it untouched. You lose runs and you get stronger anyway —
> every failure ends with a number to spend and a stat that ticked up.
>
> **A garage worth spending on**
> The stage target doesn't scale to your car, so a faster car is straightforwardly
> better and money converts directly into stages you can survive. Buy cars, buy
> permanent skills, buy boost levels, and grab the coins scattered off the racing
> line if you're brave enough to go get them.
>
> **Regions that open up**
> Regions unlock one at a time. Clear a region's eighth stage and the next one
> opens — tighter clocks, bigger payouts. Cleared regions stay repeatable at full
> payout when you need to fund the next car.
>
> **Daily, weekly and monthly challenges**
> A shared, seeded rally challenge for everyone, with its own leaderboard: one
> long stage a day, four a week, ten a month. No clock to fail against — just
> your time against the world's.
>
> **Also**
> - Free play, if you just want to drive.
> - Full keyboard, gamepad and touch support.
> - Runs are saved mid-run and resumable — put it down at stage five.

## Feature bullets (Play "what's new" style / itch bullet list)

- Eight stages, one clock — miss a target time and the run ends there
- Repair or boost between every stage; you never get both
- Damage slows the car, it never destroys it
- Lose a run, keep the money, cars, skills and stats
- Hand-authored stage pools per region, drawn fresh each run
- Daily / weekly / monthly seeded challenges with leaderboards
- Free play, resumable runs, keyboard + gamepad + touch

## Words to avoid

`career`, `championship`, `rival`, `opponent`, `podium`, `placement`, `stars`,
`world map`, `HQ`, `Gran Turismo-style` — these all describe the pre-pivot game.
"Leaderboard" is fine, but ONLY about the daily/weekly/monthly challenge; there
are no per-stage global leaderboards any more.

---

## Where this copy has to go

In this repo (update these in the same piece of work as any copy change):

- [ ] [`../README.md`](../README.md) — opening paragraph
- [ ] [`../gameplay.md`](../gameplay.md) — "Tagline & fantasy" section
- [ ] [`index.html`](index.html) — `<meta name="description">` and Open Graph tags
      on the GitHub Pages redirect (this is what link previews scrape)

Outside this repo (nothing in git controls these — someone has to paste it):

- [ ] **GitHub repo About** — description field + topics (`godot`, `roguelike`,
      `rally`, `racing`) at <https://github.com/felixxwu/tappa>
- [ ] **itch.io project page** — <https://felixxwu.itch.io/tappa>: tagline (the
      one-liner), page body (medium + full), and the "Genre / Tags" fields, which
      likely still say racing/simulation rather than roguelike
- [ ] **Google Play Console** — Main store listing: short description (≤ 80) and
      full description (≤ 4000). Also check the **screenshots and feature
      graphic**: any shot of the deleted 3D HQ, the overworld map or a rival field
      is now a screenshot of a game that doesn't exist
- [ ] **Play Console content/category** — the category and tags may predate the
      pivot too
- [ ] Anywhere the game is linked socially (profile bios, posts pinned to the
      old pitch)
