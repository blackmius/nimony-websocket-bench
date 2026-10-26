# The same chat room as `chatserver.nim`, but with one hub chain that owns
# every connection's writer.
#
# `std/websocket` allows exactly one writer per connection, and a task that
# writes another connection's socket interleaves two frames. The server in
# `chatserver.nim` therefore gives every connection a writer chain of its own
# and publishes through one channel per connection: a message costs 32 channel
# sends, 32 wakeups and 32 tasks' worth of scheduling.
#
# Here the fan-out is one chain. A reader sends the line to the hub (one
# channel send), and the hub writes it into every connection's buffer with
# `flush = false`; when its inbox runs dry it flushes each connection once.
# A message then costs one channel send and 32 buffer appends, and the
# syscalls are one per connection per turn instead of one per delivery — the
# shape Bun's server has.

import std / [httpserver, websocket, socket, ioring, threadpool, atomics,
              ticketlocks, syncio, os, envvars, strutils, channels]

when defined(posix):
  proc cSignal(sig: cint; handler: pointer): pointer {.
    importc: "signal", header: "<signal.h>".}
  const SigPipe: cint = 13

proc ignoreSigPipe() =
  ## A peer that vanishes makes the next write fail with EPIPE, and the
  ## default action for SIGPIPE is to kill the process.
  discard cSignal(SigPipe, cast[pointer](1))   # SIG_IGN

const
  MaxConns = 512
    ## Slots in the connection table. A slot is free when its `Conn` is nil.
  InboxCapacity = 4096
    ## Lines the hub may have queued before a publisher parks. The batch the
    ## hub drains per turn is what decides how many frames share one flush.

type
  EvKind = enum evJoin, evLeave, evMsg, evPong
  Ev = object
    kind: EvKind
    slot: int
    text: string

  Conn = ref object
    ## One connection's writer, owned by the hub from the moment it joins.
    wr: WebSocketWriter
    slot: int

var
  tags = newHttpTags()
  regLock: TicketLock
  conns: array[MaxConns, nil Conn]
  inbox: Sender[Ev]
  joined: int
  clientsToWaitFor = 32

# --------------------------------------------------------------- the hub --

proc retire(active: var seq[Conn]; i: int) =
  ## Takes connection `i` out of the room and frees its slot, so a new
  ## connection can have it.
  let c = active[i]
  active.delete i
  acquire regLock
  if conns[c.slot] == c:
    conns[c.slot] = nil
    dec joined
  release regLock

proc hubLoop(rx: sink Receiver[Ev]) {.passive.} =
  ## The one chain that writes to sockets. Everything it writes is buffered
  ## per connection with `flush = false`; the flush happens when there is
  ## nothing left in the inbox, so one write carries the whole turn.
  var active: seq[Conn] = @[]
  var e = Ev()
  while true:
    try:
      if not rx.tryRecv(e):
        # The turn is over: what every connection was given goes out now.
        var i = 0
        while i < active.len:
          try:
            active[i].wr.flush()
            inc i
          except ErrorCode:
            active[i].wr.abort()
            retire(active, i)
        if not rx.recv(e): return
      case e.kind
      of evJoin:
        acquire regLock
        let c = conns[e.slot]
        release regLock
        if c != nil: active.add c
      of evMsg:
        var i = 0
        while i < active.len:
          try:
            active[i].wr.send(mkText, e.text, flush = false)
            inc i
          except ErrorCode:
            active[i].wr.abort()
            retire(active, i)
      of evPong:
        for c in active:
          if c.slot == e.slot:
            try:
              c.wr.send(mkPong, e.text, flush = false)
            except ErrorCode:
              discard
            break
      of evLeave:
        var i = 0
        while i < active.len and active[i].slot != e.slot: inc i
        if i < active.len:
          try:
            active[i].wr.close(1000)   # flushes what came before, then goodbye
          except ErrorCode:
            active[i].wr.abort()
          retire(active, i)
    except ErrorCode:
      discard

proc announce() {.passive.} =
  ## What the Bun server does once the room is full: tell everybody, so the
  ## clients stop waiting for their first message and start sending.
  sleep 100
  try:
    discard inbox.send Ev(kind: evMsg, text: "ready")
  except ErrorCode:
    discard

# ------------------------------------------------------ one connection --

proc nameOf(query: string): string =
  const Prefix = "name="
  if query.len > Prefix.len and query.startsWith(Prefix):
    result = query.substr(Prefix.len)
  else:
    result = "anon"

proc join(wr: sink WebSocketWriter): int =
  ## A slot for this connection's writer, and the writer in it. `-1` when the
  ## table is full.
  result = -1
  acquire regLock
  for i in 0 ..< MaxConns:
    if conns[i] == nil:
      conns[i] = Conn(wr: move wr, slot: i)
      inc joined
      result = i
      break
  release regLock

proc chat(c: sink HttpConnection) {.passive.} =
  if not c.next(): return
  let nm = nameOf(c.query)
  var slot = -1
  try:
    var ws = upgradeWebSocket(c)
    var rd = move ws.reader
    slot = join(move ws.writer)
    if slot < 0:
      rd.close()
      return
    discard inbox.send Ev(kind: evJoin, slot: slot)
    if joined == clientsToWaitFor: submit(delay(announce()), -1)
    while true:
      var msg = ""
      let kind = rd.recv(msg)
      case kind
      of mkText, mkBinary:
        discard inbox.send Ev(kind: evMsg, text: nm & ": " & msg)
      of mkPing:
        discard inbox.send Ev(kind: evPong, slot: slot, text: msg)
      of mkPong:
        discard
      of mkClose:
        break
    rd.close()
  except ErrorCode:
    discard
  if slot >= 0:
    try:
      discard inbox.send Ev(kind: evLeave, slot: slot)
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
  var (rx, tx) = channel[Ev](InboxCapacity)
  inbox = tx
  submit(delay(hubLoop(rx)), 0)
  submit(delay(serve(uint16(port))), 1)
  while true: sleep 1000

main()

{.feature: "assumeSync".}  # the connection table is shared, guarded by regLock
