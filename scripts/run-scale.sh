#!/bin/bash
# Scalability: how many concurrent connections does a server hold, and what
# does each of them get? Two servers, the same client, alternating.
#
#   scripts/run-scale.sh                     # the default sweep, MODE=max
#   MODE=paced DURATION=10 scripts/run-scale.sh
#   CONNS_LIST="128 512" scripts/run-scale.sh
#
# MODE=max:    each connection ping-pongs back to back — the rate the server
#              can push at that concurrency, and the queueing delay at it.
# MODE=paced:  each connection sends once per INTERVAL_MS — the latency a
#              client sees at a fixed offered load.
#
# Connection counts are per run, split over PROCS client processes. Percentiles
# are computed over the merged RTT samples of every process, not averaged.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export PATH="$HOME/.bun/bin:$PATH"

CONNS_LIST=${CONNS_LIST:-"32 128 512 2048"}
MODE=${MODE:-max}
DURATION=${DURATION:-8}
PROCS=${PROCS:-4}
INTERVAL_MS=${INTERVAL_MS:-100}
REPS=${REPS:-2}

out="$ROOT/results/scale"
mkdir -p "$out"

kill_server() {
  local pids
  pids=$(ss -ltnp 2>/dev/null | grep ':4001' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
  for p in $pids; do kill -9 "$p" 2>/dev/null; done
  sleep 0.3
}

# one measurement: tag total_conns server-cmd...
measure() {
  local tag=$1 total=$2; shift 2
  local dir="$out/$tag"; rm -rf "$dir"; mkdir -p "$dir"
  kill_server
  setsid "$@" > "$dir/server.log" 2>&1 &
  sleep 2
  local srv per pids="" p
  srv=$(ss -ltnp 2>/dev/null | grep ':4001' | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1)
  if [ -z "$srv" ]; then echo "  $tag: server did not start" >&2; cat "$dir/server.log" >&2; return 1; fi
  # One client process per 64 connections, up to PROCS: a single Node process
  # is a fine driver for 64 sockets and a bad one for 512.
  local np=$(( (total + 63) / 64 ))
  [ "$np" -lt 1 ] && np=1
  [ "$np" -gt "$PROCS" ] && np=$PROCS
  per=$(( (total + np - 1) / np ))
  local c0 c1
  c0=$(cat /proc/$srv/task/*/stat 2>/dev/null | awk '{s+=$14+$15} END {print s+0}')
  for i in $(seq 0 $((np - 1))); do
    CONNS="$per" MODE="$MODE" DURATION_S="$DURATION" INTERVAL_MS="$INTERVAL_MS" \
      SAMPLES="$dir/p$i.rtt" node "$ROOT/src/scale-client.mjs" > "$dir/p$i.json" 2> "$dir/p$i.err" &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
  c1=$(cat /proc/$srv/task/*/stat 2>/dev/null | awk '{s+=$14+$15} END {print s+0}')
  kill_server

  python3 "$ROOT/scripts/scale.py" "$dir/rtt.json" "$dir"/p*.rtt
  python3 - "$tag" "$total" "$dir" "$c0" "$c1" "$DURATION" <<'PY'
import json, sys, glob
tag, total, d, c0, c1, dur = sys.argv[1:7]
recv = opened = errors = 0
for f in glob.glob(d + "/p*.json"):
    try:
        j = json.load(open(f))
    except Exception:
        continue
    recv += j.get("recv", 0); opened += j.get("opened", 0); errors += j.get("errors", 0)
rtt = json.load(open(d + "/rtt.json"))
cpu = (int(c1) - int(c0)) / 100.0
print(f"RESULT\t{tag}\t{total}\t{opened}\t{recv / float(dur):.0f}\t"
      f"{rtt['p50us']}\t{rtt['p99us']}\t{errors}\t{cpu / float(dur):.2f}")
PY
}

echo "mode=$MODE duration=${DURATION}s procs=$PROCS reps=$REPS"
echo -e "server\tconns\topened\trate\tp50us\tp99us\terrors\tcpu"
for conns in $CONNS_LIST; do
  for ((r = 0; r < REPS; r++)); do
    measure "$MODE-bun-$conns-r$r" "$conns" bun src/echo-server.bun.js | grep '^RESULT' | cut -f2-
    measure "$MODE-nimony-$conns-r$r" "$conns" ./bin/echoserver | grep '^RESULT' | cut -f2-
  done
done
