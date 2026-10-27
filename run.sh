#!/usr/bin/env bash
# Runs a program in the Virgil interpreter (no compilation step).
# Usage: ./run.sh Scenarios|Fuzz [args...]
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
VIRGIL=${VIRGIL:-$HOME/Code/virgil}
PROG=$1
shift
exec "$VIRGIL/bin/v3i" Paxos.v3 Sim.v3 Diagram.v3 "$PROG.v3" "$VIRGIL"/lib/util/*.v3 "$@"
