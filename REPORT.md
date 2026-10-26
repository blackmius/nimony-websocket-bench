# What improved

`std/websocket`'s write path and a new `Room` for fan-out, measured on Bun's
[`bench/websocket-server`](https://github.com/oven-sh/bun/tree/main/bench/websocket-server)
workload: 32 clients, every message echoed to all of them, one round =
51,200 publishes and 1,638,400 deliveries. 4-core aarch64, `nimony c
-d:release`, Bun 1.4.4. Reproduce with `scripts/run-interleaved.sh`: the box is
shared and drifts by ~10%, so Bun and nimony are measured alternately and the
medians of 3 repetitions are reported. A 3% difference is not a result.

The same work also made the many-connection case viable: 512 connections
ping-ponging went from 275k to 320k msg/s, and the memory a held connection
costs came down from 12.0 KB to **5.0 KB** — see "Holding connections" below.

## Headline

| | before | after | Bun 1.4.4 |
|---|---|---|---|
| deliveries/s, 1 client process | 927,248 | **2,471,337** | 2,530,469 |
| deliveries/s, 4 client processes | 824,417 | **7,976,888** | 7,670,167 |
| server CPU per round, 1 process | 4.75 s | 0.179 s | 0.100 s |
| `io_uring_enter` per round | 1,478,997 | **3,558** | 49,765 `sendto` |

2.7× more throughput at one client process and 9.7× at four, level at one
client process (−2.3%) and ahead at four (+4.0%), on ~1.8× Bun's server CPU at
one client process and *less* than Bun's at four, instead of 15×.

The runtime underneath was part of the work: the ring's op queue and the pool's
task queue both took a `SysLock` per operation. They are now a same-thread ring
(the owner is the only producer *and* the only consumer of its lane) and a set
of Chase-Lev work-stealing deques, which is **−42% instructions per echoed
message** (6,497 → 3,736, callgrind) and removes the mutexes from the profile.

## Where it came from, in order

Each step measured on its own, one client process:

| step | deliveries/s | server CPU per round |
|---|---|---|
| baseline | 927,248 | 4.75 s |
| `sendFrame` flushes once instead of twice | 1.22 M | 3.55 s |
| `send(flush = false)` + a non-parking `tryRecv` drain | 2.38 M | 1.74 s |
| the frame is spelled in place (`Writer.grow`), no allocation | 2.48 M | 1.40 s |
| `Room`: one chain owns every writer, `publish` is one channel send | 2.09 M | 0.28 s |
| topic tree instead of a member scan | 2.64 M | 0.12–0.17 s |
| topic cache + one UTF-8 check per publish (not per delivery) | 2.67 M | 0.12 s |
| the fan-out frame encoded once per publish, not once per member | **2.69 M** | **0.15 s** |

Four things were wrong, and they compounded:

1. **Two syscalls per frame.** The header and the payload were written with two
   `write` + `flush` pairs; a flush is a syscall and, on a ring, a
   submit-and-wait, so a two-byte header cost as much as the payload.
2. **One syscall per frame is still too many for a fan-out.** A published
   message becomes 32 frames, so the pair API needed a way to write a *run* of
   frames with one syscall — hence `flush = false` plus `tryRecv`, which lets a
   writer chain drain its outbox and flush once when it runs dry. The wait for
   that flush is also what lets the next batch form.
3. **Two allocations per frame.** `frameHeader` built a string per frame and a
   client's masked copy was a second one. The frame is now spelled straight
   into the writer's buffer.
4. **No fan-out at all**, so every connection needed a writer chain of its own
   and a publish cost 32 channel sends, 32 wakeups and a task per delivery.
   `Room` owns the writers and does the fan-out in one chain: one channel send
   per publish, one buffer append per member, one flush per member per turn.

The topic tree is not only a scaling argument. Topics are paths
(`"chat/room1"`) and a publish reaches the subtree below it, but the win here
came with a *single* topic: the flat version compared the published topic
against every member's topic string on every delivery — 1.6 M string compares
per round, ~120 ns each — and the tree compares an integer. Round time fell
from 790 ms to 611 ms at one client process and from 458 ms to 254 ms at four.

## Plain echo (no fan-out)

Same client, a server that only echoes: 51,200 messages and 51,200 deliveries
per round.

| | 1 client process | 4 client processes | server CPU per message |
|---|---|---|---|
| Bun | 294,511 msg/s | 1,096,155 msg/s | 0.80 µs |
| nimony | **307,849 msg/s** | **1,011,558 msg/s** | 1.10 µs |

Level at one client process (+4.5%), level at four on the medians of the longer
run of that row (+5.5% over 5 interleaved pairs; the 4×8 echo is the noisiest
row on this box, ±8%), on 1.1–1.3× Bun's CPU per message (it was 2.6×). With
2000-byte messages (per-message cost spread over 133× more bytes) nimony is
ahead too: 152,563 against 144,004 msg/s (+5.9%).

**The four-process row was 57% of Bun until `TCP_NODELAY` was set on accept.**
The kernel was holding each small write until the previous one was
acknowledged, so every reply cost an extra round trip — invisible in CPU and in
syscall counts, visible only as a latency that did not fall with concurrency.
One ring op per connection fixed it: 676k → 1.03M messages/s.

**Trampolining a chain inline** (running a continuation's next steps on the
same worker instead of re-queueing them) was tried here first and cost 13% of
this benchmark: a worker cannot poll its own io_uring lane while it runs, so
every deferred poll is deferred latency. It came back in this round with the one
thing it was missing — the loop stops as soon as the backend reports a published
completion — and it is now +13% on this row and +10% at 512 connections. It
still costs the *one*-client-process echo ~6%, which is client-bound.

## Holding connections

`scripts/run-conns.sh`: 8192 connections, one echo each, then held idle.

| server | server RSS per connection | idle CPU |
|---|---|---|
| Bun `Bun.serve` | **1.7 KB** | 0.04 cores |
| nimony, before this MR | 12.0 KB | 0.05 cores |
| nimony, before the pool | 9.0 KB | 0.06 cores |
| nimony, after | **5.0 KB** | 0.06 cores |

Five causes, found by counting the allocator's live blocks per size class:

* a 2.5 KB DEFLATE histogram inline in every `HttpConnection` (3320 → 848 bytes
  once the histograms moved to the heap);
* a 16 KB read buffer reserved per connection and rounded to a 36 KB chunk by
  the allocator (1 KB now, doubling to 16 KB only while a peer fills it);
* the same eager 8 KB + 8 KB buffers in `std/socket`;
* a listen backlog default of 128, which lost 19% of an 8192-connection storm to
  dropped SYNs;
* and then, the largest single piece: **the buffer a connection reserves before
  it reads**. A provided-buffer ring per lane (`IOSQE_BUFFER_SELECT`) means the
  kernel takes a buffer *when there is something to put in it*, so a parked
  connection holds none, and a record that arrives whole is parsed out of the
  pool buffer. What is left of a connection's own buffer is the case where a
  record spans reads.

A million connections would need ~4.6 GB of server memory (Bun: 1.7 GB); this
box has 1.7 GB free, and its loopback port range (28,231 ports) stops the sweep
at 28,228 connections held — the same number for both servers, and now in
126 MB instead of 260.

## Many connections

`scripts/run-scale.sh`: N connections, each ping-ponging back to back, 8 s,
medians of 2 runs, 4 client processes.

| connections | Bun rate | nimony rate | ratio | Bun p99 | nimony p99 |
|---|---|---|---|---|---|
| 32 | 176,866 | 139,962 | 79% | 491 µs | 568 µs |
| 128 | 368,292 | 277,612 | 75% | 956 µs | 1,484 µs |
| 512 | 397,547 | 319,694 | 80% | 4,212 µs | 6,576 µs |
| 2048 | 309,966 | 236,440 | 76% | 14,592 µs | 22,793 µs |

Every connection is held (2048/2048, no errors) by both. nimony's median
latency is better at 512 connections (922 µs against 1,083 µs), its tail is
~1.6× worse, and it spends 1.5–1.7× Bun's CPU. At a *fixed* offered rate nimony
delivers more, at a lower median and a lower tail (834 µs / 3.8 ms against
861 µs / 5.5 ms at 51,200 msg/s offered) — that is the thread pool's trade:
1.6× the CPU of a single-threaded server that is one thread away from its
ceiling.

What is left of Bun's advantage in the `max` rows is syscall batching: one
`epoll_wait` collects every ready socket, one `sendto` carries ~32 replies, while
the ring does ~3 `io_uring_enter` per burst of ~19 messages.

## What is left

* What is left of the 5 KB per connection: 1152 bytes of parked echo chain (848
  of them the `HttpConnection`), ~1.5 KB of continuation frames and ~1.1 KB of
  `WebSocket` state and writer outbox. Reusing the per-connection objects from a
  per-lane pool, shrinking the frames (the echo frame holds a `WebSocket` by
  value), and the allocator's page granularity are the next three.
* A pooled read costs ~4% on the 2000-byte echo (fewer, bigger reads, 4% less
  CPU, a longer round). It is not the buffer size and not the copy count;
  `-d:noPoolRead` switches the pool off for anyone who would rather have the
  4%.
* The p99 in the `max` rows: a worker cannot poll its own lane while it runs a
  continuation, so a long chain delays every completion on that lane.
* A turn flushes its members one after another, and each flush waits for its
  own write. Overlapping those waits needs "submit without waiting" plus "wait
  for the drain"; the deferred-submit variant alone measured *worse*
  (1.33 M, 1.06 M syscalls) because the wait is what creates the batch.
* The per-message cost is ~2 µs and now dominates the server's CPU: one channel
  send, one event construction and one frame append per member. Batching the
  reader's lines into one event would cut the first two, and it needs a
  non-parking check on the reader (`buffered`) to know a batch is there.
* The channel hop per message: one ticket-lock round trip and a 24-byte copy.
* `publish` walks the topic path with a `substr` per segment; caching the node
  in the subscription would do.
