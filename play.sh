#!/usr/bin/env bash
# Plays a simulation interactively: each event waits for a key.
# Usage: ./play.sh <protocol> fuzz [-seed=N] [-bug=NAME] ...
#        ./play.sh <protocol> scenarios <name-filter>
# Keys: SPACE default event, ENTER run to completion, q finish quietly,
#       1-9/A-Z pick a message, c crash, r restart, t fire a timer.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
P=$1
shift
[ -x bin/$P ] || ./build.sh $P > /dev/null
if [ -t 0 ]; then
	SAVED=$(stty -g)
	trap 'stty "$SAVED"' EXIT INT TERM
	stty -icanon -echo min 1
fi
bin/$P "$@" -play
