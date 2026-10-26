# A chat room over std/websocket's `Room`: the workload of Bun's
# bench/websocket-server.
#
# A connection joins with `ws.subscribe` and fans out with `ws.publish`, so the
# handler never leaves the pair API. The room owns the writers, so a published
# line costs one channel send and one buffer append per member, and each member
# is flushed once per turn — the shape Bun's server has. Compare
# `chatserver-conn.nim`, which gives every connection a writer chain of its own
# because it has no fan-out of its own to use.

import std / [httpserver, websocket, socket, ioring, threadpool, atomics,
              syncio, os, envvars, strutils]

when defined(posix):
  proc cSignal(sig: cint; handler: pointer): pointer {.
    importc: "signal", header: "<signal.h>".}
  const SigPipe: cint = 13

proc ignoreSigPipe() =
  ## A peer that vanishes makes the next write fail with EPIPE, and the
  ## default action for SIGPIPE is to kill the process: one client closing
  ## its tab would take the server down.
  discard cSignal(SigPipe, cast[pointer](1))   # SIG_IGN

const Topic = "room"

# With -d:perSender every connection gets a topic of its own, so a publish has
# exactly one subscriber: the same number of messages and channel sends as the
# real room, 32× fewer frame deliveries. It is how the per-message cost is
# measured apart from the per-delivery cost.
when defined(perSender):
  const OwnTopic = true
else:
  const OwnTopic = false

var
  tags = newHttpTags()
  joined: int
  clientsToWaitFor = 32

proc nameOf(query: string): string =
  ## `?name=Alice0`, which is what the client puts on the handshake.
  const Prefix = "name="
  if query.len > Prefix.len and query.startsWith(Prefix):
    result = query.substr(Prefix.len)
  else:
    result = "anon"

proc announce() {.passive.} =
  ## What the Bun server does once the room is full: tell everybody, so the
  ## clients stop waiting for their first message and start sending.
  sleep 100
  try:
    when defined(perSender): discard
    else: defaultRoom().publish(Topic, "ready")
  except ErrorCode:
    discard

proc chat(c: sink HttpConnection) {.passive.} =
  if not c.next(): return
  let nm = nameOf(c.query)
  var counted = false
  try:
    var ws = upgradeWebSocket(c)
    if OwnTopic: ws.subscribe(Topic & "/" & nm)
    else: ws.subscribe(Topic)
    counted = true
    if atomicFetchAdd(joined, 1, moRelaxed) + 1 == clientsToWaitFor:
      submit(delay(announce()), -1)
    while true:
      var msg = ""
      let kind = ws.recv(msg)
      case kind
      of mkText, mkBinary:
        if OwnTopic: ws.publish(Topic & "/" & nm, nm & ": " & msg)
        else: ws.publish(Topic, nm & ": " & msg)
      of mkClose:
        break
      else:
        discard
    ws.close()
  except ErrorCode:
    discard
  # The room fills again for the next batch of clients, so the count is of the
  # clients connected now, not of the ones that ever connected.
  if counted: discard atomicFetchAdd(joined, -1, moRelaxed)

proc serve(port: uint16) {.passive.} =
  var s = listenHttp(port, tags)
  s.serverName = "nimony-chat"
  stdout.write "listening on port " & $int(boundPort(s.fd)) & "\n"
  while true:
    let c = s.accept()
    if c.isClosed: break
    submit(delay(chat(c)), -1)

proc envInt(key: string; fallback: int): int =
  try:
    result = parseInt(getEnv(key, $fallback))
  except ErrorCode:
    result = fallback

proc main =
  ignoreSigPipe()
  initIoRing()
  let port = envInt("PORT", 4001)
  clientsToWaitFor = envInt("CLIENTS_COUNT", 32)
  submit(delay(serve(uint16(port))), 0)
  while true: sleep 1000

main()

{.feature: "assumeSync".}  # the joined count is shared; atomics only
