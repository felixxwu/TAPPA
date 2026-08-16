#!/usr/bin/env bash
# Regenerate the committed track lockfile.
#
# The opponent-field lockfile is GONE: the rival grid is now drawn matched to the
# PLAYER'S car rating (RallyLibrary.generate_opponent_field's `player_rating`), so a
# field is a function of the player as well as the rally and cannot be keyed on rally
# properties alone. Only the track cache remains cacheable.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$DIR/cache_tracks.sh"
