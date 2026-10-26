#!/bin/bash
# The plain echo comparison: every message goes back to its sender and nowhere
# else, so this is the per-message cost with no fan-out at all.
#
#   scripts/run-echo.sh          # 5 rounds per configuration
#   ROUNDS=10 scripts/run-echo.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export ROUNDS=${ROUNDS:-5}
export READY=0                 # no "ready" broadcast: the client sends at once
export TOTAL_CLIENTS_OVERRIDE=1 # each client counts only its own echoes

if [ ! -x bin/echoserver ]; then
  echo "bin/echoserver missing; run scripts/build.sh first" >&2
  exit 1
fi
havebun=yes
command -v bun >/dev/null || havebun=no

if [ "$havebun" = yes ]; then
  scripts/bench.sh echo-bun-1x32    1 32 bun src/echo-server.bun.js
  scripts/bench.sh echo-bun-4x8     4  8 bun src/echo-server.bun.js
fi
scripts/bench.sh echo-nimony-1x32 1 32 ./bin/echoserver
scripts/bench.sh echo-nimony-4x8  4  8 ./bin/echoserver

# The same, with 2000-byte messages: the per-byte part of the cost on its own,
# with the per-message part spread over 133 times more bytes.
if [ "$havebun" = yes ]; then
  MSG_SIZE=2000 scripts/bench.sh echo-bun-big-1x32 1 32 bun src/echo-server.bun.js
fi
MSG_SIZE=2000 scripts/bench.sh echo-nimony-big-1x32 1 32 ./bin/echoserver

echo
cat results/echo-*/summary.txt
