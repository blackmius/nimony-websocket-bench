# std/websocket: one flush per frame, and a runtime that holds thousands of connections

## Summary

The write path of `std/websocket` and the runtime underneath it, measured on
Bun's echo workload — 32 clients, every message echoed back to its sender — on
a 4-core aarch64 box, interleaved against Bun on the same machine:

| | nimony | Bun 1.4.4 | |
|---|---|---|---|
| plain echo, 1 client process | 277,768 msg/s | **281,306** | −1.3% |
| plain echo, 4 client processes | **1,078,218** msg/s | 974,504 | +10.6% |
| plain echo, 2000-byte messages | **147,089** msg/s | 136,070 | +8.1% |
| 8192 connections held idle | **9.0 KB** server RSS each | 1.7 KB | |
| 2048 connections ping-ponging | 241,874 msg/s | **282,010** | 86% |

The two per-message rows are the noisiest on this box and they swap places
between sessions — across the interleaved sessions the one-process row has
read −1.3…+10.7% against Bun and the four-process row −8.3…+10.6%, because
there the client, not the server, is the limit, and the trampoline below
trades a little latency for the rest. The 2000-byte row is consistently ahead
(+8…+12%), and so are two of the connection counts: the many-connection rows
are 75–92% of Bun's, which is the syscall batching Bun gets from one event
loop and the reason `IORING_OP_RECV_MULTISHOT` is a follow-up rather than a
claim.

Three things were in the way:

1. **The write path.** `sendFrame` wrote the header and the payload with two
   `write` + `flush` pairs, and every frame cost two heap allocations. The
   frame is now spelled in place in the stream's buffer and flushed once; a
   run of frames can be buffered (`send(flush = false)`) and handed to the
   kernel with one syscall.
2. **The runtime's queues.** The pool took a `SysLock` per queued task and per
   submitted I/O op; the scheduler was **52% of the echo server's CPU**. A
   lane's deferred ops are a plain `LocalRing` now — the producer and the
   consumer of a lane are the same thread — which is −37% instructions per
   echoed message; the per-connection list of ops in flight stopped being a
   hash table (`slots.nim`). Two further mechanisms were added for the same
   work and measured back out: a Chase-Lev work-stealing deque per stripe and
   the trampoline's "is a completion already published?" gate. Both were noise
   (−0.7…−4%, inside the box's spread), so the middle of this MR is smaller
   than it was.
3. **The per-message cost of a connection that is waiting.** In the flood
   benchmark one poll carries ~19 messages; in a server holding thousands of
   connections, one message is in flight per connection and a poll carries one.
   The same code cost **5.7 µs of CPU per message there against 1.1 µs in the
   flood**, and a profile named why: 16 chain re-submissions per message and a
   hash-table delete per operation. Both are gone (+10% at 512 connections),
   and the per-connection memory that made a big connection count impossible
   came down from 12.0 KB to **9.0 KB**.

Everything is additive: existing call sites keep their exact behaviour, and the
wire bytes are unchanged (`tests/nimony/websocket/tframe.nim` checks them
against the RFC's own spelling).

## Numbers

Workload: 32 clients, each sends 1600 messages, every message echoed back to
its sender — 51,200 messages and 51,200 deliveries per round. `nimony c
-d:release`, 4-core aarch64. The box is shared and drifts by ~10% between runs,
so Bun and nimony are measured **interleaved** (Bun, nimony, Bun, nimony), 20
rounds per configuration, 3 repetitions each, medians reported; a 3% difference
is not a result.

Plain echo — the whole write path and nothing else:

| | before | after | Bun 1.4.4 |
|---|---|---|---|
| messages/s, 1 client process | 313,275 | 277,768 | **281,306** |
| messages/s, 4 client processes | 675,817 | **1,078,218** | 974,504 |
| messages/s, 2000-byte messages | — | **147,089** | 136,070 |

The four-process row was 57% of Bun's until `TCP_NODELAY` was set on accept:
the kernel held each small write until the previous one was acknowledged, so
every reply cost an extra round trip — invisible in CPU and in syscall counts,
visible only as a latency that did not fall with concurrency. One ring op per
connection fixed it: 676k → 1.03M messages/s. The one-process row pays ~3% for
the trampoline, and it is the row where the client is the limit.

Scale — N connections held open, each ping-ponging as fast as it can, 8 s per
run, medians of 2 runs, 4 client processes:

| connections | Bun rate | nimony rate | ratio | Bun p50 | nimony p50 | Bun p99 | nimony p99 |
|---|---|---|---|---|---|---|---|
| 32 | 163,811 | 128,395 | 78% | 171 µs | 214 µs | 515 µs | 665 µs |
| 128 | 371,229 | 278,914 | 75% | 300 µs | 399 µs | 813 µs | 1,230 µs |
| 512 | 380,491 | 349,928 | **92%** | 1,197 µs | **820 µs** | 3,953 µs | 6,249 µs |
| 2048 | 282,010 | 241,874 | 86% | 6,793 µs | 7,332 µs | 15,482 µs | 21,973 µs |

At a **fixed** offered rate, with the server's capacity never the limit
(512 connections, one message each per interval, medians of 2):

| offered | server | delivered | p50 | p99 | CPU |
|---|---|---|---|---|---|
| 5,120 msg/s | Bun | 5,018 | 4,224 µs | **12,730 µs** | 0.09 |
| 5,120 msg/s | nimony | **5,069** | **3,596 µs** | 13,561 µs | 0.17 |
| 51,200 msg/s | Bun | 45,788 | 960 µs | 6,062 µs | 0.33 |
| 51,200 msg/s | nimony | **48,790** | **929 µs** | **4,744 µs** | 0.54 |

Holding connections — 8192 connections, one echo each, then idle; the RSS is
the difference before and after the connections, the idle CPU is measured over
5 s once they are all up and quiet:

| server | held | server RSS per connection | idle CPU |
|---|---|---|---|
| Bun `Bun.serve` | 8192 / 8192 | **1.7 KB** | 0.002 cores |
| nimony | 8192 / 8192 | **9.0 KB** | 0.066 cores |

nimony's 0.066 cores is the pool's periodic wakeup — a lane polls every 1 ms,
and an idle connection costs nothing on top of it. Before this MR the same
measurement read 12.0 KB per connection; what is left is the `HttpConnection`
itself (848 bytes of it), the WebSocket state of an upgraded connection, the
writer's outbox once it has written something, and the echo chain parked on its
next read. A 32,768-connection run stops at 28,228 held for *both* servers —
the loopback ephemeral port range, not either server — and at 9.0 KB each that
is ~250 MB of server memory.

## What changed

### `lib/std/websocket.nim`

* `sendFrame` puts the header and the payload in the stream's buffer and
  flushes **once**. `writeProto` stays for handshakes, where one write is the
  whole message.
* The frame is spelled in place: `fillHeader`/`fillFrame` write into the
  writer's buffer through the new `Writer.grow`, so a frame allocates nothing.
  A client's payload is still copied (masking must not touch the caller's
  bytes), but into the same buffer instead of a string of its own. Frames above
  `MaxBufferedFrame` (32 KiB) keep the old path: there the copy costs more than
  the allocation.
* `frameHeader` is now a thin wrapper over `fillHeader` — same bytes, one
  implementation.
* `send` takes `flush = true`. With `flush = false` the frame only joins the
  connection's buffer; a run of frames then reaches the kernel as one write.
  `flush` is exposed on `WebSocketWriter` and `WebSocket`. The pair's `recv`
  flushes before it parks — but only when the connection has nothing buffered
  (`WebSocketReader.buffered`), which is when the wait really happens. While
  frames are still coming, the replies ride along with the next write; that is
  what lets an echo server answer a burst with one write instead of one per
  message, and it halved its CPU.
### `lib/std/streamio.nim`

* `grow(w, n): var openArray[char]` — `n` bytes appended to the writer's
  buffer, for a caller that serialises a head or a frame in place. It is
  `scratch` for a writer that already has bytes buffered; nothing is copied and
  nothing is allocated once the buffer has grown.
* `tryReadRecord` — one record from a record ring if one is already there,
  `false` when it is empty. Never parks.
* **The read step adapts.** `readFd` reserved `ChunkSize` (16 KB) of spare room
  before every read, and a reservation is what the buffer keeps — so a server
  with 8000 quiet clients held 8000 sixteen-kilobyte buffers to receive forty
  bytes each. The step now starts at `MinRead` (1 KB) and doubles only while a
  read comes back full, up to `ChunkSize`, and falls back to `MinRead` when a
  read comes back short. A quiet connection holds 1 KB; a flooding peer is at
  16 KB reads within five reads, so the flood benchmark is unchanged.

### `lib/std/channels.nim`

* `Receiver.tryRecv` — one value if one is already waiting, `false` when the
  channel is empty or every sender is gone. Never parks. Over a record ring it
  is the ring's own answer; over a byte stream it is "the reader has this much
  buffered", the only case in which the read cannot park under the end lock.

Together these let a writer chain do the thing a fan-out needs:

```nim
while true:
  if not rx.tryRecv(m):
    wr.flush()                  # nothing queued: the batch goes out now
    if not rx.recv(m): return   # park until there is something
  wr.send(mkText, m.text, flush = false)
```

### `lib/std/threadpool.nim`: run a chain instead of re-queueing it

In the many-connection regime a message is one poll, and a callgrind profile
there put **24% of the instructions in `submit`** — 16 calls per message,
because every step of a `.passive` chain (an echo is eight frames deep) was
pushed to the queue and popped again: two atomics, a division and a call per
frame.

`drainOnce` now runs a chain's next steps inline (`trampolineSteps`, 64) instead
of re-queueing each one: on the many-connection echo that is ~16 submits per
message → ~0.27. 512 connections: **275k → 303k msg/s, CPU 1.62 → 1.44 cores**
(medians of three alternating pairs), echo at four client processes **993k →
1.12M (+13%)**. The one row that pays is the plain echo at one client process
(−6%), where the client is the limit and the server is idle a third of the
round: there, a worker that keeps unwinding delays the poll that has ~19
completions waiting.

Two mechanisms were built on top of this, on the theory that a worker should
never unwind while completions wait: a "is a completion already published?"
gate (`BackendRelays.hasReady`, one atomic load per step) and a Chase-Lev
work-stealing deque per stripe for the task queue. Measured against the final
tree, interleaved, medians of 3:

| workload | with both | this MR | |
|---|---|---|---|
| echo, 1 client process | 299,331 | 289,572 | −3.3% |
| echo, 4 client processes | 1,031,886 | 990,672 | −4.0% |
| 512 connections, `MODE=max` | 294,988 | 293,189 | −0.6% |

All inside the ±5–8% spread of the box, and the counters explain it: over a
512-connection round the deques' shared FIFO is never used (`fifoOwn` /
`fifoStolen` = 0) and only ~3% of batches come from another worker's deque,
because `flushStaged` already hands the owner 32 tasks per lock; the gate's
claimed ~7% on the one-process echo does not reproduce either (−0.9%). Both
were removed — that is ~110 lines this MR no longer has.

### `lib/std/ioring/core/slots.nim`: the fd is not a hash key

The per-fd op lists were headed by a `Table[cint, nil Slot]`: one hash, one
insert and one backshifting delete **per operation**, and `del` alone was 14.6%
of the instructions in that profile. A descriptor is already a small dense
integer, so the heads are a `seq[nil Slot]` indexed by `fd + 1` — the `+1`
because `opTimeout` and `opNop` have no descriptor (`fd = -1`), which a table
accepted and an array does not. Another **+8%** at 512 connections, and the
lane's allocation is 16 KB for 2048 connections.

### `lib/std/compress/deflate.nim`, `lib/std/httpserver.nim`: what a connection costs

`Deflater` kept its symbol frequencies inline — `array[286, int]` and
`array[30, int]`, 2.5 KB — and `Encoder` is a field of `HttpConnection`. Every
connection therefore carried a DEFLATE histogram for a compressor that is off by
default. The histograms moved to the heap, allocated once per *compressing*
stream: `sizeof(HttpConnection)` **3320 → 824 bytes**. With the read step above,
and with `std/socket` allocating its 8 KB + 8 KB buffers lazily instead of in
`initSocket`, a held connection went from **12.0 KB to 9.0 KB** of server RSS.

What is left is the connection itself: 848 bytes of `HttpConnection`, the
WebSocket state of a connection that has upgraded, the writer's outbox once it
has written something, and the chain that is parked on its next read. The read
step is 1 KB and only grows while a peer fills it, so a quiet connection pays
it once and nothing more.

`listenHttp`'s backlog default was 128. A client opening 8192 connections at
once overflowed it and **19% of them were lost to dropped SYNs**, which looks
like a server that cannot accept a storm. The default is 1024 now (nginx and
Node use 511); at 4096 the same run lost none.

### `lib/std/httpserver.nim`, `lib/std/ioring.nim`

* `accept` sets `TCP_NODELAY` on every connection (`setNoDelay`, one ring op).
  The library never set it, so the kernel could hold a small write until the
  previous one was acknowledged: for a server that answers in small messages
  that is one extra round trip per reply, invisible in CPU and in syscall
  counts and visible only as latency. The plain echo at four client processes
  went from **676k to 1.03M messages/s** because of this one line, and its
  p90 at 8 messages in flight fell from 112 µs to 85 µs. Every mainstream
  server (Node, nginx, Bun) sets it on accept.
* `setNoDelay` is public, so an application that wants Nagle back can ask for
  it, and an application on a raw socket can use it without the HTTP layer.

### `lib/std/threadpool.nim`, `lib/std/ioring/core/backend.nim`: the op queue

* A lane's deferred ops have one consumer (that lane's `poll`) and, for a
  worker, one producer — the same thread, since a worker submits its ops from
  the continuations it runs. So `gOpQueues[lane]` is an `OpQueue` whose
  owner-side queue is a plain `LocalRing`: no lock, no atomics. The locked
  `FifoStripe` stays for the two multi-producer cases (the trailing lane shared
  by every non-worker thread, and iocp's cross-lane routing).
* `localQueues` — the task queue — is a `FifoStripe` per worker, unchanged: the
  work-stealing deque that replaced it was measured out (above). A push from a
  thread that is not the owner still takes the locked FIFO, and `flushStaged`
  hands the owner a batch of 32 per lock.
* `deliver` submits a resumed chain without an `fd` hint, so it is staged on the
  polling lane instead of being pushed into another worker's stripe.
* The per-worker counters are behind `-d:threadpoolMetrics`; without it
  `countMetric` compiles to nothing and `workerMetrics` is never allocated.
  They were on the hottest lines and nothing in the library reads them.
* Instructions per echoed message (callgrind, same workload): 6,497 with the
  locked op queue, **4,082 with the `LocalRing`** — −37%.

### `lib/std/system/stringimpl.nim`: the first heap block of a string

Found while measuring the above, and not about connections at all: a string that
becomes long doubled its *first* heap block, because `transitionToLong` used the
geometric-growth helper on a string that had nothing to grow from. A 1 KB
reservation cost a 2 KB block, a 4 KB one 8 KB, a 16 KB read buffer 36 KB — on
every string in the program that ever became long: a read buffer, a writer's
outbox, every message a caller assembles. The first block is now what was asked
for and growth starts from there; `allocatedSize` of a 1 KB reservation went
2080 → 1056.

## What was tried and rejected

Bun keeps a per-connection buffer and lets the event loop submit it, so the
same shape was implemented in `streamio`: keep the bytes in the core, add a
`gBeforePoll` hook to `ioring` that runs once per cycle from the pool's reactor
step, and submit **one** write per connection per cycle — no `flush` knob at
all, no waiting. It measured worse:

| variant | deliveries/s | `io_uring_enter` per round |
|---|---|---|
| accumulate + `flush` + wait (kept) | **2,356,284** | **45,595** |
| accumulate + submit at cycle end, no wait | 1,330,590 | 1,059,755 |

The reason is worth recording: **the wait is what makes the batch.** A writer
that never waits keeps pace with the publisher, writes one frame per cycle, and
the cycle submits one frame per op — the deferral moves the syscall but not the
op count. The `flush` after draining the outbox is what puts thirty frames into
one op, and waiting for that op is what lets the next thirty queue up. `flush`
does not control *when* the submit happens (that is the loop's business); it
controls *how much* is in the buffer when the op is created.

The hook was removed; the change set is what measured best.

**`IORING_OP_RECV_MULTISHOT`.** The obvious next step for the many-connection
regime: one recv that stays armed and keeps producing completions, no re-arm per
read. It is not in this change, and the reason is the scheduler's shape and not
the ring's.

A multishot request is armed on *one* ring, and its completions land on the lane
that owns that ring for as long as it stays armed. A chain here can be stolen by
another worker between two reads; a second recv armed from the new lane would
race the first for the same stream, and two concurrent `recv`s on one socket
deliver bytes in whatever order the kernel picked — for a frame protocol that is
corruption. Making it safe means pinning a connection's chain to a lane for its
whole life (a "sticky" continuation), which is a change to the pool's load
balancing rather than to the WebSocket layer.

What it would buy is the SQE fill and one submit per read. In the
many-connection regime reads are already ~6.5 per `io_uring_enter`, so that is
the smaller half of the win, and the memory side — which is what made the big
connection count impossible — does not need multishot at all: the read step
starts at `MinRead` (1 KB) and grows only while a peer fills it.

**Trampolining a chain inline — the first attempt.** `drainOnce` re-submits a
continuation that yields more work, so a chain's next step goes back through the
queue — ~20 submits per echoed message. Running the chain inline until it parks
cuts that to ~0.3 and 12% of the echo's CPU, and cost 13% of its throughput
(309k → 269k at one client process): a worker cannot poll its own io_uring lane
while it runs, so every deferred poll is deferred latency, and that benchmark is
latency-bound. It was reverted.

The second attempt is in this MR and it works, because it runs in the drain loop
rather than in `submit`'s caller-runs path: the worker has already polled, and
unwinding a chain there is work it would have done next cycle anyway. It is
+13% on the echo at four client processes and +10% at 512 connections, and −6%
on the one row where the client is the limit. A gate that stopped the trampoline
early whenever a completion was already published was built for the same worry
and measured out with the deques (above).

## Testing

* `tests/nimony/websocket/tframe.nim` — the frame codec, byte for byte against
  the RFC.
* `tests/nimony/websocket/tserver.nim` — 31 cases over a real socket: the
  handshake, the three length forms, fragments, pings, and the protocol
  violations a server has to refuse.
* A plain echo server (`src/echoserver.nim`, no fan-out at all) is the per-message
  rows in Numbers above: the −1.3% at one client process is the trampoline
  (see `threadpool.nim`), the +10.6% at four is the write path once the client
  can keep up, and the 2000-byte row is +8.1%.
* `scripts/run-scale.sh` holds 32…2048 connections open, each ping-ponging:
  every connection is accepted (2048/2048, no errors) at 75–92% of Bun's
  aggregate rate, with a better median RTT at 512 connections and a p99
  1.3–1.6× worse (it grows with the connection count). At a fixed offered rate
  nimony delivers more, with a lower p99 at the high rate and a better median
  at the low one — the tables are in Numbers.
* `scripts/run-conns.sh` holds 8192 connections open and idle after one echo
  each: both servers keep every one of them, nimony at 9.0 KB of server RSS per
  connection against Bun's 1.7 KB, and idle CPU is the pool's 1 ms poll, flat in
  the connection count (0.066 cores against Bun's 0.002). A 32,768 connection
  run stops at 28,228 held for *both* servers — the loopback ephemeral port
  range, not either server — and at 9.0 KB each that is ~250 MB of server
  memory.
* `tests/nimony/stdlib/tgzip.nim` and `tests/nimony/http/tcompress.nim` cover
  the `Deflater` whose histograms moved to the heap.
* `tests/nimony/http` (15/15), `tests/nimony/streams` (4/4) — `streamio` and
  `channels` are under both.
* `tests/nimony/stdlib/tall.nim` — every module in `lib/std` still compiles
  together.

The benchmark, its harness and the raw logs are in a separate repository,
`nimony-websocket-bench`: `scripts/run-interleaved.sh` reproduces the echo
table, `scripts/run-scale.sh` the scale one, `scripts/run-conns.sh` the held
connections, and `scripts/run-all.sh` the lot.

## Compatibility

* No behaviour change for existing callers: `flush` defaults to `true`, and a
  flush of an empty buffer is free.
* `frameHeader`, `writeProto` and every other existing public signature are
  unchanged.
* Two defaults changed, both towards what a server wants: `listenHttp`'s
  `backlog` is 1024 (was 128, which loses connections in a burst), and a
  `Reader` starts with a 1 KB read step instead of reserving 16 KB (it still
  reaches 16 KB reads as soon as the peer fills it).
* `std/socket` allocates its read and write buffers on first use instead of in
  `initSocket`; `Socket.buffered`, `peek` and `take` are unchanged.
* A string's first heap block is the size that was asked for, not twice it.
  Only the *first* block changes: growth after it is geometric as before, so
  an append-heavy caller does at most one extra reallocation.
* New API only: `Writer.grow`, `Reader.tryReadRecord`, `Receiver.tryRecv`,
  `WebSocketReader.buffered`, `WebSocketWriter.flush`, `WebSocket.flush` and
  the `flush` parameter on `send`.

## Follow-ups (not in this MR)

* **What is left of the 9.0 KB per connection.** The 16 KB read reservation is
  gone (1 KB now, growing only while a peer fills it), and what remains is the
  `HttpConnection` itself (848 bytes of it), the WebSocket state of an upgraded
  connection, the writer's outbox once it has written something, and the echo
  chain parked on its next read — two orders of magnitude above Bun's 1.7 KB.
  The next steps, in order: reuse the per-connection objects from a per-lane
  pool (they are allocated and freed in the same lane), shrink the frames (the
  echo frame holds a whole `WebSocket` by value), and the allocator's page
  granularity — a 2 KB chunk still touches a 4 KB page.
* **The p99 in the many-connection case** is 1.3–1.6× Bun's while the median is
  better. A worker cannot poll its own lane while it runs a continuation, so a
  long chain delays every completion on that lane; that is why a bigger
  `trampolineSteps` is not automatically better, and why the gate that used to
  bound it was measured out rather than kept — it bought nothing on the
  throughput rows and the p99 is still there.
* A client that disconnects still kills a server that does not install
  `SIG_IGN` for `SIGPIPE`: the runtime has no handler and the write path does
  not pass `MSG_NOSIGNAL` (the flag is defined in `lib/std/posix/io_uring.nim`
  and unused). Worth fixing in the runtime rather than in every server.
