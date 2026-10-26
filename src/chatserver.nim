# A chat room over std/websocket's `Room`: the workload of Bun's
# bench/websocket-server.
#
# The room owns every connection's writer, so a published line costs one
# channel send and one buffer append per member, and each member is flushed
# once per turn — the shape Bun's server has. Compare `chatserver-conn.nim`,
# which gives every connection a writer chain of its own because the pair API
# has no fan-out of its own.

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

proc announce(room: Room) {.passive.} =
  ## What the Bun server does once the room is full: tell everybody, so the
  ## clients stop waiting for their first message and start sending.
  sleep 100
  try:
    room.publish(Topic, "ready")
  except ErrorCode:
    discard

proc chat(c: sink HttpConnection; room: Room) {.passive.} =
  if not c.next(): return
  let nm = nameOf(c.query)
  var counted = false
  try:
    var ws = upgradeWebSocket(c)
    var sub = room.join(ws, Topic)
    counted = true
    if atomicFetchAdd(joined, 1, moRelaxed) + 1 == clientsToWaitFor:
      submit(delay(announce(room)), -1)
    while true:
      var msg = ""
      let kind = sub.recv(msg)
      case kind
      of mkText, mkBinary:
        room.publish(Topic, nm & ": " & msg)
      of mkClose:
        break
      else:
        discard
    sub.close()
  except ErrorCode:
    discard
  # The room fills again for the next batch of clients, so the count is of the
  # clients connected now, not of the ones that ever connected.
  if counted: discard atomicFetchAdd(joined, -1, moRelaxed)

proc serve(room: Room; port: uint16) {.passive.} =
  var s = listenHttp(port, tags)
  s.serverName = "nimony-chat"
  stdout.write "listening on port " & $int(boundPort(s.fd)) & "\n"
  while true:
    let c = s.accept()
    if c.isClosed: break
    submit(delay(chat(c, room)), -1)

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
  try:
    let room = newRoom()
    submit(delay(serve(room, uint16(port))), 0)
  except ErrorCode:
    stdout.write "cannot start the room\n"
  while true: sleep 1000

main()

{.feature: "assumeSync".}  # the joined count is shared; atomics only
