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
| deliveries/s, 1 client process | 2,471,337 (664 ms) | 2,530,469 (638 ms) | −2.3% |
| deliveries/s, 4 client processes | 7,976,888 (200 ms) | 7,670,167 (215 ms) | **+4.0%** |
| server CPU per round, 1 process | 0.179 s | 0.100 s | 1.79× |
| server CPU per round, 4 processes | 0.100 s | 0.106 s | 0.94× |

Plain echo: 51,200 messages and 51,200 deliveries per round, no fan-out.

| | nimony | Bun | delta |
|---|---|---|---|
| messages/s, 1 client process | 307,849 (163 ms) | 294,511 (172 ms) | **+4.5%** |
| messages/s, 4 client processes | 1,011,558 (52 ms) | 1,096,155 (48 ms) | −7.7% |
| messages/s, 2000-byte messages | 152,563 (326 ms) | 144,004 (347 ms) | **+5.9%** |

The echo at four client processes is the noisiest row on this box: over 5
interleaved pairs taken on their own it reads 1,077,431 against Bun's 1,021,132
(**+5.5%**), and every run of the day has put it between −8% and +15% while Bun
stays within ±5%. The chat at one client process is behind *because* of the
change that put the other rows ahead — see the trampoline below: that row is
client-bound, so it measures latency, and a worker that keeps unwinding a chain
delays the poll that has ~19 completions waiting.

## This round: the read buffer

The previous round brought a held connection from 12.0 KB to 9.0 KB, and the
largest single piece left was the buffer a connection reserves *before* it
reads, so the kernel has somewhere to put the bytes: **2080 bytes of a 5888-byte
connection**. A connection waiting for its peer has nothing to receive, and it
held that buffer anyway, for as long as it was quiet.

A provided-buffer ring turns that around. Each io_uring lane registers a ring of
buffers; a read is submitted with `IOSQE_BUFFER_SELECT`, the kernel takes a
buffer **when there is something to put in it**, and the completion names the
buffer it filled. A parked read therefore holds nothing, and a record that
arrives whole is parsed straight out of the pool buffer — the reader copies it
once into the caller's `msg`, exactly as before, and allocates no buffer of its
own.

* a record that does not fit in one pool buffer is continued in the reader's own
  buffer: the only case where a connection pays for one, released as soon as the
  record is consumed;
* a peer that keeps filling a pool buffer grows the reader's `step` past it and
  the connection reads into a buffer of its own, where the big reads belong;
* `Reader` grew a 16-byte `Chunk` and `peek`/`consume`/`buffered` learned to hand
  out bytes that belong to the pool. Nothing above `Reader` changed.

| | before this round | after |
|---|---|---|
| 8192 connections held, RSS per connection | 9.0 KB | **5.0 KB** |
| 28,228 connections held (the port limit) | 260 MB | **126 MB** |
| `sizeof(HttpConnection)` | 824 B | 848 B |
| read buffer per parked connection | 2080 B | **0** |

Found in the same measurement and not about connections at all: a string that
becomes long doubled its *first* heap block (`transitionToLong` used the
geometric-growth helper on a string that had nothing to grow from). A 1 KB
reservation cost 2 KB, a 16 KB read buffer 36 KB — on every string in the
program that ever became long. It is now the size that was asked for;
`allocatedSize` of a 1 KB reservation went 2080 → 1056.

The honest cost: a pooled read is ~4% slower on the 2000-byte echo, at 4% *less*
CPU — a longer round with less work in it, so it is per read and not per byte.
It is not the buffer size (16 KB pool buffers are no better there and 6% worse
on 40-byte messages) and not the copy count. `-d:noPoolRead` turns the pool off
for anyone who would rather have the 4%.

`IORING_OP_RECV_MULTISHOT` is the obvious companion and is deliberately not in
this change: a multishot request is armed on one ring and its completions land
on the lane that owns it for as long as it stays armed, while a chain here can
be stolen by another worker between two reads. A second recv armed from the new
lane would race the first for the same stream, and two concurrent `recv`s on one
socket deliver bytes in whatever order the kernel picked. It needs a connection
pinned to a lane for its whole life — a change to the pool's load balancing, and
it would buy the SQE fill per read, which is the smaller half.

## What a connection costs

A connection count is a memory question before it is a throughput one, so it
was measured directly: 8192 connections, one echo each, then held idle.

| server | held | server RSS per connection | idle CPU |
|---|---|---|---|
| Bun `Bun.serve` | 8192 / 8192 | **1.7 KB** | 0.04 cores |
| nimony, before this MR | 8192 / 8192 | 12.0 KB | 0.05 cores |
| nimony, before this round | 8192 / 8192 | 9.0 KB | 0.06 cores |
| nimony, after | 8192 / 8192 | **5.0 KB** | 0.06 cores |

What is left, per connection: 1152 bytes of parked echo chain (848 of them the
`HttpConnection`), ~1.5 KB of continuation frames (25 small blocks: the frames
of the nested `.passive` calls an echo parks in), and ~1.1 KB of `WebSocket`
state and writer outbox.

**A million connections is not testable here**, and the arithmetic says why: at
4.6 KB each it needs ~4.6 GB of server memory (Bun: ~1.7 GB) and the box has
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
| 32 | 176,866 | 139,962 | 79% | 164 µs | 205 µs | 491 µs | 568 µs |
| 128 | 368,292 | 277,612 | 75% | 302 µs | 393 µs | 956 µs | 1,484 µs |
| 512 | 397,547 | 319,694 | 80% | 1,083 µs | **922 µs** | 4,212 µs | 6,576 µs |
| 2048 | 309,966 | 236,440 | 76% | 6,261 µs | 7,553 µs | 14,592 µs | 22,793 µs |

Every connection is held by both (2048/2048, zero errors). nimony's median RTT
is better at 512 connections, its tail is ~1.6× worse, and it spends 1.5–1.7×
the CPU.

At a **fixed** offered rate, with the server's capacity never the limit
(512 connections, one message each per interval):

| offered | server | delivered | p50 | p99 | CPU |
|---|---|---|---|---|---|
| 5,120 msg/s | Bun | 5,050 | 3,690 µs | 13,467 µs | 0.07 |
| 5,120 msg/s | nimony | **5,069** | **2,275 µs** | **10,528 µs** | 0.13 |
| 51,200 msg/s | Bun | 46,929 | 861 µs | 5,461 µs | 0.30 |
| 51,200 msg/s | nimony | **48,639** | **834 µs** | **3,763 µs** | 0.49 |

That is the trade the thread pool makes, and at a fixed load it wins on
delivery, median and tail at 1.6× the CPU of a single-threaded server that is
one thread away from its ceiling.

## What is left

* **The tail** in the `max` rows. A worker cannot poll its own lane while it
  runs a continuation, so a long chain delays every completion on that lane.
  That is also why the trampoline needs the `gReactorHasReady` gate, and why a
  larger `trampolineSteps` is not automatically better.
* **The other 5 KB.** Reuse the per-connection objects from a per-lane pool
  (they are allocated and freed in the same lane), shrink the frames (the echo
  frame holds a whole `WebSocket` by value), and the allocator's page
  granularity — a 2 KB chunk still touches a 4 KB page.
* **The 4% a pooled read costs** on the 2000-byte echo: somewhere between the
  SQE's buffer selection and the completion that names the buffer. Worth a look
  from someone with kernel tracing; the pool is a define away from being off.
* **Allocation** is still ~13% of the echo's CPU (~6 coroutine frames per
  message, one per nested `.passive` call). A per-thread frame cache was tried
  and measured *worse* — chains migrate between workers, so freed frames pile
  up in the wrong thread's cache.
