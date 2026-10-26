# nimony WebSocket chat-room benchmark

The workload of Bun's [`bench/websocket-server`](https://github.com/oven-sh/bun/tree/main/bench/websocket-server)
— a chat room where every message a client sends is echoed to all 32 clients —
run against a chat server written in Nim on top of nimony's `std/websocket`,
and against Bun's own server, driven by the same client on the same machine.

The Bun files are vendored unmodified in `vendor/bun-websocket-server/`; the
client that produces the numbers is `src/bench-client.mjs`, which is Bun's
`chat-client.mjs` with per-round wall-clock timing instead of its 1-second
counter (see [Why not the original counter](#why-not-the-original-counter)).

## Results

4-core aarch64 Linux (6.8), Bun 1.4.4, Node v24.13.0, nimony 0.6.3
(`nimony c -d:release`). 5 rounds per configuration, median reported.

One round is 32 clients × 1600 messages each, every message fanned out to all
32 clients: **51,200 publishes, 1,638,400 frame deliveries**.

| server | client procs | round | deliveries/s | server CPU |
|---|---|---|---|---|
| Bun `Bun.serve` | 1 × 32 | 653 ms | **2,489,846** | 0.52 s (~0.16 core) |
| Bun `Bun.serve` | 4 × 8 | 230 ms | **7,254,591** | 0.45 s (~0.39 core) |
| nimony `std/websocket` | 1 × 32 | 1764 ms | **927,248** | 23.73 s (~2.7 cores) |
| nimony `std/websocket` | 2 × 16 | 1876 ms | **860,659** | 23.48 s |
| nimony `std/websocket` | 4 × 8 | 1909 ms | **824,417** | 22.69 s |

Reading the table:

* **nimony moves ~0.9 M fan-out messages/s and is CPU-bound.** Splitting the
  clients over more processes does not help — it gets slightly worse, because
  the server already wants ~2.7 of the 4 cores and the client processes now
  compete with it.
* **Bun is not the bottleneck at one client process.** Its server used 0.16
  core while the single Node client process delivered 2.5 M msg/s, and
  splitting the clients over 4 processes took the same server to 7.25 M msg/s.
  So the 2.5 M row is a Node-client ceiling, not a Bun ceiling.
* Per single message (one connection, 1600 round trips, no fan-out):
  nimony **31,636 msg/s** (~50 ms per 1600 round trips, ~31 µs each),
  Bun **189,461 msg/s** (~8.4 ms, ~5 µs each).

So on this workload nimony's `std/websocket` is ~2.7× slower than Bun when
both are driven by one client process, and ~8.8× slower once the client side
is given enough processes not to be the limit. Both gaps are CPU, not
bandwidth: nimony is pinned at 2.7 cores while Bun idles.

## Why the gap: one I/O operation per frame

`strace -c -f` on the server during one round (`results/syscalls/`):

| server | calls in one round (1,638,400 deliveries) |
|---|---|
| nimony | **1,478,997 `io_uring_enter`** (+823 `futex`) |
| Bun | **49,765 `sendto`** (+68 `recvfrom`, 9 `epoll_pwait2`) |

How those were taken (one round per server, `results/syscalls/`):

```sh
CLIENTS_COUNT=32 setsid ./bin/chatserver &   # or bun chat-server.bun.js
srv=$!; sleep 1.5
node src/bench-client.mjs                    # warm-up round
strace -c -f -p $srv -o results/syscalls/nimony.txt & sp=$!
node src/bench-client.mjs                    # the round that is counted
kill -INT $sp; kill -- -$srv
```

`strace` inflates the wall time enormously (18 µs per call), so the counts are
the evidence here, not the timings.

Bun delivers ~33 frames per `sendto`: it appends the frame into the
connection's outgoing buffer and flushes each connection once per event-loop
turn.

nimony issues ~1 `io_uring_enter` per delivered frame, because
`std/websocket`'s `sendFrame` writes the frame header and the payload as two
separate `write` + `flush` pairs, and every `flush` is a full io_uring
submit-and-wait:

```nim
# lib/std/websocket.nim, sendFrame (server role)
head = frameHeader(opcode, payload.len, false, key, fin)
wr.writeProto(head)      # write + flush
wr.writeProto(payload)   # write + flush
```

That is the whole difference: ~1 syscall round trip per frame versus ~0.03.
Everything else the server does (the channel hop to the writer chain, the
frame encoding) is noise next to it.

What would close it, in order of payoff:

1. **Write the header and the payload in one call** — one allocation of
   `head.len + payload.len` instead of two `writeProto` calls. Roughly halves
   the I/O operations per frame.
2. **Let the writer buffer, and flush when the outbox is empty** rather than
   per frame. `std/streamio`'s writer already buffers up to 64 KiB; a
   `writeProto` that does not flush would let a fan-out of 32 messages reach
   the kernel as a handful of writes, which is what Bun does. The flush
   belongs at the point where the application has nothing left to send, not
   inside the frame encoder.
3. Fan-out batching on top of that (one buffer per connection per turn).

## Other things found while writing the server

* **A disconnecting client kills the server.** The first build exited with
  code 141 (SIGPIPE) the moment the clients closed their sockets: the runtime
  installs no SIGPIPE handler and the write path does not pass
  `MSG_NOSIGNAL` (`lib/std/posix/io_uring.nim` defines the flag, nothing uses
  it). `src/chatserver.nim` installs `SIG_IGN` at startup, which every
  long-running server would have to do. This looks like a runtime bug worth
  fixing in `std/ioring` or `std/streamio` rather than in each server.
* **`std/websocket` has no pub/sub, and says so**: one connection has one
  writer, and a handler that writes from another task interleaves two frames.
  The chat room therefore gives each connection two chains — a reader that
  publishes into the room, and a writer that owns the socket and drains its
  own outbox — with `std/channels` as the backpressure. That is 2 tasks per
  connection and one channel hop per delivery, and it is *not* where the time
  goes (see above), but it is the shape any multi-client server has to take
  with this API today.
* The registry of subscribers is copied under a lock and written to outside
  it: `send` parks when an outbox is full, and a task parked while holding
  the registry lock would keep every new connection out of the room.

## Why not the original counter

Bun's `chat-client.mjs` prints "messages per second" from a 1-second counter
that only advances when a whole batch of 1,638,400 echoes has arrived, so it
is quantised to whole batches and saturates: every one of its ten windows
printed exactly `3276800` (2 batches) against the Bun server, and ~0.8–1.0 M
against nimony. That is enough to rank the two, but not to see whether Bun was
finished. `src/bench-client.mjs` keeps the same workload and the same message
list, sends a batch, waits for every echo, and times that with
`performance.now()`.

When several client processes are used, the round is fenced by a file barrier
(a directory of empty files, one per process per round). Without it, one
process's next round is counted by a straggler as the previous round's echoes
and the counts drift until a round never completes — which is exactly what
happened before the barrier was added.

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
results/                    raw logs of the saved run (server, clients, syscalls)
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
  The Bun numbers are client-bound at one client process; the nimony numbers
  are server-bound at every split.
* `chatserver.nim` is written for the comparison, not as a library: no
  subprotocols, no origin check, no ping/idle handling beyond the echo, no
  limit on room size, and the "ready" broadcast after 32 joins is Bun's
  benchmark protocol, not a design.
* The vendored Bun files are from `main` as of 2026-10-26; re-run
  `scripts/fetch-bun-bench.sh` to refresh them.
