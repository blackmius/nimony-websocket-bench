# nimony WebSocket chat-room benchmark

The workload of Bun's [`bench/websocket-server`](https://github.com/oven-sh/bun/tree/main/bench/websocket-server)
— a chat room where every message a client sends is echoed to all 32 clients —
run against a chat server written in Nim on top of nimony's `std/websocket`,
and against Bun's own server, driven by the same client on the same machine.

It started as a measurement and turned into an optimisation of
`std/websocket`, `std/streamio` and `std/channels`: see
[What was changed](#what-was-changed). The server went from **927k to ~2.4M
fan-out messages/s** on this box, and from 1.48 M `io_uring_enter` per round to
46 k.

The Bun files are vendored unmodified in `vendor/bun-websocket-server/`; the
client that produces the numbers is `src/bench-client.mjs`, which is Bun's
`chat-client.mjs` with per-round wall-clock timing instead of its 1-second
counter (see [Why not the original counter](#why-not-the-original-counter)).

## Results

4-core aarch64 Linux (6.8), Bun 1.4.4, Node v24.13.0, nimony 0.6.3
(`nimony c -d:release`). 5 rounds per configuration, median reported. The box
is shared, so treat single-digit percentages as noise.

One round is 32 clients × 1600 messages each, every message fanned out to all
32 clients: **51,200 publishes, 1,638,400 frame deliveries**.

| server | client procs | round | deliveries/s | server CPU |
|---|---|---|---|---|
| Bun `Bun.serve` | 1 × 32 | 635 ms | **2,515,891** | 0.49 s |
| Bun `Bun.serve` | 4 × 8 | 224 ms | **7,353,584** | 0.45 s |
| nimony, `Room` | 1 × 32 | 608 ms | **2,665,439** | 0.77 s |
| nimony, `Room` | 2 × 16 | 340 ms | **4,729,159** | 0.59 s |
| nimony, `Room` | 4 × 8 | 241 ms | **6,689,450** | 0.59 s |
| nimony, writer per connection | 1 × 32 | 644 ms | **2,477,026** | 6.10 s |
| nimony, writer per connection | 4 × 8 | 525 ms | **3,088,521** | 5.22 s |

The Bun 4×8 row is the noisiest (6.4–7.6 M across runs on this shared box);
nimony's 4×8 row is 6.6–6.8 M.

Per single message (one connection, 1600 round trips, no fan-out):
nimony **32,228 msg/s** (~50 ms per 1600 round trips, ~31 µs each),
Bun **183,876 msg/s** (~8.7 ms, ~5 µs each).

Reading the table:

* **With one client process nimony is ahead** (2.64 M against 2.54 M): there the
  client is the bottleneck, and the room's turn costs less than Bun's loop.
* **Bun is still ahead with four client processes** — 7.35 M against 6.69 M —
  but by 10%, not by 3×. nimony's server CPU is *flat* at 0.6–0.8 s whatever
  the split, against Bun's 0.45–0.49 s: a 1.3× difference, not a 15× one.
* The last two rows are the same room with a writer chain per connection,
  which is what the library's one-writer-per-connection rule forces an
  application into without a `Room`. Same throughput at one client process,
  ~10× the CPU, and it stops scaling at 2.5 M.

## What was changed

Five changes, in the order they were made and measured. Each one is in the
nimony tree; the numbers are the per-connection server at one client process
(`conn-1x32` in `results/`), because that is the one that was being optimised
at each step.

### 1. One flush per frame, not two

`std/websocket`'s `sendFrame` wrote the frame header and the payload with two
`write` + `flush` pairs. A flush is a syscall and, on a ring, a submit-and-wait,
so every frame cost two of them for a header of two to fourteen bytes:

```nim
# before
head = frameHeader(opcode, payload.len, false, key, fin)
wr.writeProto(head)      # write + flush
wr.writeProto(payload)   # write + flush
```

Both pieces now go into the stream's buffer and are flushed once.

**927k → 1.22 M msg/s; server CPU 4.75 s → 3.55 s per round.**

### 2. `send(..., flush = false)` and `flush`

One flush per frame is still one syscall per delivery, and a server that fans a
message out to 32 connections pays it 32 times. A run of frames can share one
flush instead: `send` takes `flush = true` by default (so nothing existing
changed), and `flush` is exposed on `WebSocketWriter` and `WebSocket`. The
pair's `recv` flushes before it parks, so a writer that also reads cannot leave
a frame behind.

`std/channels` gained `tryRecv` and `std/streamio` gained `tryReadRecord`: a
non-parking receive, so a writer chain can drain its outbox, write the frames
with `flush = false`, and flush once when the outbox runs dry.

**1.22 M → 2.38 M msg/s; server CPU 3.55 s → 1.74 s per round.**

### 3. The frame is spelled in place, so it allocates nothing

`frameHeader` built a fresh string per frame and a client's masked copy was a
second one: two allocations per delivered frame. `std/streamio` gained
`Writer.grow(n)` — `n` bytes at the end of the writer's buffer, for a caller
that serialises in place — and `std/websocket` spells the header and the
payload straight into it. Frames past 32 KiB still take the old path: there the
copy would cost more than the allocation.

**Server CPU 1.74 s → ~1.4 s per round** (the round time is client-bound by
then, so it does not move).

### 4. What was tried and rejected: submit at the end of the cycle

Bun writes into a per-connection buffer and lets the event loop submit it, and
it looked like the same thing should be done in `streamio`: keep the bytes in
the core, have the ring submit **one** write per connection per cycle, and drop
the `flush` knob entirely. It was implemented (a `gBeforePoll` hook in
`std/ioring`, called from the pool's per-cycle reactor step; `Core.outBuf`
accumulating; one `submitWrite` per core per cycle) and measured:

| variant | deliveries/s | `io_uring_enter` per round |
|---|---|---|
| accumulate + `flush` + wait (what is kept) | **2,356,284** | **45,595** |
| accumulate + submit at cycle end, no wait | 1,330,590 | 1,059,755 |

It is *worse*, and the reason is worth writing down: **the wait is what makes
the batch**. A writer that never waits keeps pace with the publisher, so it
writes one frame per cycle and the cycle submits one frame per op — the
deferral moves the syscall but not the op count. The `flush` after draining the
outbox is what puts thirty frames into one op; the wait for that op is what
lets the next thirty queue up. `flush` does not control *when* the submit
happens (that is the loop's business) — it controls *how much* is in the buffer
when the op is created.

### 5. The syscalls: 1.48 M → 46 k per round

`strace -c -f` on the server during one round (`results/syscalls/`):

| server | calls in one round (1,638,400 deliveries) |
|---|---|
| nimony, before | **1,478,997 `io_uring_enter`** (~0.9 per frame) |
| nimony, after | **45,595 `io_uring_enter`** (~36 frames per call) |
| Bun | **49,765 `sendto`** (~33 frames per call) |

So the "one `io_uring_enter` per event-loop cycle" goal is met, and it was
already met by the ring: ops are queued per lane and the backend drains up to
128 of them into one `io_uring_enter` per `poll`. The original code paid one
syscall per frame because the writer waited for each write, so there was never
more than one op in the queue.

## The room: publish/subscribe in `std/websocket`

Bun's server does the whole fan-out in **one** task: a published message is 32
appends to 32 per-connection buffers, and each connection is flushed once per
event-loop turn. `std/websocket` allows exactly one writer per connection — a
task that writes another connection's socket interleaves two frames — so an
application on the pair API has to give every connection a writer chain of its
own and publish through one channel per connection. A message then costs 32
channel sends, 32 wakeups and a task per delivery, which is the `writer per
connection` row above: it stops scaling at 2.6 M.

`std/websocket` now has a `Room` that keeps the rule and gets Bun's shape: it
owns the members' writers, and the connection joins it and publishes through
it, without leaving the pair API.

```nim
proc handle(c: sink HttpConnection) {.passive.} =
  if not c.next(): return
  var ws = upgradeWebSocket(c)
  ws.subscribe("chat")                # the room writes from here on
  try:
    while true:
      var msg = ""
      case ws.recv(msg)
      of mkText: ws.publish("chat", msg)     # one channel send
      of mkClose: break
      else: discard
  except ErrorCode:
    discard
  ws.close()
```

`subscribe` and `publish` use the process-wide room (`defaultRoom()`) when
they are not given one, so topics are just names, as in Bun. A server that
wants isolated rooms makes one with `newRoom` and passes it:
`ws.subscribe(room, "chat")`.

Topics are **paths**, as in uWebSockets: `"chat"`, `"chat/room1"`,
`"chat/room1/users"`. Publishing to a topic reaches its subscribers *and* the
subscribers of everything below it, so `publish("chat", ...)` is the whole room
and `publish("chat/room1", ...)` one part of it. The room keeps a tree of topic
segments rather than a list of members to scan: a publish walks the path once
and then the subscribers that hang off the node it lands on. A member that is
in both a topic and one of its parents is reached twice by one walk, so each
publish carries a generation and a member that has already had it is skipped.

That is not only a scaling argument — it is where most of the win came from
here, with a *single* topic. The flat version compared the published topic
against every member's topic string on every delivery (1.6 M string compares
per round, ~120 ns each); the tree compares node segments once per publish and
an integer per delivery. The round time fell from 790 ms to 611 ms at one
client process, and from 458 ms to 254 ms at four.

The room writes into every member's buffer with `flush = false` and flushes
each member once per turn, so a message costs one channel send and one buffer
append per member. That is `src/chatserver.nim`; the per-connection server is
kept as `src/chatserver-conn.nim` for the comparison.

| | writer per connection | `Room` (tree) |
|---|---|---|
| deliveries/s, 1 client process | 2,477,026 | **2,665,439** |
| deliveries/s, 4 client processes | 3,088,521 | **6,689,450** |
| server CPU per round | 1.04–1.22 s | **0.12 s** |
| `io_uring_enter` per round | 45,595 | **3,558** |

The room is 2.2× faster than a writer chain per connection with four client
processes, and 9× cheaper in CPU. Its 3,558 enters per round are **461
deliveries per syscall**; Bun's `sendto` carries 33.

What is left is the channel hop per message and the frame encode + copy: 0.59 s
of server CPU per 5 rounds against Bun's 0.45 s. It no longer limits throughput
on this box.

## What is left

* The room's turn ends by flushing its members one after another, and each
  flush waits for its own write, so those waits are sequential. Overlapping
  them — submit the turn's writes, wait once — needs "submit without waiting"
  plus "wait for the drain". The deferred-submit variant
  [rejected above](#4-what-was-tried-and-rejected-submit-at-the-end-of-the-cycle)
  is exactly the first half; with the wait kept, a turn's flushes would overlap
  instead of serialising.
* The channel hop per message: one ticket-lock round trip and a 24-byte copy.
  Batching a reader's lines before handing them to the room would cut it by the
  batch size, at the cost of an allocation per batch.
* `publish` walks the topic path with `substr` per segment, and a member's
  subscription is a `seq[string]` — fine for chat-shaped topics, wasteful for
  a hot loop over deep paths. Caching the node in the subscription would do.

## Other things found while writing the server

* **A disconnecting client kills the server.** The first build exited with
  code 141 (SIGPIPE) the moment the clients closed their sockets: the runtime
  installs no SIGPIPE handler and the write path does not pass
  `MSG_NOSIGNAL` (`lib/std/posix/io_uring.nim` defines the flag, nothing uses
  it). `src/chatserver.nim` installs `SIG_IGN` at startup, which every
  long-running server would have to do. This looks like a runtime bug worth
  fixing in `std/ioring` or `std/streamio` rather than in each server.
* The registry of subscribers is copied under a lock and written to outside
  it: `send` parks when an outbox is full, and a task parked while holding
  the registry lock would keep every new connection out of the room.

## Why not the original counter

Bun's `chat-client.mjs` prints "messages per second" from a 1-second counter
that only advances when a whole batch of 1,638,400 echoes has arrived, so it
is quantised to whole batches and saturates: every one of its ten windows
printed exactly `3276800` (2 batches) against the Bun server. That is enough to
rank the two, but not to see whether Bun was finished.
`src/bench-client.mjs` keeps the same workload and the same message list, sends
a batch, waits for every echo, and times that with `performance.now()`.

When several client processes are used, the round is fenced by a file barrier
(a directory of empty files, one per process per round). Without it, one
process's next round is counted by a straggler as the previous round's echoes
and the counts drift until a round never completes.

## Layout

```
src/chatserver.nim          the chat room on std/httpserver + std/websocket
src/bench-client.mjs        round-based client (Bun's workload, timed)
scripts/build.sh            build bin/chatserver with bin/nimony
scripts/bench.sh            one configuration: server + N client processes
scripts/summarize.py        median round time, aggregate rate, server CPU
scripts/run-all.sh          the table above
scripts/fetch-bun-bench.sh  re-vendor oven-sh/bun's bench/websocket-server
vendor/bun-websocket-server/  Bun's files, unmodified
results/                    raw logs of the saved run, and the strace counts
```

## Reproducing

```sh
# a nimony checkout with bin/nimony built (hastur build nimony)
NIMONY=/path/to/nimony scripts/build.sh

scripts/run-all.sh          # ROUNDS=10 for longer runs
```

One configuration on its own:

```sh
scripts/bench.sh nimony-1x32 1 32 ./bin/chatserver
scripts/bench.sh bun-1x32    1 32 bun vendor/bun-websocket-server/chat-server.bun.js
```

Requirements: `node` ≥ 22 (for the built-in `WebSocket`), `python3`, and `bun`
for the Bun rows. The client script is Bun's own and runs on Node unchanged.

## Caveats

* Everything ran on one 4-core machine with server and clients sharing it.
  Bun's numbers are client-bound at one client process; nimony's are
  server-bound at every split.
* `chatserver.nim` is written for the comparison, not as a library: no
  subprotocols, no origin check, no ping/idle handling beyond the echo, no
  limit on room size, and the "ready" broadcast after 32 joins is Bun's
  benchmark protocol, not a design.
* The vendored Bun files are from `main` as of 2026-10-26; re-run
  `scripts/fetch-bun-bench.sh` to refresh them.
