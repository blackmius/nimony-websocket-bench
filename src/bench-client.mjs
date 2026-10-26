// The same workload as Bun's bench/websocket-server chat-client.mjs, but with
// wall-clock timing per round instead of the 1 s counter: that counter is
// quantised to whole batches and saturates at "2 batches per second" for
// every server fast enough to finish two.
//
// A round is: every client sends MESSAGES messages, then waits until every
// client has received every echo. That is the same total work as the
// benchmark's own client; only the measurement differs.
const env = process.env;
const SERVER = env.SERVER || "ws://0.0.0.0:4001";
const CLIENTS = parseInt(env.CLIENTS_COUNT || "", 10) || 32;
const TOTAL_CLIENTS = parseInt(env.TOTAL_CLIENTS || "", 10) || CLIENTS;
const ROUNDS = parseInt(env.ROUNDS || "", 10) || 10;
const PER_CLIENT = parseInt(env.MESSAGES || "", 10) || 1600;

const MESSAGES_TO_SEND = Array.from({ length: 32 }, () => [
  "Hello World!", "Hello World! 1", "Hello World! 2", "Hello World! 3",
  "Hello World! 4", "Hello World! 5", "Hello World! 6", "Hello World! 7",
  "Hello World! 8", "Hello World! 9", "What is the meaning of life?",
  "where is the bathroom?", "zoo", "kangaroo", "erlang", "elixir", "bun",
  "mochi", "typescript", "javascript", "Hello World! 7", "Hello World! 8",
  "Hello World! 9", "What is the meaning of life?", "where is the bathroom?",
  "zoo", "kangaroo", "erlang", "elixir", "bun", "mochi", "typescript",
  "javascript", "Hello World! 7", "Hello World! 8", "Hello World! 9",
  "What is the meaning of life?", "Hello World! 7", "Hello World! 8",
  "Hello World! 9", "What is the meaning of life?", "where is the bathroom?",
  "zoo", "kangaroo", "erlang", "elixir", "bun", "mochi", "typescript",
  "javascript",
]).flat().slice(0, PER_CLIENT);

const NAMES = Array.from({ length: 50 }, (a, i) => [
  "Alice" + i, "Bob" + i, "Charlie" + i, "David" + i, "Eve" + i,
  "Frank" + i, "Grace" + i, "Heidi" + i, "Ivan" + i, "Judy" + i,
  "Karl" + i, "Linda" + i, "Mike" + i, "Nancy" + i, "Oscar" + i,
  "Peggy" + i, "Quentin" + i, "Ruth" + i, "Steve" + i, "Trudy" + i,
  "Ursula" + i, "Victor" + i, "Wendy" + i, "Xavier" + i, "Yvonne" + i,
  "Zach" + i,
]).flat().slice(0, CLIENTS);

const expected = CLIENTS * MESSAGES_TO_SEND.length * TOTAL_CLIENTS;
const clients = new Array(CLIENTS);
let received = 0;
let resolveRound = null;
let roundTarget = 0;

// With several client processes, a round only means the same thing to all of
// them if they start it together: one process's round-2 sends would otherwise
// be counted by a straggler as round-1 echoes, and the counts drift until a
// round never completes. The barrier is a directory of empty files, one per
// process per round, polled with a 1 ms sleep.
const BARRIER = env.BARRIER_DIR || "";
const PROC = parseInt(env.PROC_ID || "0", 10);
const NPROCS = parseInt(env.NPROCS || "1", 10);
const fs = BARRIER ? await import("node:fs") : null;
const sleepBuf = new Int32Array(new SharedArrayBuffer(4));
const nap = ms => Atomics.wait(sleepBuf, 0, 0, ms);

function barrier(round) {
  if (!fs) return;
  fs.writeFileSync(`${BARRIER}/${round}.${PROC}`, "");
  const deadline = Date.now() + 60000;
  for (;;) {
    const have = fs.readdirSync(BARRIER).filter(f => f.startsWith(round + ".")).length;
    if (have >= NPROCS) return;
    if (Date.now() > deadline) throw new Error(`barrier ${round}: ${have}/${NPROCS}`);
    nap(1);
  }
}

const connected = [];
for (let i = 0; i < CLIENTS; i++) {
  const ws = new WebSocket(`${SERVER}?name=${NAMES[i]}`);
  clients[i] = ws;
  connected.push(new Promise((resolve, reject) => {
    ws.onmessage = () => resolve();          // the server's "ready"
    ws.onerror = e => reject(new Error("connect failed: " + e.message));
  }));
}
await Promise.all(connected);
console.log(`${CLIENTS} clients connected, ${MESSAGES_TO_SEND.length} msgs each, ` +
            `${expected} echoes per round`);

for (let i = 0; i < CLIENTS; i++) {
  clients[i].onmessage = () => {
    received++;
    if (received === roundTarget) resolveRound();
  };
}

const rates = [];
for (let round = 0; round < ROUNDS; round++) {
  barrier(`r${round}`);
  received = 0;
  roundTarget = expected;
  const done = new Promise(resolve => { resolveRound = resolve; });
  const t0 = performance.now();
  for (let i = 0; i < CLIENTS; i++) {
    for (let j = 0; j < MESSAGES_TO_SEND.length; j++) {
      clients[i].send(MESSAGES_TO_SEND[j]);
    }
  }
  await done;
  const ms = performance.now() - t0;
  const rate = (expected * 1000) / ms;
  rates.push(rate);
  console.log(`round ${String(round + 1).padStart(2)}: ${ms.toFixed(1).padStart(8)} ms  ${rate.toFixed(0).padStart(9)} msg/s`);
}

rates.sort((a, b) => a - b);
const median = rates[Math.floor(rates.length / 2)];
console.log(JSON.stringify({ median: Math.round(median), rates: rates.map(Math.round) }));
process.exit(0);
