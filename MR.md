# std/websocket: one flush per frame, no per-frame allocation, and a batched fan-out

## Summary

A chat-room server written on `std/websocket` moved **927k → 2.36M fan-out
messages/s** on a 4-core aarch64 box, with the server's CPU per round down from
4.75 s to 1.40 s and `io_uring_enter` calls per round down from 1,478,997 to
45,595. Bun's own server, same client, same machine: 2.40M messages/s and
49,765 `sendto`.

Three things were in the way, all of them in the write path:

1. `sendFrame` wrote the frame header and the payload with **two**
   `write` + `flush` pairs. A flush is a syscall and, on a ring, a
   submit-and-wait, so a two-byte header cost as much as the payload.
2. Every frame cost **two heap allocations**: one for the header string, and
   one for a client's masked copy of the payload.
3. There was no way to write a **run** of frames with one syscall, which is
   what a fan-out needs: one published message becomes 32 frames, and each of
   them paid a syscall of its own.

The MR fixes all three, and adds the two primitives an application needs to use
them (a non-parking channel receive, and an in-place buffer append).

Everything here is additive: existing call sites keep their exact behaviour,
and the wire bytes are unchanged (`tests/nimony/websocket/tframe.nim` checks
them against the RFC's own spelling).

## Numbers

Workload: Bun's [`bench/websocket-server`](https://github.com/oven-sh/bun/tree/main/bench/websocket-server)
— 32 clients, each sends 1600 messages, every message is echoed to all 32
clients. One round is 51,200 publishes and 1,638,400 frame deliveries. Median
of 5 rounds, `nimony c -d:release`, 4-core aarch64.

| | before | after | Bun 1.4.4 |
|---|---|---|---|
| deliveries/s (1 client process) | 927,248 | **2,356,284** | 2,396,351 |
| server CPU per round | 4.75 s | **1.40 s** | ~0.09 s |
| `io_uring_enter` per round | 1,478,997 | **45,595** | 49,765 `sendto` |
| deliveries/s (4 client processes) | 824,417 | **2,663,686** | 5,316,157 |

Per change, each measured on its own:

| change | deliveries/s | server CPU per round |
|---|---|---|
| baseline | 927,248 | 4.75 s |
| 1. one flush per frame | 1.22 M | 3.55 s |
| 2. `flush = false` + `tryRecv` drain | 2.38 M | 1.74 s |
| 3. frame spelled in place | 2.36 M | ~1.40 s |

The syscall count is the clearest single number: **~0.9 `io_uring_enter` per
delivered frame before, ~36 frames per call after** — the ring already batches
up to 128 queued ops per `poll`, and the only reason it never had more than one
was that the writer waited for each write to complete.

## What changed

### `lib/std/websocket.nim`

* `sendFrame` puts the header and the payload in the stream's buffer and
  flushes **once**. `writeProto` stays for handshakes, where one write is the
  whole message.
* The frame is spelled in place: `fillHeader`/`fillFrame` write into the
  writer's buffer through the new `Writer.grow`, so a frame allocates nothing.
  A client's payload is still copied (masking must not touch the caller's
  bytes), but into the same buffer instead of a string of its own.
* Frames above `MaxBufferedFrame` (32 KiB) keep the old path: there the copy
  costs more than the allocation, so the payload goes to the kernel straight
  from the caller's memory.
* `frameHeader` is now a thin wrapper over `fillHeader` — same bytes, one
  implementation instead of two.
* `send` takes `flush = true`. With `flush = false` the frame only joins the
  connection's buffer; a run of frames then reaches the kernel as one write.
  `flush` is exposed on `WebSocketWriter` and `WebSocket`.
* The pair's `recv` flushes before it parks, so a writer that also reads can
  never leave a frame behind and wait for an answer to something the peer has
  not been told. A flush of an empty buffer does not reach the descriptor.

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
all, no waiting.

It measured **worse**:

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

## Testing

* `tests/nimony/websocket` (2/2) — including the frame codec's byte-for-byte
  RFC checks and the 31-case server suite over a real socket.
* `tests/nimony/http` (15/15), `tests/nimony/streams` (4/4) — `streamio` and
  `channels` are under both.
* `tests/nimony/stdlib/tall.nim` — every module in `lib/std` still compiles
  together.

The benchmark, its harness and the raw logs (including the `strace -c` counts)
are in a separate repository:
`nimony-websocket-bench` (`scripts/run-all.sh` reproduces the table).

## Compatibility

* No behaviour change for existing callers: `flush` defaults to `true`, and a
  flush of an empty buffer is free.
* `frameHeader`, `writeProto` and every other public signature are unchanged.
* New API only: `Writer.grow`, `Reader.tryReadRecord`, `Receiver.tryRecv`,
  `WebSocketWriter.flush`, `WebSocket.flush`, and the `flush` parameter on
  `send`.

## What this enables in an application

The benchmark server was rewritten on top of `flush = false` + `tryRecv` into a
*hub*: one chain owns every connection's writer, a reader hands it a line (one
channel send instead of 32), and it flushes each connection once per turn. On
the same box that is 2.7 M → 4.1 M deliveries/s with four client processes, and
server CPU 5.64 s → 1.29 s per round, because the library's one-writer-per-
connection rule no longer forces a channel send, a wakeup and a task per
delivery. `io_uring_enter` per round drops from 45,595 to 3,358 — 488
deliveries per syscall, against Bun's 33 per `sendto`.

## Follow-ups (not in this MR)

* The hub's turn ends by flushing 32 connections one after another, and each
  flush waits for its own write, so those waits are sequential. Overlapping
  them — submit the turn's writes, wait once — needs "submit without waiting"
  plus "wait for the drain". The deferred-submit variant measured above is
  exactly the first half, and it lost because it dropped the second; with the
  wait kept, the 32 flushes of a turn would overlap instead of serialising.
  That is the next measurement, and it is a library change only if it pays.
* A client that disconnects still kills a server that does not install
  `SIG_IGN` for `SIGPIPE`: the runtime has no handler and the write path does
  not pass `MSG_NOSIGNAL` (the flag is defined in `lib/std/posix/io_uring.nim`
  and unused). Worth fixing in the runtime rather than in every server.
