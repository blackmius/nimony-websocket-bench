# std/websocket: fan-out, a cheaper write path, and a runtime that holds connections

`std/websocket` can now fan a message out to every subscriber (`Room`), writes
a run of frames with one syscall instead of one per frame, and encodes a frame
without allocating. `std/streamio`, `std/channels`, `std/socket`,
`std/httpserver` and the thread pool changed to support that. Measured on Bun's
`bench/websocket-server` workload — 32 clients, every message echoed to all 32,
one round = 51,200 publishes and 1,638,400 deliveries:

| | before | after | Bun 1.4.4 |
|---|---|---|---|
| chat, 1 client process | 927,248 deliveries/s | **2,471,337** | 2,530,469 |
| chat, 4 client processes | 824,417 | **7,976,888** | 7,670,167 |
| chat, server CPU per round (1 process) | 4.75 s | **0.179 s** | 0.100 s |
| chat, `io_uring_enter` per round | 1,478,997 | **3,558** | 49,765 `sendto` |
| echo, 1 client process | 313,275 msg/s | **307,849** | 294,511 |
| echo, 4 client processes | 675,817 | **1,011,558** | 1,096,155 |
| echo, 2000-byte messages | — | **152,563** | 144,004 |
| held connection, server RSS | 12.0 KB | **9.1 KB** | 1.7 KB |
| 512 connections, `MODE=max` | 275,000 msg/s | **319,694** | 397,547 |

Everything was measured on a 4-core aarch64 box (6.8), `nimony c -d:release`,
Bun 1.4.4. The box is shared and drifts by ~10% between runs, so Bun and nimony
are always measured **interleaved** (Bun, nimony, Bun, nimony) and the medians
of repeated runs are reported; a 3% difference is not a result. Each table below
names its script and settings. The harness, the raw logs and the client are in
`nimony-websocket-bench`: `scripts/run-all.sh`, `scripts/run-interleaved.sh`,
`scripts/run-scale.sh`, `scripts/run-conns.sh`, `scripts/bench.sh`.

## Chat: the fan-out workload

`scripts/run-interleaved.sh`, 10 rounds per configuration, medians of 3
repetitions, one round = 51,200 publishes / 1,638,400 frame deliveries:

| deliveries/s | before | after | Bun |
|---|---|---|---|
| 1 client process | 927,248 | **2,471,337** −2.3% vs Bun | 2,530,469 |
| 4 client processes | 824,417 | **7,976,888** +4.0% vs Bun | 7,670,167 |

Server CPU per round: 4.75 s before, 0.179 s after, Bun 0.100 s at one client
process; 0.100 s after, Bun 0.106 s at four — less CPU than Bun at four.

The same round, one `Room` against the writer-chain-per-connection server the
pair API used to force (`src/chatserver.nim` vs `src/chatserver-conn.nim`):

| | writer per connection | `Room` |
|---|---|---|
| deliveries/s, 1 client process | 2,324,477 | **2,691,446** |
| deliveries/s, 4 client processes | 2,561,422 | **6,943,658** |
| server CPU per round | 1.22 s | **0.14 s** |
| `io_uring_enter` per round | 45,595 | **3,558** |

Where the 2.7× came from, in the order it was measured (1 client process, one
change at a time, `results/`):

| step | deliveries/s | server CPU per round |
|---|---|---|
| baseline | 927,248 | 4.75 s |
| `sendFrame` flushes once, not twice | 1.22 M | 3.55 s |
| `send(flush = false)` + non-parking `tryRecv` drain | 2.38 M | 1.74 s |
| the frame is spelled in place — no allocation | 2.48 M | 1.40 s |
| `Room`: one chain owns every writer | 2.09 M | 0.28 s |
| topic tree instead of a member scan | 2.64 M | 0.12–0.17 s |
| topic cache + one UTF-8 check per publish | 2.67 M | 0.12 s |
| the fan-out frame encoded once per publish | **2.69 M** | 0.15 s |

The room's round time fell from 790 ms to 611 ms at one client process and from
458 ms to 254 ms at four; the flat topic list did 1.6 M string compares per
round (~120 ns each) and was the largest single win *with a single topic*.

## Plain echo: the per-message cost alone

`scripts/run-interleaved.sh` with `READY=0 TOTAL_CLIENTS=1`, 20 rounds per run:
51,200 messages and 51,200 deliveries per round.

| | 1 client process | 4 client processes | server CPU per message |
|---|---|---|---|
| Bun | 294,511 msg/s | 1,096,155 msg/s | 0.80 µs |
| nimony | **307,849** (+4.5%) | **1,011,558** | 1.10 µs |

2000-byte messages, one client process: **152,563** against Bun's 144,004
(+5.9%). The 4×8 echo row is the noisiest on this box (±8%); over 5 interleaved
pairs of its own it reads 1,077,431 against Bun's 1,021,132 (+5.5%).

Two measurement-only rows: `TCP_NODELAY` on accept took the 4-process echo from
**676k to 1.03M** msg/s (p90 at 8 messages in flight 112 → 85 µs), and
trampolining a chain inline took it from 993k to 1.12M (+13%).

## Many connections: `MODE=max`

`scripts/run-scale.sh`, N connections each ping-ponging back to back, 8 s per
run, medians of 2 runs, 4 client processes:

| connections | Bun rate | nimony rate | ratio | Bun p50 | nimony p50 | Bun p99 | nimony p99 |
|---|---|---|---|---|---|---|---|
| 32 | 176,866 | 139,962 | 79% | 164 µs | 205 µs | 491 µs | 568 µs |
| 128 | 368,292 | 277,612 | 75% | 302 µs | 393 µs | 956 µs | 1,484 µs |
| 512 | 397,547 | 319,694 | 80% | 1,083 µs | **922 µs** | 4,212 µs | 6,576 µs |
| 2048 | 309,966 | 236,440 | 76% | 6,261 µs | 7,553 µs | 14,592 µs | 22,793 µs |

Every connection is held (2048/2048, zero errors) by both servers; nimony spends
1.5–1.7× Bun's CPU. Its median is better at 512 connections and its tail ~1.6×
worse — a worker cannot poll its own lane while it runs a continuation.

At a **fixed** offered rate (`MODE=paced`, 512 connections, one message each per
interval), where the server's capacity is never the limit:

| offered | server | delivered | p50 | p99 | CPU |
|---|---|---|---|---|---|
| 5,120 msg/s | Bun | 5,050 | 3,690 µs | 13,467 µs | 0.07 |
| 5,120 msg/s | nimony | **5,069** | **2,275 µs** | **10,528 µs** | 0.13 |
| 51,200 msg/s | Bun | 46,929 | 861 µs | 5,461 µs | 0.30 |
| 51,200 msg/s | nimony | **48,639** | **834 µs** | **3,763 µs** | 0.49 |

## Holding connections

`scripts/run-conns.sh`: 8192 connections, one echo each, then held idle.

| server | held | server RSS per connection | idle CPU |
|---|---|---|---|
| Bun `Bun.serve` | 8192 / 8192 | **1.7 KB** | 0.04 cores |
| nimony, before this branch | 8192 / 8192 | 12.0 KB | 0.05 cores |
| nimony, after | 8192 / 8192 | **9.1 KB** | 0.06 cores |

Four causes, found by counting the allocator's live blocks per size class: the
DEFLATE histograms inline in every `HttpConnection` (3320 → 848 bytes once on
the heap), a 16 KB read buffer reserved per connection (1 KB now, growing only
while a peer fills it), the same eager 8 KB + 8 KB buffers in `std/socket`, and
a listen backlog of 128 that dropped 19% of an 8192-connection storm.

A 32,768-connection run stops at 28,228 held for **both** servers (the loopback
ephemeral port range, not either server), which costs nimony ~256 MB against
Bun's 1.7 KB per connection extrapolated to ~48 MB.

## Syscalls

`strace -c -f` on the server during one chat round (1,638,400 deliveries):

| server | calls in one round |
|---|---|
| nimony, before | **1,478,997 `io_uring_enter`** (~0.9 per frame) |
| nimony, after | **45,595** (~36 frames per call) |
| nimony, `Room` | **3,558** (~461 frames per call) |
| Bun | **49,765 `sendto`** (~33 frames per call) |

## Where wtx (Rust) sits

As a third implementation of the same two workloads, `rust/wtx-server` in
`nimony-websocket-bench` is wtx 0.52's low-level API (one tokio task per
connection). Measured in rotation with the other two (`scripts/run-rust.sh`,
medians of 3, 10 rounds per chat run, 20 per echo run):

| | Bun | nimony | wtx |
|---|---|---|---|
| chat, 1 client process | **2,488,162** | 2,403,859 | 2,247,476 |
| chat, 4 client processes | 7,968,171 | **8,112,098** | 1,767,378 |
| echo, 1 client process | 275,387 | 278,878 | **287,897** |
| echo, 4 client processes | 1,039,793 | **1,132,036** | 1,073,080 |
| echo, 2000-byte messages | 139,667 | **152,890** | 137,794 |

The echo is level — three implementations of one protocol, inside the noise at
one client process. The fan-out is not, and the syscall count says why: wtx's
`write_frame` has no queue and no `flush`, so it is one `writev` per delivered
frame, **1,638,464 per round** against the room's 3,558 `io_uring_enter` and
Bun's 49,765 `sendto`. That is 0.77 s of server CPU per round against 0.21 s
(nimony) and 0.10 s (Bun), and at four client processes it is the difference
between 1.8 M and 8.1 M deliveries/s. Batching is exactly what this branch's
write path does and what the crate's public writer does not expose.

The same holds for idle connections: 8192/8192 held at **11.8 KB** of server
RSS each and 0.06 cores, against the 9.1 KB in the table above and Bun's 1.7.

## Instructions per echoed message

callgrind on the echo server, as each step landed:

| | Ir per message |
|---|---|
| locked op queue, locked stripes | 6,497 |
| `LocalRing` op queue (no op lock) | 4,082 |
| + work-stealing task deques | 3,736 |

The task deques were afterwards **removed again** (see below) — the wall clock
did not move — so the third row is history, not the final instruction count.

## The thread pool: what was added and what was taken back out

The two queue changes are in this branch:

* a lane's deferred ops are an `OpQueue` whose owner side is a plain
  `LocalRing` — the producer and the consumer of a lane are the same thread —
  with the locked `FifoStripe` kept for the multi-producer cases (the trailing
  lane shared by every non-worker thread, and iocp's cross-lane routing);
* `drainOnce` runs a chain's next steps inline (`trampolineSteps`, 64) instead
  of re-submitting each one; on the many-connection echo that is ~16 submits
  per message → ~0.27.

Two mechanisms added for the same work were measured again and removed:

* a Chase-Lev work-stealing deque per stripe (plus a locked `shared` FIFO for
  foreign producers);
* the trampoline's "is a completion already published?" gate
  (`BackendRelays.hasReady`, one atomic load per step).

Interleaved A/B on the same tree (A = with both, B = this branch), medians of 3
runs:

| workload | A | B | B vs A |
|---|---|---|---|
| chat, 1 client process | 2,452,195 deliveries/s | 2,434,654 | −0.7% |
| chat, 4 client processes | 8,394,646 | 8,418,868 | +0.3% |
| echo, 1 client process | 299,331 msg/s | 289,572 | −3.3% |
| echo, 4 client processes | 1,031,886 | 990,672 | −4.0% |
| 512 connections, `MODE=max` | 294,988 | 293,189 | −0.6% |

Server CPU at 512 connections: 4.82 → 4.64 µs per message. All deltas are
inside the ±5–8% spread of the box. The reasons are visible in the counters:
over a full 512-connection round the deques' `shared` FIFO is never used
(`fifoOwn`/`fifoStolen` = 0) and only ~3% of batches come from another worker's
deque (0.4% in the chat), because `flushStaged` already hands the owner 32
tasks per lock. The gate's claimed ~7% on the 1-process echo does not
reproduce either (−0.9%). What is left is the same three counters and ~110
fewer lines.

## What was tried and rejected

* **Submit at the end of the cycle** (`gBeforePoll`, one write per connection
  per cycle, no `flush`, no wait): 2,356,284 vs **1,330,590** deliveries/s and
  45,595 vs 1,059,755 `io_uring_enter` per round. The wait is what makes the
  batch: a writer that never waits writes one frame per cycle.
* **Trampolining without the has-ready gate** (first attempt, before this
  branch): 309k → 269k on the 1-process echo (−13%). The second attempt, in the
  drain loop, is the one that landed (+13% at four).
