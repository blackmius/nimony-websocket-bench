#!/bin/bash
# How much memory does a server spend per held connection?
#
#   scripts/conn-mem.sh 2048 ./bin/echoserver
#   scripts/conn-mem.sh 8192 bun src/echo-server.bun.js
#
# Opens CONNS connections that each do one echo and then stay quiet, then
# reports the server's RSS growth per connection. The client is split over
# PROCS node processes.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
export PATH="$HOME/.bun/bin:$PATH"
CONNS=${1:?connections}; shift
PROCS=${PROCS:-4}
DURATION=${DURATION:-25}

pids=$(ss -ltnp 2>/dev/null | grep ':4001' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
for p in $pids; do kill -9 "$p" 2>/dev/null; done
sleep 0.3
setsid "$@" > /tmp/opencode/cm-srv.log 2>&1 &
sleep 2
srv=$(ss -ltnp 2>/dev/null | grep ':4001' | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1)
if [ -z "$srv" ]; then echo "server did not start" >&2; cat /tmp/opencode/cm-srv.log >&2; exit 1; fi
rss0=$(awk '/VmRSS/{print $2}' /proc/$srv/status)

per=$(( (CONNS + PROCS - 1) / PROCS ))
cl=""
for i in $(seq 0 $((PROCS - 1))); do
  CONNS=$per MODE=idle DURATION_S=$DURATION node src/scale-client.mjs > /tmp/opencode/cm.$i.json 2>&1 &
  cl="$cl $!"
done
# Let the ramp finish, then sample the steady state while the clients hold.
sleep $((DURATION - 8))
rss1=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
est=$(ss -tan 2>/dev/null | awk '$1=="ESTAB" && $4 ~ /:4001$/ {n++} END {print n+0}')
cpu=$(awk '{print $14+$15}' /proc/$srv/stat)
sleep 5
rss2=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
cpu2=$(awk '{print $14+$15}' /proc/$srv/stat)
for p in $cl; do wait $p; done
opened=$(cat /tmp/opencode/cm.*.json | sed -n 's/.*"opened":\([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
recv=$(cat /tmp/opencode/cm.*.json | sed -n 's/.*"recv":\([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
errors=$(cat /tmp/opencode/cm.*.json | sed -n 's/.*"errors":\([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
pids=$(ss -ltnp 2>/dev/null | grep ':4001' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
for p in $pids; do kill -9 "$p" 2>/dev/null; done

python3 - "$CONNS" "$opened" "$est" "$recv" "$errors" "$rss0" "$rss1" "$rss2" "$((cpu2-cpu))" <<'PY'
import sys
conns, opened, est, recv, errors, rss0, rss1, rss2, cpu = (int(x) for x in sys.argv[1:])
base, steady, end = rss0/1024, rss1/1024, rss2/1024
n = est if est else opened
print(f"connections   asked {conns}  opened {opened}  established {est}  echoes {recv}  errors {errors}")
print(f"server RSS    baseline {base:.0f} MB  steady {steady:.0f} MB  (+{steady-base:.0f} MB)")
print(f"per connection {(steady-base)*1024/max(n,1):.1f} KB   idle CPU {cpu/5/100:.3f} cores")
PY
