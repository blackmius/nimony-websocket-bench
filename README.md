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
(`nimony c -d:release`).

**Method.** Each pair was measured *interleaved* — Bun, nimony, Bun, nimony — 10
rounds per configuration, medians reported. The box is shared, so a single pair
of runs can differ by 10%: the interleaving is what makes the ratio mean
something, and a 3% difference is not a result.

One round is 32 clients × 1600 messages each, every message fanned out to all
32 clients: **51,200 publishes, 1,638,400 frame deliveries**.

| server | clients | round | deliveries/s | server CPU |
|---|---|---|---|---|
| Bun `Bun.serve` | 1 × 32 | 641 ms | **2,536,238** | 1.01 s |
| nimony, `Room` | 1 × 32 | 647 ms | **2,538,241** | 1.95 s |
| Bun `Bun.serve` | 4 × 8 | 199 ms | **8,117,359** | 0.89 s |
| nimony, `Room` | 4 × 8 | 204 ms | **7,995,201** | 1.26 s |

Reading the table:

* **At parity.** 2.54 M against 2.54 M with one client process (+0.1%) and
  8.00 M against 8.12 M with four (−1.5%): the two are level, and the sign
  flips between runs. Before the work below it was 0.93 M against 2.44 M.
* **Bun uses ~1.3× less CPU** (0.89 s against 1.26 s per 10 rounds at four
  client processes). The throughput is at parity anyway; the CPU headroom is
  what a bigger fan-out spends.
* The per-connection server (`chatserver-conn.nim`, which is what the library's
  one-writer-per-connection rule forces an application into without a `Room`)
  is **4.1× slower** in the same run: 1.79 M at 21.45 s of CPU against 7.40 M at
  1.36 s.

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

## The runtime: two queues that no longer lock

A callgrind profile of the echo server said the cost was the pool, not the
socket path: `submit` alone was 17% and the two stripe mutexes 12%. Both queues
took a `SysLock` per operation, and the ring's submission path is one op per
read and one per write.

**The op queue** (`lib/std/ioring/core/backend.nim`). A lane's deferred ops
have exactly one consumer — that lane's own `poll` — and, for a worker, one
producer: the same thread, because a worker submits its ops from the
continuations it runs. Producer and consumer being the same thread is not a
special case to optimise for, it is a reason to drop the lock *and* the
atomics. `gOpQueues[lane]` is now an `OpQueue` with a plain `LocalRing` for the
owner's own ops, and the old locked `FifoStripe` only for the two cases that
really are multi-producer: the trailing lane that every non-worker thread
shares, and iocp's routing of a socket's op to the lane that owns it.

**The task queue** (`lib/std/threadpool.nim`). `localQueues` is a set of
Chase-Lev work-stealing deques. The owner pushes at `bottom` — the only writer
of that index — and both the owner and a thief take from `top`, which only ever
moves by compare-exchange. Taking a *batch* is what the CAS buys: advancing
`top` to `top + n` is the instant the whole batch stops being visible to
anybody else, so one atomic operation covers `BulkSize` tasks. A push from a
thread that is not the owner still takes the locked FIFO, because `bottom` has
exactly one writer.

**Metrics behind a flag.** `-d:threadpoolMetrics` turns the per-worker counters
on and sizes `workerMetrics`; without it `countMetric` compiles to nothing and
the table stays empty. They sat on the hottest lines (`submit` bumped one per
task) and nothing in the library reads them.

Instructions per echoed message, same workload, callgrind:

| | Ir per message |
|---|---|
| locked op queue, locked stripes | 6,497 |
| `LocalRing` op queue | 4,082 |
| + work-stealing deques | 3,736 |

That is **−42% instructions per message**, and the stripe mutexes are gone from
the profile entirely. What is left is the scheduler itself: `submit` 21% (it is
still called ~20 times per message), `iouringPoll` 7%, `tryBulkPop` 7%,
allocation 13%, `workCycle` 6%, `expireDeadlines` 3%.

The wall clock moves much less than the instruction count, and the box is the
reason: the echo's server CPU per round went 1.42–1.62 s → 1.11 s while the
round time stayed at ~76 ms. **The echo is not CPU-bound at four client
processes** — it is idle a third of the round — so spending less CPU does not
make it faster. Where throughput is CPU-bound (the room, 1.6 M frame
deliveries per round) the same work shows up as CPU instead.

**Tried and reverted: trampolining a chain inline.** `drainOnce` re-submits a
continuation that yields more work, so the next step of a chain goes back
through the queue — ~20 submits per message on the echo path. Running the chain
inline until it parks (bounded at 64 steps) cuts that to ~0.3 submits per
message and 12% of the CPU… and costs 13% of the echo's throughput (309k →
269k at one client process), because a worker cannot poll its own io_uring lane
while it runs: every deferred poll is deferred latency, and this benchmark is
latency-bound. The room is neutral. Reverted; the numbers are here so the next
attempt starts from them.

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
| deliveries/s, 1 client process | 2,324,477 | **2,691,446** |
| deliveries/s, 4 client processes | 2,561,422 | **6,943,658** |
| server CPU per round | 1.22 s | **0.14 s** |
| `io_uring_enter` per round | 45,595 | **3,558** |

The last thing the fan-out was paying for: a server masks nothing, so the
frame a publish produces is the *same bytes* for every member — and it was
being encoded again for each of the 32. It is now spelled once per publish and
appended to each member's buffer. That alone took the room from 6.6 M to 7.6 M
at four client processes (CPU 0.79 s → 0.58 s per 5 rounds) and put it ahead of
Bun.

The room is 2.6× faster than a writer chain per connection with four client
processes, and 10× cheaper in CPU. Its 3,558 enters per round are **461
deliveries per syscall**; Bun's `sendto` carries 33.

What is left is the channel hop per message and the frame encode + copy: 0.59 s
of server CPU per 5 rounds against Bun's 0.45 s. It no longer limits throughput
on this box.

## Plain echo: no fan-out at all

The chat room hides the per-message cost under the fan-out. `scripts/run-echo.sh`
measures it on its own: a server that sends every message back to the
connection that sent it and nowhere else, driven by the same client
(`READY=0 TOTAL_CLIENTS=1`, so each client counts only its own echoes). One
round is 32 × 1600 = 51,200 messages and 51,200 deliveries. Same interleaved
method as above.

| | round | messages/s | server CPU per round | per message |
|---|---|---|---|---|
| Bun `Bun.serve` | 162 ms | **311,316** | 0.108 s | 2.11 µs |
| nimony `std/websocket` | 162 ms | **313,275** | 0.117 s | 2.28 µs |
| Bun `Bun.serve` | 46 ms | **1,186,888** | 0.037 s | 0.72 µs |
| nimony `std/websocket` | 76 ms | **675,817** | 0.056 s | 1.09 µs |
| Bun, 2000-byte messages | 335 ms | **151,022** | 0.179 s | 3.50 µs |
| nimony, 2000-byte messages | 299 ms | **169,192** | 0.230 s | 4.49 µs |

(upper rows: one client process, lower rows: four; the last two are 2000-byte
messages, one client process)

So with one client process nimony is level with Bun on a plain echo
(313,275 against 311,316), and with four it is at 57% on 1.5× Bun's CPU per
message. The last two rows are the same echo with 2000-byte messages, which
spreads the per-message cost over 133 times more bytes: there **nimony is
ahead** (169,192 against 151,022). So the per-byte path — copy, unmask, frame —
is already better than Bun's, and what is left is the fixed cost of a message.

The four-process row is not a CPU problem any more: the server spends 0.056 s of
CPU on a round that takes 76 ms, so it is idle a third of the time and the other
workers are idle throughout. It is the number of I/O round trips per message
that Bun wins on, and that is the next section's subject.

Getting there needed one thing: **an echo reply must not be its own syscall.**
The pair's `recv` flushes before it parks — that is the safety net that keeps a
`flush = false` sender from deadlocking — and it used to flush on *every* call,
so `send(flush = false)` was undone by the next `recv`. It now flushes only when
the connection has nothing buffered (`WebSocketReader.buffered`), which is when
the wait really happens; while frames are still coming, the replies ride along.
An echo server that writes `flush = false` then answers a burst with one write:

```nim
var ws = upgradeWebSocket(c)
while true:
  var msg = ""
  case ws.recv(msg)
  of mkText, mkBinary: ws.send(kind, msg, flush = false)
  of mkClose: break
  else: discard
```

That halved the server's CPU on the echo benchmark (0.56 s → 0.32 s per 5
rounds at four client processes) and moved it to level with Bun at one client
process.

Two smaller things went in with it: a client's frames are unmasked eight bytes
at a time instead of one, and `recv` assembles the message in the caller's own
string instead of a buffer of the reader's that was freed and copied out on
every message — so a handler that keeps its `msg` across calls allocates
nothing per message.

What is left per message is the runtime's cost, not the socket path: two
`.passive` calls per message (`recv` and `send`), a UTF-8 check on the way in
and another on the way out (an echo validates the same bytes twice), and the
parse/encode copies. Bun has none of the first two.

## What is left

* The room's turn ends by flushing its members one after another, and each
  flush waits for its own write, so those waits are sequential. Overlapping
  them — submit the turn's writes, wait once — needs "submit without waiting"
  plus "wait for the drain". The deferred-submit variant
  [rejected above](#4-what-was-tried-and-rejected-submit-at-the-end-of-the-cycle)
  is exactly the first half; with the wait kept, a turn's flushes would overlap
  instead of serialising.
* **The echo's remaining gap is round trips, not CPU.** After the queue work
  above, the server spends 0.056 s of CPU on a 76 ms round at four client
  processes: it is idle a third of the time, and the other workers are idle
  throughout. The workers still poll ~3 times per message and issue one read
  and one write op per message, because a message arriving alone (the client
  floods, but Node sends each frame as its own packet) is one completion and
  one write. Bun's event loop pays one `epoll_wait` for many sockets instead.
  That is the gap, and it is in the I/O design, not in the scheduler.
* Allocation is now the largest single block of the echo's CPU (13%,
  `rawAlloc`/`rawDealloc`, ~6 allocations per message). The frame codec is
  **~3%** (`validateUtf8` 1.5%, the payload `take` 1.2%, `memcpy` 1.3%) —
  measured on its own, `parseFrameHeader` is 1 ns, `applyMask` on 15 bytes 4 ns
  and `frameHeader` with its allocation 4 ns.
* Two things follow, in order: a write that does not wait for its completion
  (so the chain submits the next read instead of parking on the write), and
  fewer suspensions per batch. The first is the deferred-submit variant tried
  above, which lost *for the room* because the wait formed the next batch — the
  room now batches itself, so it is worth re-measuring for the echo.
* The chat's per-message cost is ~2.6 µs, and the channel hop is a large part of
  it: one send, one event construction and one wakeup per message. Batching a
  reader's lines into one event would cut it by the batch size.
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
scripts/run-all.sh          every configuration, one after another
scripts/run-interleaved.sh  the table above: A/B alternating, medians
scripts/fetch-bun-bench.sh  re-vendor oven-sh/bun's bench/websocket-server
vendor/bun-websocket-server/  Bun's files, unmodified
results/                    raw logs of the saved run, and the strace counts
```

## Reproducing

```sh
# a nimony checkout with bin/nimony built (hastur build nimony)
NIMONY=/path/to/nimony scripts/build.sh

scripts/run-interleaved.sh  # the numbers above: Bun and nimony alternating
scripts/run-all.sh          # every configuration in one sweep
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
  server-bound at every split except the plain echo at four client processes,
  where the server is idle a third of the round.
* `chatserver.nim` is written for the comparison, not as a library: no
  subprotocols, no origin check, no ping/idle handling beyond the echo, no
  limit on room size, and the "ready" broadcast after 32 joins is Bun's
  benchmark protocol, not a design.
* The vendored Bun files are from `main` as of 2026-10-26; re-run
  `scripts/fetch-bun-bench.sh` to refresh them.
