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
| Bun `Bun.serve` | 1 × 32 | 637 ms | **2,505,360** | 0.48 s |
| Bun `Bun.serve` | 4 × 8 | 242 ms | **6,927,820** | 0.43 s |
| nimony hub | 1 × 32 | 750 ms | **2,157,985** | 1.30 s |
| nimony hub | 2 × 16 | 505 ms | **3,153,820** | 1.29 s |
| nimony hub | 4 × 8 | 386 ms | **4,112,705** | 1.29 s |
| nimony, writer per connection | 1 × 32 | 669 ms | **2,389,735** | 6.08 s |
| nimony, writer per connection | 4 × 8 | 570 ms | **2,705,367** | 5.64 s |

The Bun 4×8 row is the noisiest (6.4–7.6 M across runs on this shared box);
nimony's 4×8 row is 3.6–4.2 M.

Per single message (one connection, 1600 round trips, no fan-out):
nimony **32,601 msg/s** (~49 ms per 1600 round trips, ~31 µs each),
Bun **187,140 msg/s** (~8.5 ms, ~5 µs each).

Reading the table:

* **With one client process the two are equal** (2.16–2.39 M against 2.51 M):
  there the client is the bottleneck, not the server.
* **Bun scales further** — 6.9 M against 4.1 M with four client processes —
  but no longer by an order of magnitude, and nimony's server CPU is now
  *flat* at 1.29 s whatever the split: it stopped being the limit.
* **Bun is still ~3× cheaper per delivery** (0.43 s against 1.29 s of server
  CPU for the same 8.2 M deliveries). That difference is now small in absolute
  terms on this box, and it is what keeps Bun ahead when four client processes
  compete with the server for the four cores.
* The last two rows are the same room with a writer chain per connection, which
  is what the library's one-writer-per-connection rule forces an application
  into. Same throughput at one client process, 4.4× the CPU, and it stops
  scaling at 2.7 M — see [Why Bun still scales better](#why-bun-still-scales-better).

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

## Why Bun still scales better

Bun's server does the whole fan-out in **one** task: a published message is 32
appends to 32 per-connection buffers, and each connection is flushed once per
event-loop turn. There is no hand-off per message and no task per connection.

`std/websocket` allows exactly one writer per connection — a task that writes
another connection's socket interleaves two frames — so the obvious server
gives every connection a writer chain of its own and publishes through one
channel per connection. A message then costs 32 channel sends (each a
ticket-lock round trip, a 24-byte copy and a wakeup), 32 writer chains waking
up, and one syscall per chain per burst. That is the `writer per connection`
row above: it stops scaling at 2.7 M because the fan-out plumbing, not the
network, is what it runs out of.

The **hub** is the same trick Bun uses, within the same rule: one chain owns
every connection's writer. A reader sends the line to the hub (one channel send
per message instead of 32), the hub writes it into every connection's buffer
with `flush = false`, and when its inbox runs dry it flushes each connection
once. That is `src/chatserver.nim`; the per-connection server is kept as
`src/chatserver-conn.nim` for the comparison.

| | writer per connection | hub |
|---|---|---|
| deliveries/s, 1 client process | 2,389,735 | 2,157,985 |
| deliveries/s, 4 client processes | 2,705,367 | **4,112,705** |
| server CPU per round | 1.13–1.22 s | **0.26 s** |
| `io_uring_enter` per round | 45,595 | **3,358** |

The hub gives up a little latency at one client process (the fan-out is
serialised, and the last connection in the turn is written after the first) and
wins 1.5× throughput and 4.4× CPU once the clients can push. Its 3,358 enters
per round are **488 deliveries per syscall** — Bun's `sendto` carries 33.

What is left after that is a ~3× CPU-per-delivery difference, in the frame
encode + copy and the one channel hop per message, and it no longer limits
throughput on this box.

## What is left

* The hub writes all 32 connections and *then* flushes them one after another,
  each flush waiting for its own write. Those 32 waits are sequential; letting
  them overlap (submit the turn's writes, wait for all of them once) would need
  a submit-without-wait plus a wait, which is the deferred-submit variant
  [rejected above](#4-what-was-tried-and-rejected-submit-at-the-end-of-the-cycle)
  — but combined with the wait, not instead of it. That is the next thing to
  measure.
* The channel hop per message: one ticket-lock round trip and a 24-byte copy.
  Batching the reader's lines before handing them to the hub would cut it by
  the batch size, at the cost of an allocation per batch.

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
