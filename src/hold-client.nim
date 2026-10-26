# Connection holder: opens CONNS WebSockets, does one echo on each, then holds
# them open and silent. This is the client for the "how many clients can a
# server hold" question, and it is deliberately the *same* client for every
# server.
#
# It is written in Nim rather than Node because the driver must not be the
# limit: a Node WebSocket costs ~30 KB per connection, which caps the whole
# experiment at a few tens of thousands of connections no matter what the
# server can do.
#
#   CONNS=8192 URL=ws://127.0.0.1:4001/ DURATION_S=20 ./bin/hold-client
#
# Prints one JSON line at the end and a progress line every second on stderr.

import std / [websocket, ioring, threadpool, syncio, os, envvars, strutils,
              atomics]

{.feature: "assumeSync".}

var
  opened, echoed, failed: int
  holdForever = 0

proc envInt(key: string; fallback: int): int =
  try:
    result = parseInt(getEnv(key, $fallback))
  except ErrorCode:
    result = fallback

proc hold(url: string) {.passive.} =
  ## One connection: handshake, one round trip, then park on a read forever.
  ## Parking is what keeps the connection open — the server sees a peer that
  ## has nothing to say, which is exactly the state being measured.
  try:
    var ws = connectWebSocket(url, idleMs = 0)
    discard atomicFetchAdd(opened, 1)
    ws.send(mkText, "hello")
    var msg = ""
    let kind = ws.recv(msg)
    if kind == mkText or kind == mkBinary:
      discard atomicFetchAdd(echoed, 1)
    # Park with no deadline: the read never completes, so the chain never
    # returns, so the connection is never closed.
    discard ws.recv(msg)
  except ErrorCode:
    discard atomicFetchAdd(failed, 1)

proc main =
  let url = getEnv("URL", "ws://127.0.0.1:4001/")
  let conns = envInt("CONNS", 1024)
  let durationS = envInt("DURATION_S", 20)
  initIoRing()
  for i in 0 ..< conns:
    submit(delay(hold(url)), -1)
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
