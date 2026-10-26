# The plain echo server: every message a connection sends goes back to it and
# nowhere else. No room, no topics, no fan-out — this is what the per-message
# cost of `std/websocket` is on its own, and what Bun's `ws.send` is on its own.
#
# The same client drives it (`src/bench-client.mjs` with READY=0 and
# TOTAL_CLIENTS=1, so it counts its own echoes).

import std / [httpserver, websocket, socket, ioring, threadpool, syncio, os,
              envvars, strutils]

{.feature: "assumeSync".}  # `tags` is read by every handler and never written

when defined(posix):
  proc cSignal(sig: cint; handler: pointer): pointer {.
    importc: "signal", header: "<signal.h>".}
  const SigPipe: cint = 13

proc ignoreSigPipe() =
  ## A peer that vanishes makes the next write fail with EPIPE, and the
  ## default action for SIGPIPE is to kill the process.
  discard cSignal(SigPipe, cast[pointer](1))   # SIG_IGN

var tags = newHttpTags()

proc echo(c: sink HttpConnection) {.passive.} =
  if not c.next(): return
  try:
    var ws = upgradeWebSocket(c)
    while true:
      var msg = ""
      let kind = ws.recv(msg)
      case kind
      of mkText, mkBinary:
        # `flush = false`: the reply joins the buffer, and `recv` flushes it
        # when the connection has nothing more buffered — one write for a
        # burst of echoes instead of one per message.
        ws.send(kind, msg, flush = false)
      of mkClose:
        break
      else:
        discard
    ws.close()
  except ErrorCode:
    discard

proc serve(port: uint16) {.passive.} =
  var s = listenHttp(port, tags)
  s.serverName = "nimony-echo"
  stdout.write "listening on port " & $int(boundPort(s.fd)) & "\n"
  while true:
    let c = s.accept()
    if c.isClosed: break
    submit(delay(echo(c)), -1)

proc envInt(key: string; fallback: int): int =
  try:
    result = parseInt(getEnv(key, $fallback))
  except ErrorCode:
    result = fallback

proc main =
  ignoreSigPipe()
  initIoRing()
  submit(delay(serve(uint16(envInt("PORT", 4001)))), 0)
  while true: sleep 1000

main()
