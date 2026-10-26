# The floor: a server that accepts connections and parks them, doing no
# protocol work at all. Used to answer "what does a *connection* cost?" before
# any WebSocket state exists — the difference from the echo server's number is
# what the upgrade and the echo chain add.
#
#   ./bin/holdserver
#
# Every connection parks in `next()` waiting for a request that never comes,
# with a deadline long enough that nothing expires during a measurement.

import std / [httpserver, streamio, ioring, threadpool, syncio, os, envvars,
              strutils]

{.feature: "assumeSync".}

var tags = newHttpTags()

proc hold(c: sink HttpConnection) {.passive.} =
  # The connection's streams, taken over so that the read below is ours: the
  # HTTP layer's request-head read has a deadline meant for a request, and a
  # connection held for measurement must not be closed by it. One hour is
  # longer than any run.
  var (rd, wr) = c.takeStreams()
  var buf = newString(64)
  try:
    discard rd.read(toOpenArray(buf, 0, buf.len - 1))
  except ErrorCode:
    discard

proc serve(port: uint16) {.passive.} =
  var s = listenHttp(port, tags)
  stdout.write "holding on port " & $int(boundPort(s.fd)) & "\n"
  while true:
    let c = s.accept()
    if c.isClosed: break
    submit(delay(hold(c)), -1)

proc envInt(key: string; fallback: int): int =
  try:
    result = parseInt(getEnv(key, $fallback))
  except ErrorCode:
    result = fallback

proc main =
               " Reader " & $sizeof(Reader) & " Writer " & $sizeof(Writer) & "\n"
  initIoRing()
  submit(delay(serve(uint16(envInt("PORT", 4001)))), 0)
  let exitAfter = envInt("EXIT_AFTER_S", 0)
  var elapsed = 0
  while true:
    sleep 1000
    inc elapsed
    # `occupied` is the live heap: what the allocator has handed out and not
    # got back. Comparing it with RSS separates "our objects and frames" from
    # "everything else the process maps".
    when defined(allocStats):
      stderr.write "t=" & $elapsed & " occupied " & $(getOccupiedMem() div 1024) & " KB\n"
      for i in 0 ..< 128:
        if gStatCount[i] > 0:
          stderr.write "  ~" & $(i * 64) & " B: " & $gStatCount[i] & " blocks, " &
                       $(gStatBytes[i] div 1024) & " KB\n"
    if exitAfter > 0 and elapsed >= exitAfter: break

main()
