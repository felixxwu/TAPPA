class_name StaleGuard
## A generation-token guard for "is this async result still wanted?".
##
## This project hand-rolls the same idiom at least six times, in five files, each
## under its own private name: hq.gd's `_settle_generation` (car-park prop spawn)
## and `_challenge_refresh_generation` (challenge overlay board queries),
## settings_menu.gd's `_sl_gen` (seed-lab preview, plus an `abort: Callable`
## closure fed to TrackGenerator.generate), and standings.gd / podium.gd's
## `_reveal_gen` (leaderboard reveal coroutines). All six do the same three
## things: bump an int when the underlying state is rebuilt/discarded, capture
## that int before starting async work (an `await`, a progressive per-frame
## spawn, a generated search), and compare the captured value to the CURRENT
## one after the `await` returns before touching anything. This class gives
## that idiom a name and a shape so the next instance is written once, is
## greppable as `StaleGuard`, and doesn't need re-deriving from scratch.
##
## THE RULE THIS EXISTS TO ENFORCE: a Control's DISPLAYED TEXT IS NEVER A VALID
## KEY for deciding whether an async result still applies. `UITheme.enforce`
## (scripts/ui_theme.gd) uppercases every Label's and Button's text after a page
## is built, as a blanket styling pass applied well after the page's own code
## set that text. A handler that captures `label.text` (e.g. "Top 50%") before
## an `await` and later compares it back against the same literal is comparing
## against a string UITheme has since rewritten to "TOP 50%" — the comparison
## silently and permanently fails, because the check runs on a DERIVED,
## presentation-layer value instead of the semantic identity of "which rebuild
## is this". Text comparison looks equivalent to a generation check only
## because both are "compare something now to something captured earlier" —
## but text is subject to later, unrelated rewrites (styling, localization,
## truncation) that a generation counter is not: nothing but this class ever
## touches the token, so it stays a faithful stand-in for "was there a rebuild
## since I started".
##
## Usage:
##   var guard := StaleGuard.new()
##   func rebuild() -> void:
##       guard.bump()  # cancel anything still in flight for the old state
##       var token := guard.token()
##       var result: Dictionary = await do_async_work()
##       if not guard.is_current(token):
##           return  # a newer rebuild superseded this run
##       apply(result)

var _generation := 0


## Invalidates every token captured before this call. Call once per rebuild,
## right before the old state is torn down or replaced.
func bump() -> void:
	_generation += 1


## Captures a token representing "the current rebuild", to be checked again
## after an await.
func token() -> int:
	return _generation


## True if `t` was captured from the generation that is still current, i.e.
## no `bump()` has happened since. Call this after every `await`/yield before
## acting on stale-async results.
func is_current(t: int) -> bool:
	return t == _generation
