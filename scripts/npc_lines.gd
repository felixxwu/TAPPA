class_name NpcLines
# Docs: features/npc-dialogue.md — update in the same change as this file.
# Everything the characters say: each conversation is a list of pages, %d filled in by `fill` with a number from the game.

const WELCOME := [
	"Welcome to Hafren Forest. You'll be needing some wheels.",
	"You've got £%d to spend here, however you like.", # the player's money
	"Buy a cheap car and fit it with upgrades, or just buy something quicker. Up to you.",
]

const FIRST_DRIVE := [
	"There's a delivery waiting to be picked up down the road.",
	"Follow the sat nav to the pick-up point.",
]

const DISPATCHER_GREETING := [
	"Morning! I've got %d deliveries on offer here.", # deliveries at this point
	"Take any of them and I'll pay you when you get it there.",
]

const RECIPIENT_THANKS := [
	"That's just what I was waiting for!",
	"I've got some things that need delivering myself, if you fancy another job.", # deliveries at this point
]


static func fill(pages: Array, n: int) -> Array:
	return pages.map(func(p: String) -> String: return p % n if "%d" in p else p)
