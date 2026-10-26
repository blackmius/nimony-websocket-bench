# What improved

`std/websocket`'s write path and a new `Room` for fan-out, measured on Bun's
[`bench/websocket-server`](https://github.com/oven-sh/bun/tree/main/bench/websocket-server)
workload: 32 clients, every message echoed to all of them, one round =
51,200 publishes and 1,638,400 deliveries. 4-core aarch64, `nimony c
-d:release`, Bun 1.4.4. Reproduce with `scripts/run-interleaved.sh`: the box is
shared and drifts by ~10%, so Bun and nimony are measured alternately and the
medians of 3 repetitions are reported. A 3% difference is not a result.

## Headline

| | before | after | Bun 1.4.4 |
|---|---|---|---|
| deliveries/s, 1 client process | 927,248 | **2,466,097** | 2,407,612 |
| deliveries/s, 4 client processes | 824,417 | **7,457,286** | 7,331,348 |
| server CPU per round, 1 process | 4.75 s | 0.198 s | 0.108 s |
| `io_uring_enter` per round | 1,478,997 | **3,558** | 49,765 `sendto` |

2.7× more throughput at one client process and 9.0× at four, ahead of Bun at
both splits (+2.4% and +1.7%), on ~1.4× Bun's server CPU instead of 15×.

The runtime underneath was part of the work: the ring's op queue and the pool's
task queue both took a `SysLock` per operation. They are now a same-thread ring
(the owner is the only producer *and* the only consumer of its lane) and a set
of Chase-Lev work-stealing deques, which is **−42% instructions per echoed
message** (6,497 → 3,736, callgrind) and removes the mutexes from the profile.

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
| Bun | 251,697 msg/s | 1,038,679 msg/s | 0.80 µs |
| nimony | **297,445 msg/s** | **1,026,582 msg/s** | 1.10 µs |

Ahead at one client process (+18%), level at four (−1.2%), on 1.4× Bun's CPU
per message (it was 2.6×). With 2000-byte messages (per-message cost spread over
133× more bytes) nimony is ahead too: 147,904 against 133,921 msg/s.

**The four-process row was 57% of Bun until `TCP_NODELAY` was set on accept.**
The kernel was holding each small write until the previous one was
acknowledged, so every reply cost an extra round trip — invisible in CPU and in
syscall counts, visible only as a latency that did not fall with concurrency.
One ring op per connection fixed it: 676k → 1.03M messages/s.

Trampolining a chain inline (running a continuation's next steps on the same
worker instead of re-queueing them) cuts the echo's CPU by 12% and its
throughput by 13%: a worker cannot poll its own io_uring lane while it runs, so
every deferred poll is deferred latency. Reverted.

## Many connections

`scripts/run-scale.sh`: N connections, each ping-ponging back to back, 8 s,
medians of 2 runs, 4 client processes.

| connections | Bun rate | nimony rate | ratio | Bun p99 | nimony p99 |
|---|---|---|---|---|---|
| 32 | 170,303 | 137,394 | 81% | 480 µs | 638 µs |
| 128 | 357,543 | 260,586 | 73% | 960 µs | 2,500 µs |
| 512 | 400,202 | 287,716 | 71% | 4,307 µs | 7,015 µs |
| 2048 | 315,491 | 208,598 | 66% | 14,524 µs | 22,768 µs |

Every connection is held (2048/2048, no errors) by both. nimony's median
latency is comparable or better, its tail is ~1.6× worse, and it spends 1.6–1.8×
Bun's CPU. At a *fixed* offered rate the two are level on the median and nimony
is better at p99 (3.2 ms against 4.4 ms at 51,200 msg/s offered) — that is the
thread pool's trade: twice the CPU, three cores of headroom.

What Bun wins in the many-connection case is syscall batching: one `epoll_wait`
collects every ready socket, one `sendto` carries ~32 replies, while the ring
does ~3 `io_uring_enter` per burst of ~19 messages.

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
