// Raw TCP connection holder: opens CONNS sockets, keeps them open, sends
// nothing. Used to measure what a server spends on a *connected* peer before
// any protocol work happens — a WebSocket client costs ~30 KB per connection
// in Node, which caps how many the client can hold.
//
//   CONNS=8192 DURATION_S=20 node src/conn-client.mjs
import * as net from "node:net";

const env = process.env;
const HOST = env.HOST || "127.0.0.1";
const PORT = parseInt(env.PORT || "", 10) || 4001;
const CONNS = parseInt(env.CONNS || "", 10) || 100;
const DURATION_S = parseFloat(env.DURATION_S || "") || 10;

const socks = new Array(CONNS);
let opened = 0, errors = 0;

for (let i = 0; i < CONNS; i++) {
  const s = net.connect({ host: HOST, port: PORT });
  s.setNoDelay(true);
  s.on("connect", () => { opened++; });
  s.on("error", () => { errors++; });
  s.on("close", () => {});
  socks[i] = s;
}

setTimeout(() => {
  console.log(JSON.stringify({ conns: CONNS, opened, errors }));
  process.exit(0);
}, DURATION_S * 1000);
