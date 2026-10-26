# std/websocket: a `Room` for fan-out, one flush per frame, no per-frame allocation

## Summary

A chat-room server written on `std/websocket` — the workload of Bun's
[`bench/websocket-server`](https://github.com/oven-sh/bun/tree/main/bench/websocket-server)
— moved **927k → 2.54M** fan-out messages/s on a 4-core aarch64 box, and
**824k → 8.00M** with four client processes. Server CPU per round went from
4.75 s to 0.195 s; `io_uring_enter` calls per round from 1,478,997 to 3,558.
Bun's own server, same client, same machine, measured interleaved: 2.54M and
8.12M, at 0.101 s and 0.089 s per round.

The write path and the fan-out are most of that, but not all of it: the runtime
underneath took a `SysLock` per queued task and per submitted I/O op, and the
scheduler was **52% of the echo server's CPU**. Both queues are lock-free now
(a same-thread ring for a lane's ops, Chase-Lev work-stealing deques for
tasks), which is −42% instructions per echoed message.

Four things were in the way, all in the write path:

1. `sendFrame` wrote the frame header and the payload with **two**
   `write` + `flush` pairs. A flush is a syscall and, on a ring, a
   submit-and-wait, so a two-byte header cost as much as the payload.
2. Every frame cost **two heap allocations**: one for the header string, one
   for a client's masked copy of the payload.
3. There was no way to write a **run** of frames with one syscall, which is
   what a fan-out needs: one published message becomes 32 frames, each paying a
   syscall of its own.
4. There was no **publish/subscribe** at all, so an application had to give
   every connection a writer chain of its own and fan out through one channel
   per connection: 32 channel sends, 32 wakeups and a task per delivery.

The MR fixes all four, and adds the primitives they need (`Writer.grow`, a
non-parking channel receive, and `Room`).

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

| | before | after (pair API) | after (`Room`) | Bun 1.4.4 |
|---|---|---|---|---|
| deliveries/s, 1 client process | 927,248 | 1,626,234 | **2,538,241** | 2,536,238 |
| deliveries/s, 4 client processes | 824,417 | 1,792,313 | **7,995,201** | 8,117,359 |
| server CPU per round, 1 process | 4.75 s | 2.85 s | 0.195 s | 0.101 s |
| `io_uring_enter` per round | 1,478,997 | 45,595 | **3,558** | 49,765 `sendto` |

Per change, each measured on its own with the pair API at one client process:

| change | deliveries/s | server CPU per round |
|---|---|---|
| baseline | 927,248 | 4.75 s |
| 1. one flush per frame | 1.22 M | 3.55 s |
| 2. `flush = false` + `tryRecv` drain | 2.38 M | 1.74 s |
| 3. frame spelled in place | 2.48 M | ~1.40 s |

The syscall count is the clearest single number: **~0.9 `io_uring_enter` per
delivered frame before, ~36 frames per call after, ~502 with the room** — the
ring already batches up to 128 queued ops per `poll`, and the only reason it
never had more than one was that the writer waited for each write to complete.

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

**Trampolining a chain inline.** `drainOnce` re-submits a continuation that
yields more work, so a chain's next step goes back through the queue — ~20
submits per echoed message. Running the chain inline until it parks cuts that to
~0.3 and 12% of the echo's CPU, and costs 13% of its throughput (309k → 269k at
one client process): a worker cannot poll its own io_uring lane while it runs,
so every deferred poll is deferred latency, and the echo is latency-bound. The
room is neutral. Reverted. (In a `Room` the
batch comes from the room's queue instead, which is why the room does not need
the per-frame flush at all.)

### `lib/std/threadpool.nim`, `lib/std/ioring/core/backend.nim`

* A lane's deferred ops have one consumer (that lane's `poll`) and, for a
  worker, one producer — the same thread, since a worker submits its ops from
  the continuations it runs. So `gOpQueues[lane]` is an `OpQueue` whose
  owner-side queue is a plain `LocalRing`: no lock, no atomics. The locked
  `FifoStripe` stays for the two multi-producer cases (the trailing lane shared
  by every non-worker thread, and iocp's cross-lane routing).
* `localQueues` is a set of Chase-Lev work-stealing deques: the owner pushes at
  `bottom` (its only writer), and the owner and thieves alike take from `top`
  with one compare-exchange per batch, so `BulkSize` tasks cost one atomic
  operation. A push from a thread that is not the owner still takes the locked
  FIFO.
* `deliver` submits a resumed chain without an `fd` hint, so it is staged on the
  polling lane instead of being pushed into another worker's stripe.
* The per-worker counters are behind `-d:threadpoolMetrics`; without it
  `countMetric` compiles to nothing and `workerMetrics` is never allocated.
  They were on the hottest lines and nothing in the library reads them.
* Instructions per echoed message (callgrind, same workload): 6,497 with the
  locked queues, 4,082 with the `LocalRing` op queue, 3,736 with the deques.

## Testing

* `tests/nimony/websocket/tframe.nim` — the frame codec, byte for byte against
  the RFC.
* `tests/nimony/websocket/tserver.nim` — 31 cases over a real socket: the
  handshake, the three length forms, fragments, pings, and the protocol
  violations a server has to refuse.
* A plain echo server (`src/echoserver.nim`, no room at all) is at
  313k messages/s against Bun's 311k with one client process, and 676k against
  1.19M with four, on 1.5× Bun's CPU per message. 15 messages per
  `io_uring_enter`, against Bun's 33 per `sendto`.
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
are in a separate repository, `nimony-websocket-bench` (`scripts/run-all.sh`
reproduces the table).

## Compatibility

* No behaviour change for existing callers: `flush` defaults to `true`, and a
  flush of an empty buffer is free.
* `frameHeader`, `writeProto` and every other existing public signature are
  unchanged.
* New API only: `Writer.grow`, `Reader.tryReadRecord`, `Receiver.tryRecv`,
  `WebSocketReader.buffered`, `WebSocketWriter.flush`, `WebSocket.flush`, the
  `flush` parameter on `send`,
  and `Room` with `newRoom`, `defaultRoom`, `Room.publish`, `Room.addTopic`,
  `Room.dropTopic`, plus `WebSocket.subscribe`, `WebSocket.unsubscribe` and
  `WebSocket.publish`. A connection that never subscribes behaves exactly as
  before.

## Follow-ups (not in this MR)

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
