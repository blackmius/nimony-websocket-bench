# Status: the runtime under `std/websocket`, and where the benchmark stands

Comment for the MR. Numbers are from `nimony-websocket-bench`
(`scripts/run-interleaved.sh`), 4-core aarch64 Linux 6.8, Bun 1.4.4,
Node v24.13.0, `nimony c -d:release`.

**Method.** The box is shared and drifts by ~10% between runs, so Bun and
nimony are measured *interleaved* (Bun, nimony, Bun, nimony), 10 rounds per
configuration, 3 repetitions each, medians reported. A 3% difference is not a
result on this machine.

## Where the benchmarks stand

Chat: 32 clients, each message fanned out to all of them. One round is 51,200
publishes and 1,638,400 frame deliveries.

| | nimony | Bun | delta |
|---|---|---|---|
| deliveries/s, 1 client process | 2,466,097 (658 ms) | 2,407,612 (678 ms) | +2.4% |
| deliveries/s, 4 client processes | 7,457,286 (215 ms) | 7,331,348 (218 ms) | +1.7% |
| server CPU per round, 1 process | 0.198 s | 0.108 s | 1.8× |
| server CPU per round, 4 processes | 0.144 s | 0.105 s | 1.4× |

Plain echo: 51,200 messages and 51,200 deliveries per round, no fan-out.

| | nimony | Bun | delta |
|---|---|---|---|
| messages/s, 1 client process | 297,445 (170 ms) | 251,697 (203 ms) | **+18.2%** |
| messages/s, 4 client processes | 1,026,582 (53 ms) | 1,038,679 (51 ms) | −1.2% |
| messages/s, 2000-byte messages | 147,904 (344 ms) | 133,921 (381 ms) | **+10.4%** |

Start of this round, for comparison: chat 4×8 was 7.40 M, echo 1×32 297 k,
echo 4×8 603–637 k. So the chat and the echo are both at parity or ahead now,
and the one row that was 43% behind is fixed — see the Nagle section below.

## What this round changed

The profile said the cost was the pool, not the socket path: `submit` alone was
17% of the echo server's CPU and the two stripe mutexes 12%. Both of the
runtime's queues took a `SysLock` per operation.

* **The op queue** (`lib/std/ioring/core/backend.nim`). A lane's deferred ops
  have exactly one consumer — that lane's own `poll` — and, for a worker, one
  producer: the same thread, because a worker submits its ops from the
  continuations it runs. So the owner side is a plain `LocalRing`: no lock, no
  atomics. The locked `FifoStripe` is kept only for the two genuinely
  multi-producer cases (the trailing lane shared by every non-worker thread,
  and iocp's routing of a socket's op to its owning lane).
* **The task queue** (`lib/std/threadpool.nim`). `localQueues` is now a set of
  Chase-Lev work-stealing deques: the owner pushes at `bottom` (its only
  writer), and the owner and thieves alike take from `top` with one
  compare-exchange per batch, so `BulkSize` tasks cost one atomic operation.
* **`deliver`** submits a resumed chain without an `fd` hint, so it stays on
  the lane that polled the completion instead of being pushed into a foreign
  stripe (which is the locked half of the queue).
* **Counters** moved behind `-d:threadpoolMetrics`; without it `countMetric`
  compiles to nothing and `workerMetrics` is never allocated.
* **`TCP_NODELAY` on accept** (`httpserver.accept` → `setNoDelay`, one ring op
  per connection). This is the one that fixed the echo; see below.

Instructions per echoed message (callgrind, same workload):

| | Ir per message |
|---|---|
| locked op queue, locked stripes | 6,497 |
| `LocalRing` op queue | 4,082 |
| + work-stealing deques | 3,736 |

**−42% instructions per message**, and the mutexes are gone from the profile
entirely. What is left is the scheduler itself: `submit` 21% (it is still
called ~20 times per message), `iouringPoll` 7%, `tryBulkPop` 7%, allocation
13%, `workCycle` 6%, `expireDeadlines` 3%, frame codec ~3%.

## Tried and reverted: trampolining a chain inline

`drainOnce` re-submits a continuation that yields more work, so the next step of
a chain goes back through the queue — ~20 submits per echoed message. Running
the chain inline until it parks (bounded at 64 steps) cuts that to ~0.3 submits
per message and 12% of the CPU… and costs 13% of the echo's throughput
(309 k → 269 k at one client process), because a worker cannot poll its own
io_uring lane while it runs: every deferred poll is deferred latency. The chat
is neutral. Reverted, with the numbers recorded so the next attempt starts from
them.

## The four-process echo: it was Nagle

The one row that was behind has nothing to do with any of the above. The
library never set `TCP_NODELAY`, so the kernel could hold a small write until
the previous one had been acknowledged: for a server that answers in small
messages, one extra round trip per reply. It is invisible in CPU (the server was
idle a third of the round either way) and invisible in the syscall counts — it
shows up only as a latency that does not fall with concurrency, which is exactly
what the measurements said:

| | before | after `setNoDelay` |
|---|---|---|
| echo, 4 client processes | 675,817 | **1,026,582** |
| echo, 1 client process | 313,275 | 297,445 |
| RTT, 8 messages in flight, mean | 145 µs | 52 µs |
| RTT, 8 in flight, p90 | 112 µs | 85 µs |

`httpserver.accept` now calls `setNoDelay` (one ring op per connection), and the
whole benchmark set is at parity or ahead: chat +2.4% at one client process and
+1.7% at four, echo +18% at one and −1.2% at four, echo with 2000-byte messages
+10%.

Before finding it, four other explanations were measured and rejected: not
parking on the write (647–670k, no change), bigger read chunks (627–654k, no
change), busy-polling instead of sleeping (415k, worse — the workers take the
clients' cores), and running a chain's steps inline (−12% CPU, −13% throughput,
because a worker cannot poll its own io_uring lane while it runs).

## Scalability: how many connections

`scripts/run-scale.sh` holds N connections open and has each of them ping-pong
back to back, so the row is "this many clients, at this rate, with this RTT":

| connections | Bun rate | nimony rate | ratio | Bun p99 | nimony p99 |
|---|---|---|---|---|---|
| 32 | 170,303 | 137,394 | 81% | 480 µs | 638 µs |
| 128 | 357,543 | 260,586 | 73% | 960 µs | 2,500 µs |
| 512 | 400,202 | 287,716 | 71% | 4,307 µs | 7,015 µs |
| 2048 | 315,491 | 208,598 | 66% | 14,524 µs | 22,768 µs |

Every connection is held by both (2048/2048, zero errors). nimony's median RTT
is comparable — better at 512 (968 µs against 1,081 µs) — its tail is ~1.6×
worse, and it spends 1.6–1.8× the CPU.

At a **fixed** offered rate, with the server's capacity never the limit, the
picture is the one the thread pool is for: 512 connections at 51,200 msg/s
offered, both at ~48k delivered, median 763 µs (nimony) against 784 µs (Bun),
p99 **3.2 ms against 4.4 ms** — and nimony at 0.56 cores against Bun's 0.27.

The gap in the `max` rows is syscall batching: one `epoll_wait` collects every
ready socket and one `sendto` carries ~32 replies, while the ring does ~3
`io_uring_enter` per burst of ~19 messages. That is the next thing to attack
(`IORING_OP_RECV_MULTISHOT`, and submitting a burst's writes without waiting for
each).

## What is left

* Syscall batching for the many-connection case, as above.
* The tail: a worker cannot poll its own lane while it runs a continuation, so
  a long chain delays every completion on that lane.
* Allocation is still ~13% of the echo's CPU (~6 coroutine frames per message,
  one per nested `.passive` call). A per-thread frame cache was tried and
  measured *worse* — chains migrate between workers, so freed frames pile up in
  the wrong thread's cache.
