# std/websocket: one flush per frame, and a runtime that holds connections

`std/websocket` writes a run of frames with one syscall instead of one per
frame, spells a frame straight into the stream's buffer instead of allocating
one, and the runtime underneath it stopped locking per queued task and per
submitted I/O op. `std/streamio`, `std/channels`, `std/socket`,
`std/httpserver` and the thread pool changed to support that. Measured on Bun's
echo workload — 32 clients, every message echoed back to its sender, one round
= 51,200 messages:

| | before | after | Bun 1.4.4 |
|---|---|---|---|
| echo, 1 client process | 313,275 msg/s | 277,768 | **281,306** |
| echo, 4 client processes | 675,817 | **1,078,218** | 974,504 |
| echo, 2000-byte messages | — | **147,089** | 136,070 |
| held connection, server RSS | 12.0 KB | **9.0 KB** | 1.7 KB |
| 512 connections, `MODE=max` | 275,000 msg/s | **349,928** | 380,491 |

Everything was measured on a 4-core aarch64 box, `nimony c -d:release`, Bun
1.4.4. The box is shared and drifts by ~10% between runs, so Bun and nimony are
always measured **interleaved** (Bun, nimony, Bun, nimony) and the medians of
repeated runs are reported; a 3% difference is not a result. Each table below
names its script and settings. The harness, the raw logs and the client are in
`nimony-websocket-bench`: `scripts/run-interleaved.sh`, `scripts/run-scale.sh`,
`scripts/run-conns.sh`, `scripts/bench.sh`.

## Plain echo: the per-message cost alone

`scripts/run-interleaved.sh` with `READY=0 TOTAL_CLIENTS=1`, 20 rounds per run:
51,200 messages and 51,200 deliveries per round.

| | 1 client process | 4 client processes |
|---|---|---|
| Bun | **281,306** msg/s | 974,504 msg/s |
| nimony | 277,768 (−1.3%) | **1,078,218** (+10.6%) |

2000-byte messages, one client process: **147,089** against Bun's 136,070
(+8.1%). Both per-message rows are the noisiest on this box (±10% between
sessions) and they swap places; it is the row where the client, not the
server, is the limit.

Two measurement-only rows: `TCP_NODELAY` on accept took the 4-process echo from
**676k to 1.03M** msg/s (p90 at 8 messages in flight 112 → 85 µs), and
trampolining a chain inline took it from 993k to 1.12M (+13%).

## Many connections: `MODE=max`

`scripts/run-scale.sh`, N connections each ping-ponging back to back, 8 s per
run, medians of 2 runs, 4 client processes:

| connections | Bun rate | nimony rate | ratio | Bun p50 | nimony p50 | Bun p99 | nimony p99 |
|---|---|---|---|---|---|---|---|
| 32 | 163,811 | 128,395 | 78% | 171 µs | 214 µs | 515 µs | 665 µs |
| 128 | 371,229 | 278,914 | 75% | 300 µs | 399 µs | 813 µs | 1,230 µs |
| 512 | 380,491 | 349,928 | **92%** | 1,197 µs | **820 µs** | 3,953 µs | 6,249 µs |
| 2048 | 282,010 | 241,874 | 86% | 6,793 µs | 7,332 µs | 15,482 µs | 21,973 µs |

Every connection is held (2048/2048, zero errors) by both servers; nimony spends
1.4–1.5× Bun's CPU. Its median is better at 512 connections and its tail
1.3–1.6× worse — a worker cannot poll its own lane while it runs a
continuation.

At a **fixed** offered rate (`MODE=paced`, 512 connections, one message each per
interval), where the server's capacity is never the limit:

| offered | server | delivered | p50 | p99 | CPU |
|---|---|---|---|---|---|
| 5,120 msg/s | Bun | 5,018 | 4,224 µs | **12,730 µs** | 0.09 |
| 5,120 msg/s | nimony | **5,069** | **3,596 µs** | 13,561 µs | 0.17 |
| 51,200 msg/s | Bun | 45,788 | 960 µs | 6,062 µs | 0.33 |
| 51,200 msg/s | nimony | **48,790** | **929 µs** | **4,744 µs** | 0.54 |

## Holding connections

`scripts/run-conns.sh`: 8192 connections, one echo each, then held idle. The
idle CPU is measured over 5 s once they are all up and quiet.

| server | held | server RSS per connection | idle CPU |
|---|---|---|---|
| Bun `Bun.serve` | 8192 / 8192 | **1.7 KB** | 0.002 cores |
| nimony, before this branch | 8192 / 8192 | 12.0 KB | — |
| nimony, after | 8192 / 8192 | **9.0 KB** | 0.066 cores |

Four causes, found by counting the allocator's live blocks per size class: the
DEFLATE histograms inline in every `HttpConnection` (3320 → 848 bytes once on
the heap), a 16 KB read buffer reserved per connection (1 KB now, growing only
while a peer fills it), the same eager 8 KB + 8 KB buffers in `std/socket`, and
a listen backlog of 128 that dropped 19% of an 8192-connection storm.

A 32,768-connection run stops at 28,228 held for **both** servers (the loopback
ephemeral port range, not either server), which costs nimony ~250 MB against
Bun's 1.7 KB per connection extrapolated to ~48 MB.

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
| echo, 1 client process | 299,331 msg/s | 289,572 | −3.3% |
| echo, 4 client processes | 1,031,886 | 990,672 | −4.0% |
| 512 connections, `MODE=max` | 294,988 | 293,189 | −0.6% |

Server CPU at 512 connections: 4.82 → 4.64 µs per message. All deltas are
inside the ±5–8% spread of the box. The reasons are visible in the counters:
over a full 512-connection round the deques' `shared` FIFO is never used
(`fifoOwn`/`fifoStolen` = 0) and only ~3% of batches come from another worker's
deque because `flushStaged` already hands the owner 32
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
