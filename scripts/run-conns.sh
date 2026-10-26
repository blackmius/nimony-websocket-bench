#!/bin/bash
# How many connections does a server hold, and what does each one cost?
#
#   scripts/run-conns.sh 8192 ./bin/echoserver
#   scripts/run-conns.sh 32768 bun src/echo-server.bun.js
#
# The client is `bin/hold-client` (Nim, one chain per connection: handshake,
# one echo, then park on a read), split over PROCS processes. Both sides are
# measured: the server's RSS per connection is the number that says how many
# it could hold, and the client's is the one that says how many the driver can
# ask for.
#
# Reports one RESULT line: asked, opened, echoed, failed, established, server
# MB/conn, client MB/conn, idle CPU of the server.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
export PATH="$HOME/.bun/bin:$PATH"

N=${1:?connections}; shift
rm -f /tmp/opencode/rc.*.json /tmp/opencode/rc.*.err
PROCS=${PROCS:-1}
DUR=${DUR:-25}
SAMPLE_AT=${SAMPLE_AT:-$((DUR - 6))}

pids=$(ss -ltnp 2>/dev/null | grep ':4001' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
for p in $pids; do kill -9 "$p" 2>/dev/null; done
sleep 0.3
setsid "$@" > /tmp/opencode/rc-srv.log 2>&1 &
sleep 2
srv=$(ss -ltnp 2>/dev/null | grep ':4001' | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1)
if [ -z "$srv" ]; then echo "server did not start" >&2; cat /tmp/opencode/rc-srv.log >&2; exit 1; fi
srss0=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
scpu0=$(awk '{print $14+$15}' /proc/$srv/stat)

per=$(( (N + PROCS - 1) / PROCS ))
cl=""
for i in $(seq 0 $((PROCS - 1))); do
  CONNS=$per DURATION_S=$DUR ${CLIENT:-./bin/hold-client} > /tmp/opencode/rc.$i.json 2> /tmp/opencode/rc.$i.err &
  cl="$cl $!"
done
sleep "$SAMPLE_AT"
srss1=$(awk '/VmRSS/{print $2}' /proc/$srv/status)
crss=0
for p in $cl; do
  r=$(awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null || echo 0)
  crss=$((crss + ${r:-0}))
done
est=$(ss -Htan state established "( sport = :4001 )" 2>/dev/null | wc -l)
sleep 5
scpu1=$(awk '{print $14+$15}' /proc/$srv/stat)
for p in $cl; do wait "$p"; done
opened=$(cat /tmp/opencode/rc.*.json | sed -n 's/.*"opened": \([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
echoed=$(cat /tmp/opencode/rc.*.json | sed -n 's/.*"echoed": \([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
failed=$(cat /tmp/opencode/rc.*.json | sed -n 's/.*"failed": \([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
pids=$(ss -ltnp 2>/dev/null | grep ':4001' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
for p in $pids; do kill -9 "$p" 2>/dev/null; done

python3 - "$N" "$opened" "$echoed" "$failed" "$est" "$srss0" "$srss1" "$crss" "$((scpu1-scpu0))" <<'PY'
import sys
n, opened, echoed, failed, est, srss0, srss1, crss, cpu = (int(x) for x in sys.argv[1:])
held = est if est else opened
smb = (srss1 - srss0) / 1024
cmb = crss / 1024
print(f"RESULT asked {n}  opened {opened}  echoed {echoed}  failed {failed}  established {held}")
print(f"       server +{smb:.0f} MB = {smb*1024/max(held,1):.1f} KB/conn   "
      f"client {cmb:.0f} MB = {cmb*1024/max(held,1):.1f} KB/conn   "
      f"server idle CPU {cpu/5/100:.3f} cores")
PY
