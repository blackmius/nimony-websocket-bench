# Connection holder, raw socket edition: opens CONNS TCP connections, does the
# WebSocket handshake by hand, sends one masked text frame, reads the echo,
# then parks on a read and holds the connection open.
#
# This exists because the *client* must not be the limit. `hold-client` goes
# through `std/websocket` like a real application would, and that costs ~32 KB
# per connection — a driver for a few thousand connections, not for a hundred
# thousand. Here a connection is one socket, one handshake and one parked
# chain: a couple of kilobytes.
#
#   CONNS=32768 HOST=127.0.0.1 PORT=4001 DURATION_S=30 ./bin/raw-hold-client
#
# The frame helpers are the library's own (`frameHeader`, `applyMask`), so the
# bytes on the wire are the same as `std/websocket` would produce.

import std / [socket, ioring, threadpool, syncio, os, envvars, strutils,
              atomics, websocket]

{.feature: "assumeSync".}

var
  opened, echoed, failed: int

proc envInt(key: string; fallback: int): int =
  try:
    result = parseInt(getEnv(key, $fallback))
  except ErrorCode:
    result = fallback

proc hold(host: string; port: uint16) {.passive.} =
  try:
    var s = connect(host, port, afterMs(30000))
    # The upgrade, by hand. `fill` is the read that returns as soon as
    # *something* arrived (`read` fills the whole buffer, which a 150-byte head
    # never does); `peek` looks at it, `take` consumes it.
    const key = "dGhlIHNhbXBsZSBub25jZQ=="
    s.write "GET / HTTP/1.1\r\nHost: bench\r\nUpgrade: websocket\r\n" &
            "Connection: Upgrade\r\nSec-WebSocket-Key: " & key &
            "\r\nSec-WebSocket-Version: 13\r\n\r\n"
    var headLen = -1
    while headLen < 0:
      if s.fill(afterMs(30000)) == 0: break
      let seen = s.peek()
      var i = 0
      while i + 3 < seen.len and headLen < 0:
        if seen[i] == '\r' and seen[i+1] == '\n' and seen[i+2] == '\r' and
           seen[i+3] == '\n':
          headLen = i + 4
        inc i
    if headLen < 12:
      discard atomicFetchAdd(failed, 1)
      s.close()
      return
    var head = newString(headLen)
    discard s.take(head, headLen)
    if not (head[9] == '1' and head[10] == '0' and head[11] == '1'):
      discard atomicFetchAdd(failed, 1)
      s.close()
      return
    discard atomicFetchAdd(opened, 1)
    # One masked text frame, and the echo that proves the pipeline works.
    let mask = [char('a'), 'b', 'c', 'd']
    let text = "hello"
    var payload = newString(text.len)
    for i in 0 ..< text.len:
      payload[i] = char(ord(text[i]) xor ord(mask[i and 3]))
    s.write frameHeader(wsoText, payload.len, true, mask)
    s.write payload
    if s.fill(afterMs(30000)) > 0:
      discard atomicFetchAdd(echoed, 1)
    # Park with no deadline: the read never completes, so the connection is
    # never closed and the server sees a peer with nothing to say.
    discard s.fill(never)
  except ErrorCode:
    discard atomicFetchAdd(failed, 1)


proc main =
  let host = getEnv("HOST", "127.0.0.1")
  let port = uint16(envInt("PORT", 4001))
  let conns = envInt("CONNS", 1024)
  let durationS = envInt("DURATION_S", 20)
  initIoRing()
  for i in 0 ..< conns:
    submit(delay(hold(host, port)), -1)
  var elapsed = 0
  while elapsed < durationS:
    sleep 1000
    inc elapsed
    stderr.write "t=" & $elapsed & " opened " & $atomicLoad(opened) &
                 " echoed " & $atomicLoad(echoed) & " failed " & $atomicLoad(failed) & "\n"
  stdout.write "{\"conns\": " & $conns & ", \"opened\": " & $atomicLoad(opened) &
               ", \"echoed\": " & $atomicLoad(echoed) &
               ", \"failed\": " & $atomicLoad(failed) & "}\n"

main()
