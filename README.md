# Consensus protocols in Virgil

Simulated implementations of four consensus and broadcast protocols, for learning.
They share one deterministic network simulator, one fuzzer and one ASCII
message-sequence-diagram printer:

| Protocol | Fault model | Directory |
|----------|-------------|-----------|
| Paxos (single-decree) | crash faults, asynchronous network | `paxos/` |
| Raft (election + log replication) | crash faults, asynchronous network | `raft/` |
| Dolev-Strong (authenticated broadcast) | Byzantine faults (any f < n), synchronous network | `dolevstrong/` |
| PBFT (normal case + view change) | Byzantine faults (f < n/3), asynchronous network | `pbft/` |

For a guided tour of how each protocol works, illustrated with diagrams from real
runs, see [EXPLAINER.md](EXPLAINER.md).

## Building and running

```sh
./build.sh                    # native binaries bin/paxos, bin/raft, bin/dolevstrong, bin/pbft
./build.sh test               # build, then run every protocol's scenarios, 10k fuzz runs, and selftest
./build.sh raft               # build just one

bin/paxos scenarios                     # run all scenarios
bin/paxos scenarios -v preemption       # diagram of scenarios whose name contains "preemption"
bin/paxos fuzz -runs=100000             # fuzz
bin/paxos fuzz -seed=77 -runs=1 -v      # replay one fuzz run as a diagram
bin/paxos                               # usage

./run.sh paxos scenarios -v happy       # same programs, in the interpreter
```

### Interactive play

```sh
./play.sh raft fuzz -seed=13                   # step through a fuzz run, one event at a time
./play.sh paxos scenarios dueling              # play a randomized scenario
```

Before each event, the simulation stops and shows the event it is about to
perform (the default), the messages in flight, and the other actions that
make sense right now:

| Key | Action |
|-----|--------|
| `SPACE` | perform the default event |
| `ENTER` | stop asking and run the rest to completion (the diagram keeps printing) |
| `q` | run the rest to completion quietly, printing only the verdict |
| `1`-`9`, `A`-`Z` | pick an in-flight message, then `SPACE`/`d` deliver it, `x` drop it, `2` deliver it and keep a duplicate in flight |
| `c` / `r` | crash an up node / restart a down node |
| `t` | fire one of a node's timers (e.g. force an election or a view change) |

Only actions within the protocol's fault model are offered. Dolev-Strong is
synchronous, so its messages can only be reordered within a round. PBFT's
honest replicas can't be crashed. The default event is planned with the same
random numbers the simulator would use, so pressing only SPACE replays the
seed's run exactly. Any other key turns it into a run of your own, still
watched by the protocol's checker.

`play.sh` puts the terminal into raw mode, so a key registers without ENTER,
and restores it on exit. Each menu is erased after use, so only the diagram
stays on screen. Without the wrapper, `bin/<protocol> ... -play` reads keys
from stdin, so you can script a session: `printf '   2x' | bin/paxos fuzz
-seed=77 -play -plain`. Add `-plain` to turn off the ANSI escape codes.
Scripted scenarios run their scripted steps without stopping; only events
from the random simulator (`Sim.step`) wait for a key.

The build script uses the Virgil checkout in `~/Code/virgil`, or `$VIRGIL` if
it is set. The scenario filter is the last non-flag argument, and it matches
part of the scenario name, case-sensitively. Quote filters that contain
spaces. `-trace` prints a plain event log instead of a diagram.

## Layout

| File | Contents |
|------|----------|
| `core/Node.v3` | `Node<M>`: base class for a protocol node. It has an `outbox` and requests to start or stop timers, and no network or clock. |
| `core/Sim.v3` | `Rng`, `Packet<M>`, `SimFaults`, `Sim<M>`, `SimListener<M>`, `TextLog<M>`. |
| `core/Crypto.v3` | Simulated signatures: `Sig`, `KeyRing`, `Signer`, `Digest`. |
| `core/Diagram.v3` | `Diagram<M>`: prints any simulation as a lifeline diagram. |
| `core/Driver.v3` | Command-line driver: `TestOptions`, `Scenario`, `Suite`, `Injection`, scenario runner, fuzz loop, selftest. |
| `core/Play.v3` | `Player<M>`: the interactive controller for `-play`. |
| `<protocol>/<Name>.v3` | The protocol itself: its message ADT and node class. |
| `<protocol>/<Name>Test.v3` | Simulation harness, safety and liveness checker, scenarios, fuzzer, `main`. |

Each protocol is compiled as its own program: `core/*.v3`, plus its
directory, plus Virgil's `lib/util`.

## The simulator

A `Sim<M>` owns the nodes, the messages in flight, and all randomness. Each
`step()` is a sequence of events: `planNext()` picks each one and `perform()`
executes it, and a `SimController` such as the interactive player may step in
between. A step:
1. crashes and restarts nodes at random (`crashPct`, `restartPct`);
2. fires expired timers;
3. delivers a random subset of in-flight messages (`deliverPct`) in shuffled
   order.

A delivered message can be dropped (`dropPct`), or duplicated so that it also
stays in flight (`dupPct`). Timers come in kinds (`addTimer(min, max)`), and
each firing gets a random duration in that range. Nodes can restart or stop
their own timers. `faults.synchronous()` turns this into a lockstep
synchronous network: every message is delivered in the next round, and a
`[1,1]` timer marks round boundaries. Scenarios script events precisely with
`fire`, `deliverIf`, `dropIf`, `crash` and `restart`.

Channels are authenticated, so a packet's `src` is genuine. Signatures
(`core/Crypto.v3`) are needed for evidence that can be passed on to others,
such as Dolev-Strong chains and PBFT view-change certificates. A signature's
tag is a keyed hash under the signer's secret. Only that node's `Signer`, or
the adversary for a Byzantine node, holds the secret. Anyone can construct a
`Sig` value, but a forged one fails `KeyRing.verify`.

## Diagrams

```
round    N0    N1    N2
legend: X sender, > < receiver, x lost, o timer, ! crash, + restart
0         o     |     |    N0 timeout: starts a ballot
          X---->|---->|    Prepare(b=3)
          |<----X-----X    Promise(b=3, ab=0, av=0)
          X---->|     |    Accept(b=3, v=10)
          |     |     |    *** value 10 is chosen (ballot 3) ***
```

In each batch of deliveries, copies of the same message from the same sender
are drawn as one line. Lines that carry the same message to the same
receivers are merged. A down node's lifeline is drawn as `:`, and Byzantine
nodes are labeled `B<i>`. Protocols mark their own events on lifelines, for
example `#` when a node learns a value.

## Paxos

Messages (`type PaxosMsg`): `Prepare`, `Promise`, `Accept`, `Accepted`,
`Nack`, plus `Query` and `Decided`, which spread the outcome to nodes that
missed it. Ballots are `round * N + id`. Every node is a proposer, an
acceptor and a learner. `PaxosStable` holds the state that survives a crash.
The checker treats a value as chosen once a majority of acceptors accept it
in the same ballot. It checks that a ballot never has two values, that only
proposed values are accepted, that at most one value is chosen, and that
learners learn only the chosen value. Each fuzz run has a chaos phase, then
the network stabilizes and every node must decide.

## Raft

Messages (`type RaftMsg`): `RequestVote`, `Vote`, `AppendEntries`,
`AppendResp`, and `ClientRequest`, which a follower uses to forward a command
to the leader. `RaftStable` holds the state that survives a crash: the term,
the vote and the log. There are two timers. The election timer restarts when
a node hears from the leader or grants a vote, and the heartbeat timer drives
the leader's AppendEntries. A leader commits only entries from its own term
(Figure 8). A new leader appends a no-op by default; fuzz runs sometimes turn
this off, which makes Figure 8-style schedules more likely. The harness injects client commands with
`sim.act()`.

The checker enforces these properties:
- Election Safety: at most one leader per term.
- Log Matching: checked across every pair of logs, every round.
- Leader Completeness: a new leader holds every committed entry.
- State Machine Safety: every node applies the same command at each index, in order.

For liveness, after stabilization every node must apply a newly submitted
command.

## Dolev-Strong

Authenticated Byzantine broadcast. It tolerates any f < n faulty nodes, in
f+1 synchronous rounds (`faults.synchronous()`, plus a quiet `[1,1]` timer
that marks each round). The only message is `Chain(value, sigs)`.
- A chain delivered in round r is valid if it has at least r signatures, the
  first signer is the sender, all signers are distinct, and every signature
  verifies.
- Signature k signs a digest of the value and signers 0..k-1.
- A node extracts at most two values, and relays each with its own signature
  appended.
- At the start of round f+2, a node outputs its value if it extracted exactly
  one, and bottom (0) otherwise.

All faulty nodes are controlled by one colluding `DsAdversary`, which holds
only their keys. Its strategies:
- silent
- honest, then crashes
- equivocating sender and selective relays
- random garbage
- forged honest signatures
- late release: reveal a second value to a single honest node in the last
  round where its chain is still valid

The checker enforces agreement, validity (if the sender is honest, everyone
outputs its value) and termination. It also checks that no honest node accepts
a forged chain.

## PBFT

The signature-based variant, with n = 3f+1 replicas, the normal case and
view changes, and no checkpoints. Messages (`type PbftMsg`): `PrePrepare`,
`Prepare`, `Commit`, `ViewChange` (which carries prepared certificates) and
`NewView`. There are also `Fetch` and `Proof`, which let a lagging replica
fetch commit certificates. They stand in for the state transfer that
checkpoints would provide.

Every message is signed. Certificates are verified against the `KeyRing`, and
the new primary's proposals are recomputed from the ViewChanges it presents.
View-change timeouts back off exponentially, and a replica joins a higher view
once it receives f+1 ViewChanges for it. Honest replicas never crash, but the
network drops, duplicates and reorders messages during the chaos phase. The
client retransmits requests that haven't been executed everywhere.

All faulty replicas are controlled by one colluding adversary; the initial
primary is often faulty. Its strategies:
- silent, or crash partway through
- equivocate: send different, validly signed versions of each broadcast,
  including NewViews whose proposals don't match their ViewChanges
- random garbage
- ViewChanges carrying certificates with forged honest signatures

The checker requires that, at every sequence number, honest replicas execute
the same op, that only submitted ops are executed, and that no op is executed
twice. For liveness, after stabilization every request must be executed by
every honest replica, even though the adversary keeps misbehaving.

## Verification

Fuzz runs of each correct protocol in the final code, all with zero safety
and zero liveness failures. Times are for the x86-64 binaries running under
Rosetta on an Apple M4 Pro.

| Protocol | Runs | Time |
|----------|------|------|
| Paxos | 200k | 14s |
| Raft | 100k | 36s |
| Dolev-Strong | 1M | 12s |
| PBFT | 50k | 35s |

## Fault injection

The checkers are only as good as the mistakes they can catch. A fuzzer that
reports "0 failures" proves little unless it would have noticed a real error.
So each protocol has a few *injectable faults*. Each one is a deliberate,
classic protocol mistake that removes one rule of the correct protocol. They
are off by default and live in a small `...Injected` class next to each
protocol (for example, `PaxosInjected`). Turning one on with `-inject=NAME`
should make the checker report violations, which shows that the checks and
the fuzzing are strong enough to notice.

These are separate from the *fault models* the protocols are designed to
survive: lost, duplicated and reordered messages, crashes, and Byzantine
adversaries. Those are always on in fuzzing, and the correct protocols must
handle them.

```sh
bin/paxos selftest                              # every injection: its scenarios, then fuzz until caught
bin/raft fuzz -inject=skip-uptodate-check       # fuzz with one fault injected
bin/raft fuzz -inject=skip-uptodate-check -seed=13 -runs=1 -v   # watch a counterexample
./play.sh paxos fuzz -inject=ignore-promises    # try to break it by hand
```

`selftest` runs each injection's scripted scenarios, which must detect it,
then fuzzes with the fault injected (up to `-runs`, default 20,000) until the
checker catches it. The rates below come from 100k–1M fuzz runs each.

| Protocol | `-inject=` | Fault | Caught in |
|----------|-----------|-------|-----------|
| Paxos | `forget-acceptor` | acceptor state is lost on a crash | 1 in 12 runs |
| Paxos | `ignore-promises` | proposer ignores values reported in promises | 1 in 8 runs; also a scenario |
| Paxos | `forget-round` | proposer's ballot round is lost on a crash (ballot reuse) | 2 in 1M runs |
| Raft | `skip-uptodate-check` | votes granted without the log up-to-date check | 1 in 16 runs |
| Raft | `truncate-on-match` | follower truncates its log even when entries match | 1 in 180 runs |
| Raft | `forget-vote` | `votedFor` is lost on a crash, so a node can vote twice in a term | 1 in 320 runs |
| Raft | `commit-old-terms` | leader commits old-term entries by counting replicas (Figure 8) | 6 in 200k runs; always caught by its scenario |
| Dolev-Strong | `skip-sig-check` | signatures are not verified | 1 in 4 runs; also a scenario |
| Dolev-Strong | `one-round-short` | decide after f rounds instead of f+1 | 1 in 6 runs; also a scenario |
| Dolev-Strong | `skip-relay` | newly extracted values are not relayed | 1 in 13 runs |
| Dolev-Strong | `skip-distinct-check` | signers needn't be distinct, so a chain can be padded | 1 in 100 runs; also a scenario |
| PBFT | `omit-prepared` | ViewChanges omit prepared certificates | 1 in 3 runs (mostly as liveness failures) |
| PBFT | `weak-quorum` | 2f instead of 2f+1 for commit and new-view quorums | 1 in 38 runs |
| PBFT | `skip-cert-sigs` | signatures inside view-change certificates aren't checked | 1 in 56 runs; also a scenario |
| PBFT | `trust-newview` | NewView accepted without recomputing its proposals | 1 in 1,260 runs |
