# std/websocket: a `Room` for fan-out, one flush per frame, no per-frame allocation

## Summary

A chat-room server written on `std/websocket` — the workload of Bun's
[`bench/websocket-server`](https://github.com/oven-sh/bun/tree/main/bench/websocket-server)
— moved **927k → 2.48M** fan-out messages/s on a 4-core aarch64 box with the
existing pair API, and **2.62M → 3.90M** with four client processes once the
new `Room` does the fan-out. Server CPU per round went from 4.75 s to 1.40 s
(pair API) and 0.26 s (room); `io_uring_enter` calls per round from 1,478,997
to 45,595 and 3,261. Bun's own server, same client, same machine: 2.45M and
7.41M, at 0.53 s and 0.45 s.

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
Median of 5 rounds, `nimony c -d:release`, 4-core aarch64.

| | before | after (pair API) | after (`Room`) | Bun 1.4.4 |
|---|---|---|---|---|
| deliveries/s, 1 client process | 927,248 | 2,524,746 | **2,638,737** | 2,541,884 |
| deliveries/s, 4 client processes | 824,417 | 2,449,155 | **6,286,334** | 7,291,716 |
| server CPU per round, 1 process | 4.75 s | 1.40 s | 0.12–0.17 s | ~0.09 s |
| `io_uring_enter` per round | 1,478,997 | 45,595 | **3,296** | 49,765 `sendto` |

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
  flushes before it parks, so a writer that also reads can never leave a frame
  behind and wait for an answer to something the peer has not been told.
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
  publish and an integer per delivery. Round time 790 ms → 611 ms at one client
  process, 458 ms → 254 ms at four.

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

The hook was removed; the change set is what measured best. (In a `Room` the
batch comes from the room's queue instead, which is why the room does not need
the per-frame flush at all.)

## Testing

* `tests/nimony/websocket/tframe.nim` — the frame codec, byte for byte against
  the RFC.
* `tests/nimony/websocket/tserver.nim` — 31 cases over a real socket: the
  handshake, the three length forms, fragments, pings, and the protocol
  violations a server has to refuse.
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
  `WebSocketWriter.flush`, `WebSocket.flush`, the `flush` parameter on `send`,
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
