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
| deliveries/s, 1 client process | 2,538,241 (647 ms) | 2,536,238 (641 ms) | +0.1% |
| deliveries/s, 4 client processes | 7,995,201 (204 ms) | 8,117,359 (199 ms) | −1.5% |
| server CPU per round, 1 process | 0.195 s | 0.101 s | 1.9× |
| server CPU per round, 4 processes | 0.126 s | 0.089 s | 1.4× |

Plain echo: 51,200 messages and 51,200 deliveries per round, no fan-out.

| | nimony | Bun | delta |
|---|---|---|---|
| messages/s, 1 client process | 313,275 (162 ms) | 311,316 (162 ms) | +0.6% |
| messages/s, 4 client processes | 675,817 (76 ms) | 1,186,888 (46 ms) | −43% |
| messages/s, 2000-byte messages | 169,192 (299 ms) | 151,022 (335 ms) | **+12%** |

Start of this round, for comparison: chat 4×8 was 7.40 M, echo 1×32 297 k,
echo 4×8 603–637 k. So the chat is at parity, the echo at one client process is
at parity, the echo with big messages is ahead, and the echo at four client
processes is the one still behind.

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

## The four-process echo: what it is, and what it is not

It is **not capacity**. Give the same server more connections and it matches
Bun:

| echo configuration | nimony | Bun |
|---|---|---|
| 4 client procs × 8 connections | 675,817 | 1,186,888 |
| 4 client procs × 32 connections | 980,222 / 1,016,940 | 1,146,013 / 1,026,996 |
| 2 client procs × 32 connections | 592,951 / 579,295 | 596,039 / 610,383 |

At 128 connections nimony reaches 88–99% of Bun; at 32 it reaches 57%. So what
the 4×8 row measures is **per-message latency at low concurrency**, not
throughput: nimony needs ~4× the in-flight messages to saturate.

It is **not CPU** either. Per-thread accounting (the harness sums the threads)
shows the three workers balanced — 0.22 s / 0.22 s / 0.19 s over a ten-round
run — and each one busy only ~28% of a 76 ms round.

It is **not syscalls**. `strace -c` over the same workload: nimony 2,729
`io_uring_enter` per round against Bun's 3,070 (`recvfrom` + `sendto` +
`epoll_pwait2`). And it is not the client: the four Node processes spend 2.64 s
against nimony and 2.38 s against Bun for the same work.

Measured latency, one connection, strict ping-pong (`hrtime`, 4000 samples):

| | 1 in flight | 8 in flight |
|---|---|---|
| nimony | p50 48.4 µs, mean 52 µs | p50 46.2 µs, mean 145 µs |
| Bun | p50 45.4 µs, mean 49.5 µs | p50 41.8 µs, mean 55 µs |

At one message in flight the two are the same. Under pipelining nimony's mean
triples while Bun's does not: its per-message latency does not fall with
concurrency, so throughput stays `in-flight / 47 µs` while Bun's becomes
`in-flight / 27 µs`.

Three things were tried against this and rejected on measurement:

* **Do not park on the write.** `writeFd` copied the bytes and submitted the
  write fire-and-forget (throwaway patch, buffer ownership not addressed):
  647–670 k, no change.
* **Bigger read bursts.** `ChunkSize` 4 KB / 16 KB / 64 KB: 627–654 k, no
  change.
* **Never sleep in the kernel.** Forcing the reactor to busy-poll instead of
  `submitAndWait` made it *worse* — 415 k — because three spinning workers take
  the cores the four client processes need. The server has idle CPU, but that
  CPU is not free.

What is left is the chain itself: a message costs a read completion, a pool
dispatch of the resumed continuation, the parse/append, and a write op — and at
32 connections there is not enough in flight to hide that. Bun's single-thread
loop does the same work in one wakeup with no cross-thread dispatch. The
promising directions are therefore fewer pool hops per completion (run the
resumed step in `deliver` instead of re-queueing it — worth re-measuring now
that the queues are lock-free) and fewer continuations per message (the echo
path takes ~20), not more threads or more CPU.

Two smaller items: allocation is now the largest single block of the echo's CPU
(13%, ~6 allocations per message), and a chain still takes ~20 queue round
trips per message, which is what the trampoline above was trying to fix.
