#!/usr/bin/env bash
# Regenerate BOTH committed lockfiles in dependency order: tracks first (the opponent
# field's times are computed over the cached tracks), then opponents.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$DIR/cache_tracks.sh"
"$DIR/cache_opponents.sh"
