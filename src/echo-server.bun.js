// The plain echo server in Bun: every message goes back to the connection that
// sent it. The counterpart of `src/echoserver.nim`.
const port = process.env.PORT || 4001;

const server = Bun.serve({
  port: port,
  websocket: {
    message(ws, msg) {
      ws.send(msg);
    },
    perMessageDeflate: false,
  },
  fetch(req, server) {
    if (server.upgrade(req)) return;
    return new Response("Error");
  },
});

console.log(`echo on http://${server.hostname}:${port}/`);
