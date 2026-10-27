# std/websocket: a `Room` for fan-out, one flush per frame, and a runtime that holds 8k connections

## Summary

A chat-room server written on `std/websocket` — the workload of Bun's
[`bench/websocket-server`](https://github.com/oven-sh/bun/tree/main/bench/websocket-server)
— is now **within 8% of Bun on every row and ahead on three of the five**, on a
4-core aarch64 box, measured interleaved against Bun on the same machine:

| | nimony | Bun 1.4.4 | |
|---|---|---|---|
| chat, 1 client process | 2,471,337 deliveries/s | 2,530,469 | −2.3% |
| chat, 4 client processes | **7,976,888** | 7,670,167 | +4.0% |
| plain echo, 1 client process | **307,849** msg/s | 294,511 | +4.5% |
| plain echo, 4 client processes | **1,011,558** msg/s | 1,096,155 | −7.7% |
| plain echo, 2000-byte messages | **152,563** msg/s | 144,004 | +5.9% |

A third implementation of the same workloads — Rust on the `wtx` crate — is in
the same benchmark for scale, and it says what is left: it is level on the echo
and **4.5× behind on the fan-out**, because it writes a delivered frame per
syscall (1.6 M `writev` per round) where the room puts ~461 deliveries in one
`io_uring_enter`. See [Where wtx (Rust) sits](#where-wtx-rust-sits).

The write path and the fan-out are most of the way there, but not all of it.
Three separate things were in the way:

1. **The write path and the fan-out.** `sendFrame` wrote the header and the
   payload with two `write` + `flush` pairs; every frame cost two heap
   allocations; there was no way to write a run of frames with one syscall and
   no publish/subscribe at all, so an application had to fan out through one
   channel per connection. The MR fixes all four and adds the primitives they
   need (`Writer.grow`, a non-parking channel receive, and `Room`).
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
   came down from 12.0 KB to **9.1 KB** — four causes, none of them in the
   WebSocket layer.

Everything is additive: existing call sites keep their exact behaviour, and the
wire bytes are unchanged (`tests/nimony/websocket/tframe.nim` checks them
against the RFC's own spelling).

## Numbers

Workload: 32 clients, each sends 1600 messages, every message is echoed to all
32 clients. One round is 51,200 publishes and 1,638,400 frame deliveries.
`nimony c -d:release`, 4-core aarch64. The box is shared and drifts by ~10%
between runs, so Bun and nimony are measured **interleaved** (Bun, nimony, Bun,
nimony), 10 rounds per configuration, 3 repetitions each, medians reported; a
3% difference is not a result.

Chat — the fan-out workload, one round is 51,200 publishes:

| | before this MR | after | Bun 1.4.4 |
|---|---|---|---|
| deliveries/s, 1 client process | 927,248 | **2,471,337** | 2,530,469 |
| deliveries/s, 4 client processes | 824,417 | **7,976,888** | 7,670,167 |
| server CPU per round, 1 process | 4.75 s | 0.179 s | 0.100 s |
| server CPU per round, 4 processes | — | 0.100 s | 0.106 s |
| `io_uring_enter` per round | 1,478,997 | **3,558** | 49,765 `sendto` |

Plain echo — no fan-out at all, 51,200 messages and 51,200 deliveries a round
(the "before" column is this MR before `TCP_NODELAY`, the one line that moved
this benchmark):

| | before | after | Bun 1.4.4 |
|---|---|---|---|
| messages/s, 1 client process | 313,275 | **307,849** | 294,511 |
| messages/s, 4 client processes | 675,817 | 1,011,558 | 1,096,155 |
| messages/s, 2000-byte messages | — | **152,563** | 144,004 |

The rows that are behind are the chat at one client process (−2.3%) and the
echo at four (−7.7%, and the noisiest row on this box: over 5 interleaved pairs
of its own it reads 1,077,431 against Bun's 1,021,132, +5.5%). Both are the
ones where the client, not the server, is the limit, so what they measure is
latency, and the trampoline below trades a little of it for the rest.

Scale — N connections held open, each ping-ponging as fast as it can, 8 s per
run, medians of 2 runs, 4 client processes:

| connections | Bun rate | nimony rate | ratio | Bun p50 | nimony p50 | Bun p99 | nimony p99 |
|---|---|---|---|---|---|---|---|
| 32 | 176,866 | 139,962 | 79% | 164 µs | 205 µs | 491 µs | 568 µs |
| 128 | 368,292 | 277,612 | 75% | 302 µs | 393 µs | 956 µs | 1,484 µs |
| 512 | 397,547 | 319,694 | 80% | 1,083 µs | **922 µs** | 4,212 µs | 6,576 µs |
| 2048 | 309,966 | 236,440 | 76% | 6,261 µs | 7,553 µs | 14,592 µs | 22,793 µs |

At a **fixed** offered rate, with the server's capacity never the limit
(512 connections, one message each per interval):

| offered | server | delivered | p50 | p99 | CPU |
|---|---|---|---|---|---|
| 5,120 msg/s | Bun | 5,050 | 3,690 µs | 13,467 µs | 0.07 |
| 5,120 msg/s | nimony | **5,069** | **2,275 µs** | **10,528 µs** | 0.13 |
| 51,200 msg/s | Bun | 46,929 | 861 µs | 5,461 µs | 0.30 |
| 51,200 msg/s | nimony | **48,639** | **834 µs** | **3,763 µs** | 0.49 |

Holding connections — 8192 connections, one echo each, then idle:

| server | held | server RSS per connection | idle CPU |
|---|---|---|---|
| Bun `Bun.serve` | 8192 / 8192 | **1.7 KB** | 0.04 cores |
| nimony, before this MR | 8192 / 8192 | 12.0 KB | 0.05 cores |
| nimony, after | 8192 / 8192 | **9.1 KB** | 0.06 cores |

The syscall count is the clearest single number for the fan-out: **~0.9
`io_uring_enter` per delivered frame before, ~36 frames per call after, ~461
with the room** — the ring already batches up to 128 queued ops per `poll`, and
the only reason it never had more than one was that the writer waited for each
write to complete.

## Where wtx (Rust) sits

A third implementation of the same two workloads rides along, to say what the
remaining gap is made of: `rust/wtx-server` in `nimony-websocket-bench`, the
low-level API of wtx 0.52 (`WebSocketAcceptor`, one tokio task per connection),
echo and chat. Measured in rotation with the other two — Bun, nimony, wtx /
nimony, wtx, Bun / wtx, Bun, nimony — medians of 3:

| | Bun | nimony | wtx |
|---|---|---|---|
| chat, 1 client process | **2,488,162** | 2,403,859 | 2,247,476 |
| chat, 4 client processes | 7,968,171 | **8,112,098** | 1,767,378 |
| echo, 1 client process | 275,387 | 278,878 | **287,897** |
| echo, 4 client processes | 1,039,793 | **1,132,036** | 1,073,080 |
| echo, 2000-byte messages | 139,667 | **152,890** | 137,794 |

One session, so the absolute numbers differ from the tables above by the box's
drift (the echo rows by ±10% between sessions); the three columns are what
compare. The echo is level — three implementations of one protocol. The fan-out
is not, and the syscall count says why: wtx's `write_frame` has no queue and no
`flush`, so it is one `writev` per delivered frame, **1,638,464 per round**
against the room's 3,558 `io_uring_enter` and Bun's 49,765 `sendto`, and 0.77 s
of server CPU against 0.21 and 0.10. Batching a turn's writes is exactly what
this MR's write path does and what the crate's public writer does not expose.

The same holds for idle connections: 8192/8192 held at **11.8 KB** of server
RSS each and 0.06 cores, against the 9.1 KB above and Bun's 1.7.

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
* **`Room`** — publish/subscribe, and the only place in the module that writes
  to more than one connection. The connection joins it, so the handler stays on
  the pair API:

  ```nim
  var ws = upgradeWebSocket(c)
  ws.subscribe("chat")                       # the room owns the writer now
  ...
  ws.publish("chat", msg)                    # one channel send
  ```

  `subscribe` moves the writer into the room; from then on `ws.send`, `ws.recv`
  and `ws.close` go through it, so pings are answered and the peer's close is
  echoed by whatever owns the writer. The room writes into every member's
  buffer with `flush = false` and flushes each member once per turn, so a
  publish is one channel send and one buffer append per member — not a task per
  delivery. `subscribe`/`publish` use the process-wide `defaultRoom()` when not
  given one (topics are then just names, as in Bun); `newRoom` gives a server
  isolated rooms, and `Room.publish` is the server-initiated form. `publish`
  parks when the room's queue is full: that is the backpressure, and it is per
  room rather than per member.

  Topics are **paths**, as in uWebSockets — `"chat"`, `"chat/room1"`,
  `"chat/room1/users"` — and a publish reaches the topic *and everything below
  it*. The room keeps a tree of segments instead of a list of members to scan,
  so a publish walks the path once and then the subscribers hanging off the
  node it lands on; a member that is in both a topic and one of its parents is
  reached once, by a per-publish generation. That is where most of the room's
  win came from even with a single topic: the flat version compared the
  published topic against every member's topic string on every delivery
  (1.6 M string compares per round), the tree compares segments once per
  publish and an integer per delivery. A server masks nothing, so the frame a
  publish produces is the same bytes for every member: it is spelled once per
  publish and appended, not encoded again for each of the 32. Round time 790 ms → 611 ms at one client
  process, 458 ms → 254 ms at four. The text is checked as UTF-8 once per
  publish rather than once per member, and the topic of the last publish is
  remembered so a repeated topic is one string compare rather than a walk.

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
| chat, 1 client process | 2,452,195 | 2,434,654 | −0.7% |
| chat, 4 client processes | 8,394,646 | 8,418,868 | +0.3% |
| echo, 1 client process | 299,331 | 289,572 | −3.3% |
| echo, 4 client processes | 1,031,886 | 990,672 | −4.0% |
| 512 connections, `MODE=max` | 294,988 | 293,189 | −0.6% |

All inside the ±5–8% spread of the box, and the counters explain it: over a
512-connection round the deques' shared FIFO is never used (`fifoOwn` /
`fifoStolen` = 0) and only ~3% of batches come from another worker's deque
(0.4% in the chat), because `flushStaged` already hands the owner 32 tasks per
lock; the gate's claimed ~7% on the one-process echo does not reproduce either
(−0.9%). Both were removed — that is ~110 lines this MR no longer has.

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
`initSocket`, a held connection went from **12.0 KB to 9.1 KB** of server RSS.

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
* A plain echo server (`src/echoserver.nim`, no room at all) is the per-message
  rows in Numbers above: the +4.5% at one client process is the protocol and the
  write path, the −7.7% at four is the trampoline (see `threadpool.nim`), and
  the 2000-byte row is +5.9%.
* `scripts/run-scale.sh` holds 32…2048 connections open, each ping-ponging:
  every connection is accepted (2048/2048, no errors) at 75–81% of Bun's
  aggregate rate, with a comparable or better median RTT at 512 connections and
  a p99 ~1.6× worse. At a fixed offered rate nimony delivers more, at a lower
  median and a lower p99 — the tables are in Numbers.
* `scripts/run-conns.sh` holds 8192 connections open and idle after one echo
  each: both servers keep every one of them, nimony at 9.1 KB of server RSS per
  connection against Bun's 1.7 KB, and idle CPU is flat in the connection count
  (0.06 cores against Bun's 0.04). A 32,768 connection run stops at 28,228 held
  for *both* servers — the loopback ephemeral port range, not either server —
  and at 9.1 KB each that is ~250 MB of server memory.
* `tests/nimony/stdlib/tgzip.nim` and `tests/nimony/http/tcompress.nim` cover
  the `Deflater` whose histograms moved to the heap.
* `tests/nimony/websocket/troom.nim` (new) — a room over a real socket:
  `ws.publish` reaches every member including the sender, `ws.send` reaches one
  connection only, a publish to a parent topic reaches the topics below it and
  a member in both gets the line once, a publish to a child reaches only its
  subtree, a member leaving does not take the room with it, and the room
  answers the peer's close.
* `tests/nimony/http` (15/15), `tests/nimony/streams` (4/4) — `streamio` and
  `channels` are under both.
* `tests/nimony/stdlib/tall.nim` — every module in `lib/std` still compiles
  together.

The benchmark, its harness and the raw logs (including the `strace -c` counts)
are in a separate repository, `nimony-websocket-bench`: `scripts/run-all.sh`
reproduces the tables, `scripts/run-rust.sh` the one with wtx in the rotation.

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
  `WebSocketReader.buffered`, `WebSocketWriter.flush`, `WebSocket.flush`, the
  `flush` parameter on `send`,
  and `Room` with `newRoom`, `defaultRoom`, `Room.publish`, `Room.addTopic`,
  `Room.dropTopic`, plus `WebSocket.subscribe`, `WebSocket.unsubscribe` and
  `WebSocket.publish`. A connection that never subscribes behaves exactly as
  before.

## Follow-ups (not in this MR)

* **What is left of the 9.1 KB per connection.** The 16 KB read reservation is
  gone (1 KB now, growing only while a peer fills it), and what remains is the
  `HttpConnection` itself (848 bytes of it), the WebSocket state of an upgraded
  connection, the writer's outbox once it has written something, and the echo
  chain parked on its next read — two orders of magnitude above Bun's 1.7 KB.
  The next steps, in order: reuse the per-connection objects from a per-lane
  pool (they are allocated and freed in the same lane), shrink the frames (the
  echo frame holds a whole `WebSocket` by value), and the allocator's page
  granularity — a 2 KB chunk still touches a 4 KB page.
* **The p99 in the many-connection case** is ~1.6× Bun's while the median is
  better. A worker cannot poll its own lane while it runs a continuation, so a
  long chain delays every completion on that lane; that is why a bigger
  `trampolineSteps` is not automatically better, and why the gate that used to
  bound it was measured out rather than kept — it bought nothing on the
  throughput rows and the p99 is still there.
* The room's turn ends by flushing its members one after another, and each
  flush waits for its own write, so those waits are sequential. Overlapping
  them — submit the turn's writes, wait once — needs "submit without waiting"
  plus "wait for the drain". The deferred-submit variant measured above is
  exactly the first half, and it lost because it dropped the second; with the
  wait kept, a turn's flushes would overlap instead of serialising.
* `publish` walks the topic path with a `substr` per segment. Fine for
  chat-shaped topics, wasteful for a hot loop over deep paths; caching the node
  in the subscription would do.
* A client that disconnects still kills a server that does not install
  `SIG_IGN` for `SIGPIPE`: the runtime has no handler and the write path does
  not pass `MSG_NOSIGNAL` (the flag is defined in `lib/std/posix/io_uring.nim`
  and unused). Worth fixing in the runtime rather than in every server.
* The room's turn ends by flushing its members one after another, and each
  flush waits for its own write, so those waits are sequential. Overlapping
  them — submit the turn's writes, wait once — needs "submit without waiting"
  plus "wait for the drain". The deferred-submit variant measured above is
  exactly the first half, and it lost because it dropped the second; with the
  wait kept, a turn's flushes would overlap instead of serialising.
* `publish` walks the topic path with a `substr` per segment. Fine for
  chat-shaped topics, wasteful for a hot loop over deep paths; caching the node
  in the subscription would do.
* A client that disconnects still kills a server that does not install
  `SIG_IGN` for `SIGPIPE`: the runtime has no handler and the write path does
  not pass `MSG_NOSIGNAL` (the flag is defined in `lib/std/posix/io_uring.nim`
  and unused). Worth fixing in the runtime rather than in every server.
