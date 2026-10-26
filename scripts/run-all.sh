#!/bin/bash
# The whole comparison, into results/. Takes a few minutes.
#
#   scripts/run-all.sh            # 5 rounds per configuration
#   ROUNDS=10 scripts/run-all.sh
#
# Needs: a built bin/chatserver (scripts/build.sh), `bun` on PATH for the Bun
# rows, and node (>= 22, for the built-in WebSocket) for the client.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export ROUNDS=${ROUNDS:-10}

if [ ! -x bin/chatserver ] || [ ! -x bin/chatserver-conn ]; then
  echo "bin/chatserver missing; run scripts/build.sh first" >&2
  exit 1
fi
if ! command -v node >/dev/null; then
  echo "node is required for the client" >&2
  exit 1
fi
havebun=yes
if ! command -v bun >/dev/null; then
  echo "warning: no bun on PATH, skipping the Bun rows" >&2
  havebun=no
fi

BUNBENCH=vendor/bun-websocket-server/chat-server.bun.js

if [ "$havebun" = yes ]; then
  scripts/bench.sh bun-1x32     1 32 bun "$BUNBENCH"
  scripts/bench.sh bun-4x8      4  8 bun "$BUNBENCH"
fi
scripts/bench.sh nimony-1x32  1 32 ./bin/chatserver
scripts/bench.sh nimony-2x16  2 16 ./bin/chatserver
scripts/bench.sh nimony-4x8   4  8 ./bin/chatserver
# the same room with a writer chain per connection, for the comparison
scripts/bench.sh conn-1x32    1 32 ./bin/chatserver-conn
scripts/bench.sh conn-4x8     4  8 ./bin/chatserver-conn

# One connection, 1600 round trips: the cost of a single message with no
# fan-out at all, where a per-frame I/O cost shows up as latency.
single() {
  local tag=$1; shift
  CLIENTS_COUNT=1 setsid "$@" > "results/$tag.server.log" 2>&1 &
  local srv=$!
  sleep 2
  CLIENTS_COUNT=1 TOTAL_CLIENTS=1 ROUNDS=$ROUNDS \
    node src/bench-client.mjs > "results/$tag.client.log" 2>&1
  kill -- -"$srv" 2>/dev/null || true
  sleep 0.3
  kill -9 -- -"$srv" 2>/dev/null || true
  echo "$tag: $(grep -o '{"median":[0-9]*' "results/$tag.client.log" || echo 'no rounds')"
}
single single-nimony ./bin/chatserver
if [ "$havebun" = yes ]; then single single-bun bun "$BUNBENCH"; fi

echo
cat results/*/summary.txt
