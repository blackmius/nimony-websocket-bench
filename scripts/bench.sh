#!/bin/bash
# One measurement: start a server, drive it with N client processes, report.
#
#   scripts/bench.sh <tag> <nprocs> <clients-per-proc> <server-cmd...>
#
#   scripts/bench.sh bun-1x32    1 32 bun vendor/bun-websocket-server/chat-server.bun.js
#   scripts/bench.sh nimony-1x32 1 32 ./bin/chatserver-conn
#
# Relative paths in <server-cmd> are resolved from the repository root.
# TOTAL_CLIENTS_OVERRIDE and READY are passed to the client: an echo server
# (one recipient per message) wants TOTAL_CLIENTS_OVERRIDE=1 READY=0.
# Raw logs land in results/<tag>/; the summary is appended to its summary.txt.
# ROUNDS (default 8) is the number of measured rounds per client process.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

tag="$1"; shift
nprocs="$1"; shift
per="$1"; shift
out="$ROOT/results/$tag"
rm -rf "$out"; mkdir -p "$out"

setsid "$@" > "$out/server.log" 2>&1 &
srv=$!
sleep 2
if ! kill -0 "$srv" 2>/dev/null; then
  echo "$tag: server died at startup:" >&2
  cat "$out/server.log" >&2
  exit 1
fi

# utime+stime over every thread: the server's whole CPU cost, not the main
# thread's. (For a single-threaded server the two are the same.)
cpu() { cat /proc/$srv/task/*/stat 2>/dev/null | awk '{s+=$14+$15} END {print s+0}'; }

# A round only means the same thing to every client process if they start it
# together: one process's round-2 sends would otherwise be counted by a
# straggler as round-1 echoes, and the counts drift until a round never
# completes. The barrier is a directory of empty files, one per process/round.
barrier="$out/barrier"
mkdir -p "$barrier"

c1=$(cpu)
pids=()
for i in $(seq 0 $((nprocs - 1))); do
  CLIENTS_COUNT="$per" TOTAL_CLIENTS="${TOTAL_CLIENTS_OVERRIDE:-$((per * nprocs))}" \
    ROUNDS="${ROUNDS:-8}" READY="${READY:-1}" \
    BARRIER_DIR="$barrier" PROC_ID="$i" NPROCS="$nprocs" \
    node "$ROOT/src/bench-client.mjs" > "$out/client.$i.log" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
c2=$(cpu)

alive=yes; kill -0 "$srv" 2>/dev/null || alive=NO
kill -- -"$srv" 2>/dev/null || true
sleep 0.3
kill -9 -- -"$srv" 2>/dev/null || true
rm -rf "$barrier"

python3 "$ROOT/scripts/summarize.py" "$out" "$tag" "$c1" "$c2" "$alive" "$nprocs" | tee -a "$out/summary.txt"
