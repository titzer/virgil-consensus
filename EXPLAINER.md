# How consensus works, by watching it fail

This repository holds four classic agreement protocols, each implemented in
Virgil and run inside a deterministic simulator. Each protocol comes with a
checker that knows exactly what "correct" means, and with a fuzzer that
attacks it. Every protocol also has a few deliberately broken variants. The
idea is not just that the protocols work, but that you can watch why each rule
is there by switching it off and seeing what breaks.

| Protocol | Problem | Faults tolerated | Network | Replicas needed |
|----------|---------|------------------|---------|-----------------|
| Paxos | agree on one value | f crashes | asynchronous | 2f+1 |
| Raft | agree on a log of commands | f crashes | asynchronous | 2f+1 |
| Dolev-Strong | broadcast one value | f Byzantine, any f < n | synchronous | f+1 or more (any n > f) |
| PBFT | agree on a log of requests | f Byzantine | asynchronous* | 3f+1 |

\* PBFT is safe in a fully asynchronous network. It needs eventual synchrony
only for liveness: view changes must eventually complete.

## Reading the diagrams

Every scenario and every fuzz run can be printed as a message sequence chart
(`-v`). Each node has a vertical lifeline, and each line is one event:

```
round    N0    N1    N2
0         o     |     |    N0 timeout: starts a ballot
          X---->|---->|    Prepare(b=3)
          |<----X-----X    Promise(b=3, ab=0, av=0)
```

| Symbol | Meaning |
|--------|---------|
| `X` | sender of the message on this line |
| `>` `<` | receivers (the arrow points at them) |
| `x` | a receiver whose copy was lost |
| `o` | a timer fired |
| `!` `+` | crash, restart |
| `:` | lifeline of a node that is down |
| `B3` | header label for a Byzantine (faulty) node |
| `#` and other letters | protocol events: `#` learn/apply/execute/decide, `L` becomes leader, `C` candidate, `*` extract or enter view, `v` start view change |

When several nodes send identical messages to the same receivers, they are
drawn on one line. That's why `|<----X-----X` shows two acceptors answering a
proposer.

## The simulator

Real distributed systems are hard to test because the bad interleavings are
rare and impossible to reproduce. The simulator (`core/Sim.v3`) replaces the
network, the clock and the randomness with one deterministic object:

- Nodes are pure state machines. A `Node<M>` reacts to `receive(src, msg)`
  and `onTimer(kind)` by appending to an outbox. It never sends anything or
  reads a clock itself.
- Each round, the simulator:
  - crashes and restarts nodes at random;
  - fires expired timers;
  - delivers a random subset of messages in flight, in shuffled order;
  - drops some deliveries, and duplicates others so that a copy stays in
    flight.
- Everything comes from one seeded RNG. A failing fuzz run prints its seed,
  and `-seed=S -runs=1 -v` replays it event for event as a diagram.
- `faults.synchronous()` gives Dolev-Strong its lockstep model: every message
  is delivered in the next round, and a `[1,1]` timer marks each round.
- A crash keeps only the state the protocol explicitly marked as persistent,
  such as `PaxosStable` or `RaftStable`. Forgetting to persist something is
  one of the injectable bugs.

**Signatures without cryptography** (`core/Crypto.v3`). Channels are
authenticated, so a packet's `src` is always genuine. But Byzantine protocols
need *transferable* evidence: "node 3 signed this, and I can prove it to you".
A `Sig` carries a tag that is a keyed hash under the signer's secret, and only
that node's `Signer` holds the secret. A Byzantine node can build any `Sig`
value it wants, such as one claiming to be from node 2, but `KeyRing.verify`
rejects it. That's the property real signatures provide, and it's all the
protocols rely on.

## How the testing works

Each protocol has three layers of testing:

1. **An oracle checker.** It sees every event in the whole system, which no
   real node could, and checks the protocol's safety properties after every
   step. For example, Paxos's checker knows a value is chosen the moment a
   majority accepts it in one ballot, even if no node knows that yet.
2. **Scenarios.** These are scripted runs with timers off. They choose exactly
   which messages arrive (`deliverIf`), which get lost (`dropIf`), and who
   crashes. Each one reproduces a textbook situation.
3. **A fuzzer.** Each run draws a cluster size, fault rates, timer ranges and
   Byzantine strategies from its seed. It runs a *chaos* phase, then a
   *stabilization* phase. In chaos, anything goes and only safety must hold.
   Stabilization means no drops or crashes and every node restarted, and the
   protocol must then make progress. This tests liveness the only way that
   makes sense: no protocol can guarantee progress while the network is
   adversarial (the FLP impossibility result).

**Injected bugs check the checkers.** A fuzzer that never fails proves nothing
unless it can catch real mistakes. Each protocol exposes `-bug=NAME` switches
that remove one rule. If the fuzzer catches that variant, the rule matters and
the tests are strong enough to notice. Detection rates appear below. Some bugs
take a million runs to show up, which is exactly why these protocols are
famously subtle.

---

## Paxos: the value may already be chosen

**The problem.** Several proposers want different values chosen. Messages are
lost and reordered, and nodes crash. Exactly one value must ever be chosen.

**The protocol.**
- *Phase 1.* A proposer picks a unique ballot b and sends `Prepare(b)`. Each
  acceptor promises to ignore lower ballots, and reports the last value it
  accepted, if any.
- *Phase 2.* With promises from a majority, the proposer sends `Accept(b, v)`.
  A value is *chosen* once a majority accepts it in the same ballot.

**The key rule.** In phase 2, v must be the value with the highest ballot
among those reported in the promises. The proposer may use its own value only
if no one reported one. Any two majorities share an acceptor, so if some value
was already chosen, at least one promise reports it.

In this run (`bin/paxos scenarios -v "chosen value survives"`), N0 gets 10
chosen, but every `Accepted` notification is lost, so nobody knows. N4 then
runs a higher ballot with a different quorum. N2 overlaps both quorums, and
its promise carries `ab=5, av=10`:

```
round    N0    N1    N2    N3    N4
          X---->|---->|     |     |    Accept(b=5, v=10)
          |     |     |     |     |    *** value 10 is chosen (ballot 5) ***
          ...                          (all Accepted notifications lost)
          |     |     |<----|<----X    Prepare(b=14)
          |     |     X-----X---->|    Promise(b=14, ab=5, av=10)
          |<----|<----|<----|<----X    Accept(b=14, v=10)      <- N4 adopts 10, not its own 20
          |<----------X     |     |    Accepted(b=14, v=10)
          #     |     |     |     |    N0 learns 10
```

With `-bug=adopt`, N4 proposes its own 20, and the checker reports
`two values chosen: 10 and 20`. Every other rule matters too:
- `-bug=acceptor`: an acceptor that forgets its promise after a crash.
  Caught in about 1 in 12 runs.
- `-bug=round`: a proposer that forgets its ballot counter after a crash, so
  it reuses a ballot number with a different value. Caught 2 times in a
  million runs, because it needs a crash at just the wrong moment.

## Raft: Paxos for a log, with a strong leader

**The problem.** Replicate a log of commands so that every node applies the
same commands in the same order.

**The protocol.**
- Time is divided into *terms*. Each term has at most one leader, elected by
  a majority with `RequestVote`.
- The leader appends client commands to its log and replicates them with
  `AppendEntries`. Each one carries the index and term of the preceding entry,
  so a follower whose log diverges rejects it. The leader then backs up and
  overwrites the follower's conflicting entries.
- An entry is *committed* once it's stored on a majority, and nodes apply
  committed entries in order.

**Two subtle rules:**
1. *Voting restriction.* Grant a vote only if the candidate's log is at least
   as up to date as yours. Since committed entries are on a majority, and any
   winning majority overlaps that one, every new leader has every committed
   entry. Without this rule (`-bug=uptodate`), a node with a stale log can win
   and overwrite committed entries. Caught in 1 in 16 runs.
2. *Only count replicas for current-term entries* (Figure 8 of the Raft
   paper). An entry from an older term can be on a majority and still be
   overwritten later. A leader therefore commits old entries only indirectly,
   by committing a newer entry from its own term.

The Figure 8 scenario (`bin/raft scenarios -v "figure 8"`) builds the
counterexample step by step. N0, leader of term 2, puts entry `2:2` on N0 and
N1 only. N4 becomes leader of term 3 and writes `3:3` locally. N0 returns as
leader of term 4 and spreads `2:2` to a majority. Under `-bug=commit`, N0
counts replicas and commits `2:2`. Then N4 is elected again: its last log
entry, `3:3`, has a higher term than `2:2`, so the up-to-date rule lets it
win. It overwrites `2:2`:

```
          :     |     |     |     L    N4 becomes leader of term 5
          :     |     |     |     |    !!! SAFETY VIOLATION: leader completeness: leader 4 of term 5 lacks committed entry 2=2:2
          ...
          :     |     |     |     |    !!! SAFETY VIOLATION: state machine safety: node 4 applied index 2 = 3:3 but 2:2 was committed
```

The correct protocol refuses to commit `2:2` in term 4, so N4 overwriting it
is legal. The usual fix is for a new leader to append a no-op entry, which
commits everything before it; Raft does that here by default. Fuzz runs
sometimes turn the no-op off, because the no-op hides bugs: with it on, the
old entry usually gets committed legitimately.

The other bugs:
- `-bug=vote`: forgetting `votedFor` after a crash, so a node votes twice in
  one term. Caught in 1 in 320 runs.
- `-bug=truncate`: truncating the log on every AppendEntries, even when the
  entries match. A delayed, duplicate message then erases committed entries.
  Caught in 1 in 180 runs.

## Dolev-Strong: when you can't trust anyone, wait f+1 rounds

**The problem.** A sender broadcasts a value to n nodes. Up to f of the nodes,
possibly including the sender, are *Byzantine*: they lie, collude and send
different things to different people. Every honest node must output the same
value, and it must be the sender's value if the sender is honest.

Without signatures this needs n > 3f. With signatures, Dolev-Strong handles
**any** f < n, at the price of a synchronous network and f+1 rounds.

**The protocol.**
- Messages are *signature chains*: a value plus an ordered list of
  signatures, starting with the sender's.
- A chain delivered in round r is valid only if it carries at least r
  distinct, valid signatures.
- When an honest node sees a valid chain for a new value, it accepts
  ("extracts") the value, adds its own signature, and relays the chain to
  everyone.
- After round f+1, a node outputs the value if it extracted exactly one;
  otherwise it outputs bottom (the faulty sender equivocated).

**Why f+1 rounds?** The danger is a value that reaches one honest node so
late that it can't be passed on. A chain delivered in round f+1 has f+1
distinct signers, and at most f of them are faulty, so at least one signer is
honest. That honest node accepted the value in an earlier round and has
already relayed it to everyone. So any value accepted in the last round was
already seen by all honest nodes.

The *late-release* attack tests exactly this. Faulty sender B0 sends value 1
to everyone and, together with B1, secretly builds a chain for value 2, which
it reveals only to N2. With f=2 there are three rounds, so N2 still has time
to relay, and both honest nodes see both values:

```
round    B0    B1    N2    N3
2         |     X---->|     |    Chain(v=2, 0>1)          <- revealed only to N2
          |     |     *     |    N2 extracts 2
3         |     |     X---->|    Chain(v=2, 0>1>2)        <- N2 relays it in time
          |     |     |     *    N3 extracts 2
4         |     |     #     |    N2 decides bottom
          |     |     |     #    N3 decides bottom        <- agreement
```

With `-bug=rounds`, nodes decide one round early. N2 has extracted 2, but N3
never hears about it, so N2 outputs bottom while N3 outputs 1: agreement is
broken. Caught in 1 in 6 fuzz runs. The other bugs:

| Bug | What the adversary does | Caught in |
|-----|------------------------|-----------|
| `-bug=nosig` | forges honest nodes' signatures | 1 in 4 runs |
| `-bug=distinct` | pads a chain by repeating its own signature | 1 in 100 runs |
| `-bug=relay` | relies on honest nodes not relaying | 1 in 13 runs |

## PBFT: Byzantine agreement without synchrony

**The problem.** Like Raft, PBFT replicates a log of requests. But up to f
replicas, including the primary (leader), may be Byzantine, and the network
is asynchronous.

**Why 3f+1?** A replica can only wait for n − f replies, since f may never
answer. Among those n − f replies, up to f may be lies. Two such quorums must
overlap in at least one *honest* replica: 2(n − f) − n ≥ f + 1, which gives
n ≥ 3f + 1. With n = 3f + 1, a quorum is 2f+1 replicas.

**The normal case** has three phases:
1. The primary assigns a sequence number to a request and broadcasts a
   `PrePrepare`.
2. Replicas broadcast `Prepare`. A replica that holds the PrePrepare plus 2f
   matching Prepares is *prepared*. This proves no other request can be
   prepared at that sequence number in this view.
3. Replicas broadcast `Commit`. A replica that holds 2f+1 matching Commits has
   *committed*, which guarantees the request survives view changes, and it
   executes requests in sequence order.

**View change** is how PBFT gets rid of a faulty or slow primary:
- A replica whose request doesn't execute in time broadcasts a signed
  `ViewChange` for view v+1. It carries the replica's *prepared certificates*:
  a PrePrepare plus 2f signed Prepares for each request.
- The new primary collects 2f+1 ViewChanges. For each sequence number it
  re-proposes the request from the highest-view certificate, or a null request
  if there is none.
- It broadcasts all of this as a `NewView`. Every replica re-checks every
  signature and recomputes the proposals itself, so even a Byzantine new
  primary can't slip in a different request.

In the run below (`bin/pbft scenarios -v "preserves a prepared"`), op101 is
prepared everywhere, but every Commit is lost. The view change carries the
certificate, and the new primary N1 re-proposes the same request at the same
sequence number:

```
round    N0    N1    N2    N3
          |<----|<----|<----X    Prepare(v=0, s=1, d=op101)
          X---->x---->x---->x    Commit(v=0, s=1, d=op101)  lost: N0 N1 N2 N3
          ...                          (all Commits lost; view-change timers expire)
          |<----X---->|---->|    ViewChange(v=1, prepared=[s1:op101@v0])
          |<----X     |     |    NewView(v=1, from 1 2 3, O=[s1:op101])
          |     *     |     |    N1 enters view 1 (primary N1)
          |<----|<----X---->|    Prepare(v=1, s=1, d=op101)
          |<----X---->|---->|    Commit(v=1, s=1, d=op101)
          |     #     |     |    N1 executes s1: op101
```

The adversary attacks every step of this:
- A faulty primary equivocates: it sends different requests for one sequence
  number to different replicas.
- Faulty replicas send conflicting votes and random garbage.
- They also send ViewChanges whose "certificates" carry forged Prepares from
  honest replicas.

The bugs:

| Bug | Effect | Caught in |
|-----|--------|-----------|
| `-bug=prepared` | ViewChanges drop their certificates, so prepared requests can be replaced. This shows up mostly as replicas getting stuck. | 1 in 3 runs |
| `-bug=quorum` | Quorums of 2f no longer overlap in an honest replica. | 1 in 38 runs |
| `-bug=nosig` | Forged certificates are believed. | 1 in 56 runs |
| `-bug=newview` | A Byzantine new primary's NewView is trusted without being recomputed. This needs a faulty replica as the next primary. | 1 in 1,260 runs |

---

## Comparing them

- **Crash vs. Byzantine.**
  - Paxos and Raft assume nodes fail only by stopping. That is why a simple
    majority works: any two majorities overlap.
  - The Byzantine protocols must also survive nodes that lie. They need either
    a larger overlap (PBFT's 3f+1 replicas, so quorums share an honest node)
    or synchrony plus signatures (Dolev-Strong).
- **What signatures buy.** Signatures let a node prove what someone else said.
  - PBFT's view change carries certificates the new primary can't fake.
  - Dolev-Strong's chains let it tolerate any number of faults.
  - Paxos and Raft need no signatures, because crashed nodes don't lie.
- **What synchrony buys.** Dolev-Strong always terminates in exactly f+1
  rounds. The asynchronous protocols can't promise termination at all (FLP).
  They stay safe no matter what, and make progress once timers and the
  network behave, which is what the fuzzer's stabilization phase models.
- **The same shape repeats.** Paxos's "adopt the highest accepted value",
  Raft's up-to-date voting, and PBFT's choice of the highest-view certificate
  in NewView are the same idea three times. Before a new leader acts, it must
  learn anything that might already be decided, from a quorum that overlaps
  every quorum that could have decided it.

## Things to try

```sh
./build.sh
bin/paxos scenarios -v "BUG"                    # watch Paxos break without the adopt rule
bin/raft fuzz -bug=uptodate                     # find a stale-leader counterexample, then replay its seed with -v
bin/dolevstrong scenarios -v "f = n-1"          # 3 of 4 nodes are traitors, and it still works
bin/pbft scenarios -v "two faulty primaries"    # two view changes in a row (f=2)
bin/pbft fuzz -runs=100000                      # leave it running; it should print 0 failures
```

To change a protocol, edit `<protocol>/<Name>.v3`, rebuild, and run
`bin/<protocol> fuzz`. If the checker catches what you did, the diagram of the
failing seed shows you exactly how it went wrong.
