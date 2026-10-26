// Scalability client: hold CONNS connections open and measure what the server
// does with them.
//
// Two modes:
//
//   MODE=max    each connection sends the next message as soon as the previous
//               echo arrives (back-to-back ping-pong). The aggregate rate is
//               what the server can push at this concurrency, and the RTT is
//               the queueing delay at that rate.
//   MODE=paced  every connection sends once per INTERVAL_MS, one message in
//               flight. The offered rate is fixed and independent of the
//               server, so the RTT is what a client sees at that load — the
//               number that says whether the server is still keeping up.
//
// This is deliberately not the throughput benchmark: that one floods 1600
// messages per connection and measures how long a round takes. This one asks
// how many connections a server can hold, and what each of them gets.
//
// Output is one JSON line plus, optionally, the raw RTT samples in a file, so
// several processes can be merged into one set of percentiles.
import * as fs from "node:fs";

const env = process.env;
const SERVER = env.SERVER || "ws://0.0.0.0:4001";
const CONNS = parseInt(env.CONNS || "", 10) || 100;
const MODE = env.MODE || "max";
const INTERVAL_MS = parseInt(env.INTERVAL_MS || "", 10) || 100;
const DURATION_S = parseFloat(env.DURATION_S || "") || 10;
const MSG_SIZE = parseInt(env.MSG_SIZE || "", 10) || 0;
const SAMPLES = env.SAMPLES || "";     // where to write the raw RTTs (us)
const CONNECT_TIMEOUT_MS = 20000;

const base = "Hello World!";
const MSG = MSG_SIZE > base.length ? base + "x".repeat(MSG_SIZE - base.length) : base;

const socks = new Array(CONNS);
let sent = 0, recv = 0, errors = 0, opened = 0;
const rtts = [];
const t0 = process.hrtime.bigint();
let running = true;

const nowUs = () => Number(process.hrtime.bigint() - t0) / 1000;

function sendOn(i) {
  if (!running) return;
  const s = socks[i];
  if (s === undefined || s.readyState !== 1) return;
  s._sentAt = process.hrtime.bigint();
  s.send(MSG);
  sent++;
}

for (let i = 0; i < CONNS; i++) {
  const ws = new WebSocket(SERVER);
  ws._sentAt = 0n;
  socks[i] = ws;
  ws.onopen = () => {
    opened++;
    if (MODE === "max") sendOn(i);
  };
  ws.onmessage = () => {
    recv++;
    if (ws._sentAt !== 0n) {
      rtts.push(Number(process.hrtime.bigint() - ws._sentAt) / 1000);
      ws._sentAt = 0n;
    }
    if (MODE === "max") sendOn(i);
  };
  ws.onerror = () => { errors++; };
  ws.onclose = () => { if (running) errors++; };
}

// A paced run is driven by one timer for the whole process rather than one per
// socket: with a few thousand connections a timer each costs more than the
// load it generates.
let ticker = null;
if (MODE === "paced") {
  ticker = setInterval(() => {
    for (let i = 0; i < CONNS; i++) sendOn(i);
  }, INTERVAL_MS);
}

const wallStart = Date.now();
const check = setInterval(() => {
  if (Date.now() - wallStart > CONNECT_TIMEOUT_MS && opened === 0) {
    console.error(`no connection opened within ${CONNECT_TIMEOUT_MS} ms`);
    process.exit(2);
  }
}, 200);

setTimeout(() => {
  running = false;
  if (ticker !== null) clearInterval(ticker);
  clearInterval(check);
  const elapsed = nowUs() / 1e6;
  rtts.sort((a, b) => a - b);
  const q = p => rtts.length
    ? +rtts[Math.min(rtts.length - 1, Math.floor(rtts.length * p))].toFixed(1)
    : 0;
  if (SAMPLES) fs.writeFileSync(SAMPLES, rtts.join("\n"));
  console.log(JSON.stringify({
    conns: CONNS, mode: MODE, opened, errors, sent, recv,
    seconds: +elapsed.toFixed(2),
    rate: Math.round(recv / elapsed),
    samples: rtts.length,
    p50us: q(0.5), p90us: q(0.9), p99us: q(0.99),
    maxus: rtts.length ? +rtts[rtts.length - 1].toFixed(1) : 0,
  }));
  process.exit(0);
}, DURATION_S * 1000);
