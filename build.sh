#!/usr/bin/env bash
# Builds the Paxos scenarios and fuzzer as native binaries in bin/.
# Usage: ./build.sh            build native binaries
#        ./build.sh test       build, then run scenarios and a short fuzz
# Set VIRGIL to the Virgil checkout (default: ~/Code/virgil).
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
VIRGIL=${VIRGIL:-$HOME/Code/virgil}
export PATH=$VIRGIL/bin:$PATH

case "$(uname -s)-$(uname -m)" in
	Darwin-*)        V3C=v3c-x86-64-darwin ;;
	Linux-x86_64)    V3C=v3c-x86-64-linux ;;
	Linux-aarch64)   V3C=v3c-arm64-linux ;;
	*)               echo "unsupported host; use run.sh to run in the interpreter"; exit 1 ;;
esac

LIB="$VIRGIL/lib/util/*.v3"
PROTOCOL="Paxos.v3 Sim.v3 Diagram.v3"
mkdir -p bin
$V3C -output=bin $PROTOCOL Scenarios.v3 $LIB
$V3C -output=bin $PROTOCOL Fuzz.v3 $LIB
echo "built bin/Scenarios bin/Fuzz"

if [ "$1" = "test" ]; then
	bin/Scenarios
	bin/Fuzz -runs=10000
fi
