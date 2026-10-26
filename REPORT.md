# What improved

`std/websocket`'s write path and a new `Room` for fan-out, measured on Bun's
[`bench/websocket-server`](https://github.com/oven-sh/bun/tree/main/bench/websocket-server)
workload: 32 clients, every message echoed to all of them, one round =
51,200 publishes and 1,638,400 deliveries. 4-core aarch64, median of 5 rounds,
`nimony c -d:release`. Reproduce with `scripts/run-all.sh`.

## Headline

| | before | after | Bun 1.4.4 |
|---|---|---|---|
| deliveries/s, 1 client process | 927,248 | **2,690,980** | 2,542,382 |
| deliveries/s, 4 client processes | 824,417 | **7,638,596** | 7,372,058 |
| server CPU per round, 1 process | 4.75 s | 0.15 s | 0.10 s |
| `io_uring_enter` per round | 1,478,997 | **3,558** | 49,765 `sendto` |

2.9× more throughput at one client process, 9.3× at four, and ~10× less CPU
per round. nimony is **ahead of Bun at both splits**: +6% with one client process and
+4% with four.

## Where it came from, in order

Each step measured on its own, one client process:

| step | deliveries/s | server CPU per round |
|---|---|---|
| baseline | 927,248 | 4.75 s |
| `sendFrame` flushes once instead of twice | 1.22 M | 3.55 s |
| `send(flush = false)` + a non-parking `tryRecv` drain | 2.38 M | 1.74 s |
| the frame is spelled in place (`Writer.grow`), no allocation | 2.48 M | 1.40 s |
| `Room`: one chain owns every writer, `publish` is one channel send | 2.09 M | 0.28 s |
| topic tree instead of a member scan | 2.64 M | 0.12–0.17 s |
| topic cache + one UTF-8 check per publish (not per delivery) | 2.67 M | 0.12 s |
| the fan-out frame encoded once per publish, not once per member | **2.69 M** | **0.15 s** |

Four things were wrong, and they compounded:

1. **Two syscalls per frame.** The header and the payload were written with two
   `write` + `flush` pairs; a flush is a syscall and, on a ring, a
   submit-and-wait, so a two-byte header cost as much as the payload.
2. **One syscall per frame is still too many for a fan-out.** A published
   message becomes 32 frames, so the pair API needed a way to write a *run* of
   frames with one syscall — hence `flush = false` plus `tryRecv`, which lets a
   writer chain drain its outbox and flush once when it runs dry. The wait for
   that flush is also what lets the next batch form.
3. **Two allocations per frame.** `frameHeader` built a string per frame and a
   client's masked copy was a second one. The frame is now spelled straight
   into the writer's buffer.
4. **No fan-out at all**, so every connection needed a writer chain of its own
   and a publish cost 32 channel sends, 32 wakeups and a task per delivery.
   `Room` owns the writers and does the fan-out in one chain: one channel send
   per publish, one buffer append per member, one flush per member per turn.

The topic tree is not only a scaling argument. Topics are paths
(`"chat/room1"`) and a publish reaches the subtree below it, but the win here
came with a *single* topic: the flat version compared the published topic
against every member's topic string on every delivery — 1.6 M string compares
per round, ~120 ns each — and the tree compares an integer. Round time fell
from 790 ms to 611 ms at one client process and from 458 ms to 254 ms at four.

## Plain echo (no fan-out)

Same client, a server that only echoes: 51,200 messages and 51,200 deliveries
per round.

| | 1 client process | 4 client processes | server CPU per message |
|---|---|---|---|
| Bun | 291,709 msg/s | 904,082 msg/s | 0.55 µs |
| nimony | **275,907 msg/s** | **538,336 msg/s** | 1.45 µs |

Level with Bun at one client process, 60% at four, on 2.6× Bun's CPU per
message. With 2000-byte messages (per-message cost spread over 133× more bytes)
nimony is ahead: 160,921 against 143,880 msg/s.

What is left per message is the runtime, not the socket: two `.passive` calls
per message and a UTF-8 check on the way in *and* on the way out (an echo
validates the same bytes twice).

## What is left

* A turn flushes its members one after another, and each flush waits for its
  own write. Overlapping those waits needs "submit without waiting" plus "wait
  for the drain"; the deferred-submit variant alone measured *worse*
  (1.33 M, 1.06 M syscalls) because the wait is what creates the batch.
* The per-message cost is ~2 µs and now dominates the server's CPU: one channel
  send, one event construction and one frame append per member. Batching the
  reader's lines into one event would cut the first two, and it needs a
  non-parking check on the reader (`buffered`) to know a batch is there.
* The channel hop per message: one ticket-lock round trip and a 24-byte copy.
* `publish` walks the topic path with a `substr` per segment; caching the node
  in the subscription would do.
