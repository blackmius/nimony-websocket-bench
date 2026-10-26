# Status: the runtime under `std/websocket`, and where the benchmark stands

Comment for the MR. Numbers are from `nimony-websocket-bench`
(`scripts/run-interleaved.sh`, `scripts/run-scale.sh`, `scripts/run-conns.sh`),
4-core aarch64 Linux 6.8, Bun 1.4.4, Node v24.13.0, `nimony c -d:release`.

**Method.** The box is shared and drifts by ~10% between runs, so Bun and
nimony are measured *interleaved* (Bun, nimony, Bun, nimony), 10 rounds per
configuration, 3 repetitions each, medians reported. A 3% difference is not a
result on this machine.

## Where the benchmarks stand

Chat: 32 clients, each message fanned out to all of them. One round is 51,200
publishes and 1,638,400 frame deliveries.

| | nimony | Bun | delta |
|---|---|---|---|
| deliveries/s, 1 client process | 2,431,989 (664 ms) | 2,494,737 (653 ms) | −2.5% |
| deliveries/s, 4 client processes | 8,123,777 (195 ms) | 7,612,020 (215 ms) | **+6.7%** |
| server CPU per round, 1 process | 0.183 s | 0.104 s | 1.76× |
| server CPU per round, 4 processes | 0.110 s | 0.103 s | 1.07× |

Plain echo: 51,200 messages and 51,200 deliveries per round, no fan-out.

| | nimony | Bun | delta |
|---|---|---|---|
| messages/s, 1 client process | 308,639 (163 ms) | 306,315 (163 ms) | +0.8% |
| messages/s, 4 client processes | 1,167,314 (43 ms) | 1,090,936 (47 ms) | **+7.0%** |
| messages/s, 2000-byte messages | 160,166 (319 ms) | 138,229 (366 ms) | **+15.9%** |

So four of the five rows are ahead or level, on 1.07–1.76× Bun's CPU. The one
that is behind is the chat at one client process, and it is behind *because* of
the change that put the other four ahead — see the trampoline below: that row
is client-bound, so it measures latency, and a worker that keeps unwinding a
chain delays the poll that has ~19 completions waiting.

## This round: the many-connection regime

Everything above was measured on the flood workload, where one poll carries ~19
messages. The shape a server is actually bought for is the opposite: thousands
of connections, one message in flight each, so one completion per poll. The
same code cost **5.7 µs of CPU per message there against 1.1 µs in the flood**,
and a callgrind profile of that regime named two things.

* **`submit` was 24% of the instructions — 16 calls per message.** Every step of
  a `.passive` chain (an echo is eight frames deep) was pushed to the
  work-stealing deque and popped again: two atomics, a division and a call per
  frame. `drainOnce` now runs a chain's next steps inline (`trampolineSteps`,
  64) and **stops as soon as the backend reports a completion already published
  and not yet consumed** (`gReactorHasReady` → one atomic load of the ring's
  shared tail). That gate is the whole difference from the attempt that was
  rejected earlier in the MR: without it the worker keeps unwinding while
  completions sit in the ring, which is pure latency.
* **The slot arena keyed its per-fd lists by a `Table[cint, nil Slot]`** — one
  hash, one insert and one backshifting delete *per operation*; `del` alone was
  14.6% of the instructions. A descriptor is a small dense integer, so the heads
  are a `seq[nil Slot]` indexed by `fd + 1` (the `+1` for `opTimeout`/`opNop`,
  which have no descriptor: `fd = -1`, which a table accepted and an array does
  not).

Medians of three alternating pairs, before → after this round:

| | before | after | |
|---|---|---|---|
| 512 connections, ping-pong | 275k msg/s | **303k** | **+10%**, CPU 1.62 → 1.44 |
| echo, 4 client processes | 993k | **1.12M** | **+13%** |
| chat, 4 client processes | 6.83M | 7.08M | +3.7% |
| chat, 1 client process | 2.27M | 2.24M | −1.5% (inside its spread) |
| echo, 1 client process | 314k | 294k | **−6%** |

Two other ideas were measured and rejected in that regime: spinning in the poll
loop instead of blocking (rate and CPU identical — the wakeup was never the
cost) and submitting the write without parking on it (neutral).

## What a connection costs

A connection count is a memory question before it is a throughput one, so it
was measured directly: 8192 connections, one echo each, then held idle.

| server | held | server RSS per connection | idle CPU |
|---|---|---|---|
| Bun `Bun.serve` | 8192 / 8192 | **1.7 KB** | 0.04 cores |
| nimony, before this round | 8192 / 8192 | 12.0 KB | 0.05 cores |
| nimony, after | 8192 / 8192 | **9.0 KB** | 0.06 cores |

Four separate causes, found by counting the allocator's live blocks per size
class (`-d:allocStats`) rather than by guessing:

1. **A 2.5 KB DEFLATE histogram in every connection.** `Deflater` kept its
   symbol frequencies inline (`array[286, int]` + `array[30, int]`) and
   `Encoder` is a field of `HttpConnection`, so every connection carried the
   compressor's working set for a feature that is off by default.
   `sizeof(HttpConnection)` was **3320 bytes**; the histograms are on the heap
   now, allocated once per compressing stream, and it is **824**.
2. **A 16 KB read buffer per connection.** `readFd` reserved `ChunkSize` of
   spare room before every read and the reservation is what the buffer keeps —
   8000 quiet clients held 8000 sixteen-kilobyte buffers to receive forty bytes,
   and the allocator rounded each to **36 KB**. The step now starts at 1 KB and
   doubles only while a read comes back full (up to 16 KB), so a quiet
   connection holds 1 KB and a flooding one is at 16 KB reads within five reads.
3. **The same disease in `std/socket`**: `initSocket` allocated an 8 KB read and
   an 8 KB write buffer eagerly. Both are lazy now — that is what took the
   *driver* from 30 KB to 14 KB per connection, and without it the sweep cannot
   go past a few thousand.
4. **A listen backlog of 128.** `listenHttp`'s default, so a client opening 8192
   connections at once overflowed it and **19% were lost to dropped SYNs** — a
   server that looks like it cannot accept a storm. At 4096 the same run lost
   none; the default is 1024 now (nginx and Node use 511).

What is left: a connection that only accepts and parks costs 4.6 KB, so about
half of the upgraded idle connection is the `WebSocket` object, the parked echo
chain and the writer's outbox.

**A million connections is not testable here**, and the arithmetic says why: at
9.0 KB each it needs ~9 GB of server memory (Bun: ~1.7 GB) and the box has
1.7 GB free. It also needs ~1M ephemeral ports, and the loopback range is
28,231 — which is exactly where the sweep stops: 32,768 asked, **28,228 held,
both servers, the same number**, because the driver ran out of ports before
either server ran out of anything.

## Scalability: how many connections, at what rate

`scripts/run-scale.sh` holds N connections open and has each of them ping-pong
back to back, so the row is "this many clients, at this rate, with this RTT"
(8 s per run, medians of 2 runs, 4 client processes):

| connections | Bun rate | nimony rate | ratio | Bun p50 | nimony p50 | Bun p99 | nimony p99 |
|---|---|---|---|---|---|---|---|
| 32 | 181,109 | 135,185 | 75% | 159 µs | 209 µs | 467 µs | 597 µs |
| 128 | 339,214 | 261,291 | 77% | 303 µs | 415 µs | 1,356 µs | 1,725 µs |
| 512 | 381,880 | 310,369 | 81% | 1,155 µs | **985 µs** | 4,356 µs | 6,767 µs |
| 2048 | 309,344 | 240,852 | 78% | 6,338 µs | 7,310 µs | 12,757 µs | 22,115 µs |

Every connection is held by both (2048/2048, zero errors). nimony's median RTT
is better at 512 connections, its tail is ~1.6× worse, and it spends 1.4–1.7×
the CPU (was 1.6–1.9×).

At a **fixed** offered rate, with the server's capacity never the limit
(512 connections, one message each per interval):

| offered | server | delivered | p50 | p99 | CPU |
|---|---|---|---|---|---|
| 5,120 msg/s | Bun | 5,063 | 3,843 µs | 13,009 µs | 0.08 |
| 5,120 msg/s | nimony | **5,069** | **3,160 µs** | **9,994 µs** | 0.16 |
| 51,200 msg/s | Bun | 46,435 | 1,038 µs | 5,390 µs | 0.32 |
| 51,200 msg/s | nimony | **48,953** | **816 µs** | **4,042 µs** | 0.51 |

That is the trade the thread pool makes, and at a fixed load it now wins on
delivery, median and tail at 1.6× the CPU of a single-threaded server that is
one thread away from its ceiling.

## What is left

* **The tail** in the `max` rows. A worker cannot poll its own lane while it
  runs a continuation, so a long chain delays every completion on that lane.
  That is also why the trampoline needs the gate, and why a larger
  `trampolineSteps` is not automatically better.
* **The other half of the 9 KB.** Reuse the per-connection objects from a
  per-lane pool (they are allocated and freed in the same lane), shrink the
  frames (the echo frame holds a whole `WebSocket` by value), and the
  allocator's page granularity — a 2 KB chunk still touches a 4 KB page.
* **Allocation** is still ~13% of the echo's CPU (~6 coroutine frames per
  message, one per nested `.passive` call). A per-thread frame cache was tried
  and measured *worse* — chains migrate between workers, so freed frames pile
  up in the wrong thread's cache.
