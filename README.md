# Paxos in Virgil

Single-decree Paxos with a deterministic network simulator, hand-written
scenarios, a fuzzer, and an ASCII message-sequence-diagram printer.

| File | Contents |
|------|----------|
| `Paxos.v3` | The protocol: `Msg` ADT, `PaxosNode` (proposer + acceptor + learner), stable vs. volatile state. No simulator dependencies. |
| `Sim.v3` | Simulator: `Rng`, in-flight `Packet`s, fault injection, crash/restart, `SafetyChecker` oracle, `SimListener`/`TextLog`. |
| `Diagram.v3` | `Diagram` listener: prints runs as lifeline diagrams. |
| `Scenarios.v3` | Scripted scenarios (program with its own `main`). |
| `Fuzz.v3` | Randomized fuzzer (program with its own `main`). |

## Building and running

```sh
./build.sh            # native binaries in bin/ (needs ~/Code/virgil, or set VIRGIL=...)
./build.sh test       # build, run all scenarios and 10k fuzz runs

bin/Scenarios                 # run all scenarios
bin/Scenarios -v preemption   # diagram of scenarios whose name contains "preemption"
bin/Fuzz -runs=100000         # fuzz
bin/Fuzz -bug=adopt           # fuzz a deliberately broken protocol; finds violations
bin/Fuzz -seed=77 -runs=1 -v -bug=adopt   # replay one failing run as a diagram

./run.sh Scenarios -v happy   # same programs, in the interpreter
```

## Protocol

Messages (`type Msg`): `Prepare`, `Promise`, `Accept`, `Accepted`, `Nack`, and
two outcome-dissemination messages, `Query` and `Decided`. Ballots are
`round * N + id`, so they are unique per proposer. Acceptors broadcast `Accepted`
to every node, and a node learns a value when it sees a majority of acceptors
accept the same ballot.

Nodes never touch the network. `receive()` and `onTimeout()` append to
`outbox`, and the environment drains it. The environment also decides when
timers fire, so all the randomness lives in the simulator.

`crashAndRestart()` keeps only `PaxosStable` (the promise, the accepted
ballot and value, and the proposer's round counter). Everything else is lost.
`PaxosConfig` can turn off parts of the protocol to inject bugs:

| `-bug=` | Bug | Typical detection |
|---------|-----|-------------------|
| `acceptor` | acceptor state is not persisted | ~8% of runs |
| `adopt` | proposer ignores values reported in promises | ~13% of runs |
| `round` | proposer's ballot round is not persisted (ballot reuse) | rare: 2 in 1M runs |

## Simulation and checking

Each `Sim.step()` crashes and restarts nodes at random, fires retry timers
that have expired (each timer is reset to a random value in
`[timeoutMin, timeoutMax]`), and delivers a random subset of in-flight
messages in shuffled order. A delivered message can be dropped, or duplicated
so that it stays in flight. Scenarios can also script delivery precisely with
`deliverIf`, `dropIf`, `kick`, `crash` and `restart`.

`SafetyChecker` is an oracle that sees every acceptance. It treats a value as
chosen once a majority of acceptors accept it in the same ballot, and it
checks these properties:

- no ballot is accepted with two different values
- only proposed values are accepted
- at most one value is ever chosen
- learners only learn the chosen value

Each fuzz run draws a cluster size (1–7), a set of proposers, timer ranges and
a fault profile from its seed. It runs up to `-chaos` rounds with faults, then
the network stabilizes: no drops, duplicates or crashes, and every node
restarts. Within `-bound` rounds after that, every node must decide
(liveness).

## Diagrams

```
round    N0    N1    N2
legend: X sender, > < receiver, x lost, o timeout, ! crash, + restart, # learn
0         o     |     |    N0 timeout: starts a ballot
          X---->|---->|    Prepare(b=3)
          |<----X-----X    Promise(b=3, ab=0, av=0)
          X---->|     |    Accept(b=3, v=10)
          |     |     |    *** value 10 is chosen (ballot 3) ***
```

In each batch of deliveries, copies of the same message from the same sender
are drawn as one line. Lines that carry the same message to the same
receivers are merged. A down node's lifeline is drawn as `:`.
