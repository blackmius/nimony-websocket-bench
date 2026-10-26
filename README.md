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

**Method.** Each pair was measured *interleaved* — Bun, nimony, Bun, nimony —
10 rounds per configuration, 3 repetitions each, medians reported. The box is
shared, so a single pair of runs can differ by 10%: the interleaving is what
makes the ratio mean something, and a 3% difference is not a result.

One round is 32 clients × 1600 messages each, every message fanned out to all
32 clients: **51,200 publishes, 1,638,400 frame deliveries**.

| server | clients | round | deliveries/s | server CPU |
|---|---|---|---|---|
| Bun `Bun.serve` | 1 × 32 | 678 ms | 2,407,612 | 1.08 s |
| nimony, `Room` | 1 × 32 | 658 ms | **2,466,097** | 1.98 s |
| Bun `Bun.serve` | 4 × 8 | 218 ms | 7,331,348 | 1.05 s |
| nimony, `Room` | 4 × 8 | 215 ms | **7,457,286** | 1.44 s |

Reading the table:

* **Ahead at both splits**, by 2.4% and 1.7% — small, and inside the noise of a
  single run, but the sign was the same in every repetition. Before the work
  below it was 0.93 M against 2.44 M.
* **Bun uses ~1.4× less CPU** (1.05 s against 1.44 s per 10 rounds at four
  client processes). The throughput is level anyway; the CPU headroom is what a
  bigger fan-out spends.
* The numbers are lower than an earlier run of this table (2.54 M / 8.00 M)
  because the box was busier; the ratio is what is comparable.


## What was changed

Six changes, in the order they were made and measured. Each one is in the
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

### 6. `TCP_NODELAY` on accept

Not a `std/websocket` change at all: the library never turned Nagle's algorithm
off, so the kernel could hold a small write until the previous one was
acknowledged. A server that answers in small messages pays one round trip per
reply for that, and pays it in latency only — the server's CPU and syscall
counts look fine, it is just idle. `httpserver.accept` now calls `setNoDelay`
(one ring op per connection), and the echo benchmark went from 676k to 1.03M
messages/s at four client processes. See
[the echo section](#plain-echo-no-fan-out-at-all).

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
| Bun `Bun.serve` | 203 ms | 251,697 | 0.136 s | 2.66 µs |
| nimony `std/websocket` | 170 ms | **297,445** | 0.134 s | 2.62 µs |
| Bun `Bun.serve` | 51 ms | 1,038,679 | 0.041 s | 0.80 µs |
| nimony `std/websocket` | 53 ms | **1,026,582** | 0.057 s | 1.10 µs |
| Bun, 2000-byte messages | 381 ms | 133,921 | 0.197 s | 3.85 µs |
| nimony, 2000-byte messages | 344 ms | **147,904** | 0.258 s | 5.03 µs |

(upper rows: one client process, lower rows: four; the last two are 2000-byte
messages, one client process)

nimony is **ahead at one client process (+18%)**, level at four (−1.2%), and
ahead again on 2000-byte messages (+10%). It spends 1.0× Bun's CPU per message
at one client process and 1.4× at four.

**The four-process row was 57% of Bun before one line changed: Nagle.** The
library never set `TCP_NODELAY`, so the kernel held each small write until the
previous one was acknowledged — for a server that answers in small messages,
one extra round trip per reply. It is invisible in CPU (the server was idle a
third of the round in both cases) and invisible in the syscall counts; it shows
up only as a latency that does not fall with concurrency. Turning it off on
accept (`httpserver.accept` → `setNoDelay`) moved that row from **676k to
1.03M messages/s** and the 8-in-flight p90 from 112 µs to 85 µs.

Two smaller things went in earlier: a client's frames are unmasked eight bytes
at a time instead of one, and `recv` assembles the message in the caller's own
string instead of a buffer of the reader's that was freed and copied out on
every message — so a handler that keeps its `msg` across calls allocates
nothing per message.


## Scalability: many connections

Throughput on one core is one question; "how many clients can it hold" is
another, and it is the one a server is bought for. `scripts/run-scale.sh` holds
N connections open, has every one of them ping-pong as fast as it can
(`MODE=max`), and reports the aggregate rate and the RTT each connection sees.
Connection counts are split over 4 client processes, and the percentiles are
over the merged samples of all of them.

**Mode `max`: every connection back-to-back** (8 s per run, 2 runs each,
medians):

| connections | server | rate | p50 | p99 | server CPU |
|---|---|---|---|---|---|
| 32 | Bun | 170,303 | 170 µs | 480 µs | 0.65 |
| 32 | nimony | 137,394 | 195 µs | 638 µs | 1.06 |
| 128 | Bun | 357,543 | 307 µs | 960 µs | 0.96 |
| 128 | nimony | 260,586 | 387 µs | 2,500 µs | 1.75 |
| 512 | Bun | 400,202 | 1,081 µs | 4,307 µs | 0.95 |
| 512 | nimony | 287,716 | 968 µs | 7,015 µs | 1.62 |
| 2048 | Bun | 315,491 | 6,133 µs | 14,524 µs | 0.95 |
| 2048 | nimony | 208,598 | 8,096 µs | 22,768 µs | 1.75 |

Reading it:

* **Every connection is held**: 2048 of 2048 opened, zero errors, both servers.
  nimony's accept loop spawns a task per connection and keeps going.
* **Rate is 66–81% of Bun's**, and the gap widens with concurrency. This is the
  one benchmark where Bun's single event loop wins: one `epoll_wait` collects
  every ready socket and one `sendto` carries ~32 replies, while the ring does
  ~3 `io_uring_enter` per burst of ~19 messages.
* **Median latency is comparable** — better at 512 connections (968 µs against
  1,081 µs) — but the **tail is ~1.6× worse** (p99 7.0 ms against 4.3 ms at
  512). Three workers spread the median; the tail is a worker that was busy.
* **CPU is 1.6–1.8× Bun's.** At 128 connections nimony spends 1.75 cores to
  Bun's 0.96, and on a 4-core box shared with four client processes that is
  paid for by the clients.

**Mode `paced`: 512 connections at a fixed offered rate** (one message per
connection per interval, so the server's capacity is never the limit):

| offered rate | server | rate | p50 | p99 | server CPU |
|---|---|---|---|---|---|
| 5,120 msg/s | Bun | 5,069 | 3,255 µs | 9,263 µs | 0.07 |
| 5,120 msg/s | nimony | 4,806 | 2,422 µs | 10,366 µs | 0.15 |
| 51,200 msg/s | Bun | 48,182 | 784 µs | 4,419 µs | 0.27 |
| 51,200 msg/s | nimony | 47,818 | 763 µs | 3,235 µs | 0.56 |

At a fixed load the two are level on the median, nimony is **better at the 99th
percentile** at the higher rate (3.2 ms against 4.4 ms), and it costs 2× the CPU
of a single-threaded server that is one thread away from its ceiling. That is
the trade the thread pool makes: twice the CPU, three cores of headroom.

## What is left

* **The echo is at parity now; the many-connection case is not.** The 66–81% in
  the scale table is syscall batching: Bun's event loop collects every ready
  socket in one `epoll_wait` and writes ~32 replies per `sendto`, while the ring
  does ~3 `io_uring_enter` per ~19-message burst. `IORING_OP_RECV_MULTISHOT`
  (kernel 6.0+) removes the read re-arm, and submitting a burst's writes without
  waiting for each would take the third `enter` out; the second was measured in
  isolation here and was neutral in the flood benchmark, which is why neither is
  in this change.
* **The tail.** nimony's p99 is ~1.6× Bun's at high concurrency while its median
  is better. Three workers each own a lane and only that lane's thread may poll
  it, so a worker inside a long continuation delays every completion on its own
  lane; that is also why trampolining a chain inline (measured, −12% CPU) cost
  throughput.
* The room's turn ends by flushing its members one after another, and each
  flush waits for its own write, so those waits are sequential. Overlapping
  them — submit the turn's writes, wait once — needs "submit without waiting"
  plus "wait for the drain". The deferred-submit variant
  [rejected above](#4-what-was-tried-and-rejected-submit-at-the-end-of-the-cycle)
  is exactly the first half; with the wait kept, a turn's flushes would overlap
  instead of serialising.
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
scripts/run-interleaved.sh  the throughput table: A/B alternating, medians
scripts/run-scale.sh        the scalability sweep: N connections, RTT, rate
src/scale-client.mjs        the scalability client (max rate or paced)
scripts/fetch-bun-bench.sh  re-vendor oven-sh/bun's bench/websocket-server
vendor/bun-websocket-server/  Bun's files, unmodified
results/                    raw logs of the saved run, and the strace counts
```

## Reproducing

```sh
# a nimony checkout with bin/nimony built (hastur build nimony)
NIMONY=/path/to/nimony scripts/build.sh

scripts/run-interleaved.sh  # the throughput numbers: Bun and nimony alternating
scripts/run-scale.sh        # the scalability sweep (MODE=paced for a fixed rate)
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
  That is the sharpest limit on the scalability sweep: at 128 connections
  nimony already spends 1.75 cores, and the four client processes are paying
  for it. A bigger box would show the thread pool's headroom better.
* The scalability numbers are per box, not per core: the client processes are
  the same in every row, so a row says "this server, that many connections, on
  this machine".
* `chatserver.nim` is written for the comparison, not as a library: no
  subprotocols, no origin check, no ping/idle handling beyond the echo, no
  limit on room size, and the "ready" broadcast after 32 joins is Bun's
  benchmark protocol, not a design.
* The vendored Bun files are from `main` as of 2026-10-26; re-run
  `scripts/fetch-bun-bench.sh` to refresh them.
