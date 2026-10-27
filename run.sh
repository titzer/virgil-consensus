#!/usr/bin/env bash
# Runs a protocol's test program in the Virgil interpreter (no compilation step).
# Usage: ./run.sh <protocol> scenarios|fuzz [args...]
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
VIRGIL=${VIRGIL:-$HOME/Code/virgil}
P=$1
shift
"$VIRGIL/bin/v3i" core/*.v3 $P/*.v3 "$VIRGIL"/lib/util/*.v3 "$@" 2>&1 | grep -v "outside repository"
