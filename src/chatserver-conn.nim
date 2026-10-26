# A chat room over std/websocket: the workload of Bun's
# bench/websocket-server, so the same client script can drive both.
#
# One connection is two chains. The reader owns the receive half and the
# writer owns the send half, because a connection has one writer and the room
# is written to from other connections: a reader that published by writing
# the peer's socket itself would interleave two frames in the middle of each
# other (see the note in std/websocket).
#
# Publishing therefore goes through per-connection outboxes: the reader of a
# connection that received a message drops one copy of the line into every
# subscriber's channel, and each subscriber's own writer chain puts it on its
# own wire. The channels are the backpressure — a slow peer parks the
# publisher instead of growing a queue nobody reads.

import std / [httpserver, websocket, socket, ioring, threadpool, atomics,
              ticketlocks, syncio, os, envvars, strutils, channels]

when defined(posix):
  proc cSignal(sig: cint; handler: pointer): pointer {.
    importc: "signal", header: "<signal.h>".}
  const SigPipe: cint = 13

proc ignoreSigPipe() =
  ## A peer that vanishes makes the next write fail with EPIPE, and on a POSIX
  ## system the default action for SIGPIPE is to kill the process: one client
  ## closing its tab would take the server down. Windows has no SIGPIPE; a
  ## write to a closed socket is an error there. The runtime installs no handler of
  ## its own and the write path does not pass MSG_NOSIGNAL, so this is the
  ## server's to do.
  when defined(posix):
    discard cSignal(SigPipe, cast[pointer](1))   # SIG_IGN

const
  MaxOutbox = 256
    ## Messages one connection may have queued before the publisher parks.
    ## The client sends a whole batch at once, so this absorbs the burst.

type
  OutKind = enum okText, okClose, okPong
  OutMsg = object
    kind: OutKind
    text: string

  Sub = object
    id: int
    outbox: Sender[OutMsg]

var
  tags = newHttpTags()
  regLock: TicketLock
  subs: seq[Sub]
  nextId: int
  joined: int
  clientsToWaitFor = 32

# ------------------------------------------------------------- the room --

proc publish(text: string) {.passive, raises.} =
  ## One line to every subscriber. The registry is copied under the lock and
  ## written to outside it: `send` parks when an outbox is full, and a task
  ## parked while holding the registry lock would keep every new connection
  ## out of the room.
  var snap: seq[Sub] = @[]
  acquire regLock
  snap = subs
  release regLock
  for s in snap:
    # `false` is a subscriber that left between the copy and this line.
    discard s.outbox.send OutMsg(kind: okText, text: text)

proc announce() {.passive.} =
  ## What the Bun server does once the room is full: tell everybody, so the
  ## clients stop waiting for their first message and start sending.
  sleep 100
  try:
    publish "ready"
  except ErrorCode:
    discard

proc join(outbox: Sender[OutMsg]): (int, bool) =
  ## A new subscriber, and whether it was the one that filled the room.
  acquire regLock
  result = (nextId, false)
  inc nextId
  subs.add Sub(id: result[0], outbox: outbox)
  inc joined
  result[1] = joined == clientsToWaitFor
  release regLock

proc leave(id: int) =
  acquire regLock
  for i in 0 ..< subs.len:
    if subs[i].id == id:
      subs.delete i
      break
  dec joined
  release regLock

# ------------------------------------------------------ one connection --

proc writerLoop(rx: sink Receiver[OutMsg]; wr: sink WebSocketWriter) {.passive.} =
  ## The only place this connection's socket is written to.
  ##
  ## Frames go out with `flush = false`, and the flush happens when the outbox
  ## runs dry, just before the chain parks on it: one syscall for a burst of
  ## frames instead of one per frame. The wait for that syscall is also what
  ## lets the next burst form — a writer that never waits keeps pace with the
  ## publisher and would write one frame per op.
  var m = OutMsg()
  while true:
    try:
      if not rx.tryRecv(m):
        # Nothing left to write: what is buffered is owed to the peer now.
        wr.flush()
        if not rx.recv(m): return
      case m.kind
      of okText: wr.send(mkText, m.text, flush = false)
      of okPong: wr.send(mkPong, m.text, flush = false)
      of okClose:
        wr.close(1000)          # flushes what came before it, then the close
        return
    except ErrorCode:
      wr.abort()
      return

proc nameOf(query: string): string =
  ## `?name=Alice0`, which is what the client puts on the handshake.
  const Prefix = "name="
  if query.len > Prefix.len and query.startsWith(Prefix):
    result = query.substr(Prefix.len)
  else:
    result = "anon"

proc chat(c: sink HttpConnection) {.passive.} =
  if not c.next(): return
  var id = -1
  var tx = Sender[OutMsg]()
  try:
    let nm = nameOf(c.query)
    var ws = upgradeWebSocket(c)
    var rd = move ws.reader
    var wr = move ws.writer
    var (rx, tx2) = channel[OutMsg](MaxOutbox)
    tx = tx2
    let (i, full) = join(tx2)
    id = i
    submit(delay(writerLoop(rx, wr)), -1)
    if full: submit(delay(announce()), -1)
    while true:
      var msg = ""
      let kind = rd.recv(msg)
      case kind
      of mkText, mkBinary:
        publish nm & ": " & msg
      of mkPing:
        discard tx.send OutMsg(kind: okPong, text: msg)
      of mkPong:
        discard
      of mkClose:
        break
    rd.close()
  except ErrorCode:
    discard
  if id >= 0:
    leave(id)
    # The outbox is dropped from the registry, but this chain still holds a
    # sender: the close is the last thing the writer chain is told, and it is
    # told it even when the peer left without a goodbye.
    try:
      discard tx.send OutMsg(kind: okClose, text: "")
    except ErrorCode:
      discard

# ------------------------------------------------------------ the server --

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

{.feature: "assumeSync".}  # the room is shared state, guarded by regLock
