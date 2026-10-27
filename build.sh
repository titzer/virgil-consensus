#!/usr/bin/env bash
# Builds each protocol's test program as a native binary in bin/.
# Usage: ./build.sh [protocol...]        build (default: all protocols)
#        ./build.sh test [protocol...]   build, then run scenarios and a short fuzz
# Set VIRGIL to the Virgil checkout (default: ~/Code/virgil).
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
VIRGIL=${VIRGIL:-$HOME/Code/virgil}
export PATH=$VIRGIL/bin:$PATH
ALL="paxos raft dolevstrong pbft"

case "$(uname -s)-$(uname -m)" in
	Darwin-*)        V3C=v3c-x86-64-darwin ;;
	Linux-x86_64)    V3C=v3c-x86-64-linux ;;
	Linux-aarch64)   V3C=v3c-arm64-linux ;;
	*)               echo "unsupported host; use run.sh to run in the interpreter"; exit 1 ;;
esac

TEST=0
if [ "$1" = "test" ]; then TEST=1; shift; fi
PROTOCOLS=${@:-$ALL}

mkdir -p bin
for p in $PROTOCOLS; do
	[ -d "$p" ] && ls $p/*.v3 > /dev/null 2>&1 || continue
	rm -f bin/$p
	# The Virgil scripts print a harmless git warning outside the Virgil repo.
	$V3C -output=bin -program-name=$p core/*.v3 $p/*.v3 $VIRGIL/lib/util/*.v3 2>&1 | grep -v "outside repository" || true
	[ -x bin/$p ] || { echo "build of $p failed"; exit 1; }
	echo "built bin/$p"
done

if [ $TEST = 1 ]; then
	for p in $PROTOCOLS; do
		[ -x bin/$p ] || continue
		echo "=== $p"
		bin/$p scenarios
		bin/$p fuzz -runs=10000
	done
fi
