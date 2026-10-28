#!/bin/bash
# Interleaved A/B runs: for every configuration, alternate the two servers
# (`A, B, A, B, ...`) and report the median of each side.
#
#   scripts/run-interleaved.sh            # 3 repetitions per side
#   REPS=5 scripts/run-interleaved.sh
#
# Why interleaved: the box is shared and drifts by ~10% between runs, so a
# nimony run and a Bun run measured minutes apart are not a comparison. Two
# servers measured in the same minute, alternately, are. A 3% difference is
# still not a result.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
REPS=${REPS:-3}
export PATH="$HOME/.bun/bin:$PATH"

# tagA tagB nprocs per rounds extra-env
configs=(
  "bun-1x32 nimony-1x32 1 32 10 chat"
  "bun-4x8 nimony-4x8 4 8 10 chat"
  "echo-bun-1x32 echo-nimony-1x32 1 32 20 echo"
  "echo-bun-4x8 echo-nimony-4x8 4 8 20 echo"
  "echo-bun-big-1x32 echo-nimony-big-1x32 1 32 20 echobig"
)

declare -A AGG CPU RND
for cfg in "${configs[@]}"; do
  read -r ta tb nper per rounds kind <<< "$cfg"
  case "$kind" in
    chat)    ca="bun vendor/bun-websocket-server/chat-server.bun.js"; cb="./bin/chatserver-conn"; envs="";;
    echo)    ca="bun src/echo-server.bun.js"; cb="./bin/echoserver"; envs="READY=0 TOTAL_CLIENTS_OVERRIDE=1";;
    echobig) ca="bun src/echo-server.bun.js"; cb="./bin/echoserver"; envs="READY=0 TOTAL_CLIENTS_OVERRIDE=1 MSG_SIZE=2000";;
  esac
  for ((i = 0; i < REPS; i++)); do
    for side in a b; do
      if [ "$side" = a ]; then tag=$ta; cmd=$ca; else tag=$tb; cmd=$cb; fi
      line=$(env $envs ROUNDS="$rounds" ./scripts/bench.sh "$tag" "$nper" "$per" $cmd | tail -1)
      agg=$(sed -n 's/.*aggregate= *\([0-9]*\) msg\/s.*/\1/p' <<< "$line")
      cpu=$(sed -n 's/.*server_cpu= *\([0-9.]*\)s.*/\1/p' <<< "$line")
      rnd=$(sed -n 's/.*round= *\([0-9.]*\) ms.*/\1/p' <<< "$line")
      AGG[$tag]+="$agg "; CPU[$tag]+="$cpu "; RND[$tag]+="$rnd "
    done
  done
  echo "$ta vs $tb (nprocs=$nper x $per, $rounds rounds, $REPS reps each)"
  python3 - "$ta" "$tb" "${AGG[$ta]}" "${AGG[$tb]}" "${CPU[$ta]}" "${CPU[$tb]}" "${RND[$ta]}" "${RND[$tb]}" <<'PY'
import sys, statistics as st
ta, tb, aa, ab, ca, cb, ra, rb = sys.argv[1:9]
def nums(s): return [float(x) for x in s.split()]
def line(tag, a, c, r):
    print(f"  {tag:22s} median {int(st.median(nums(a))):>9,} msg/s   "
          f"round {st.median(nums(r)):>6.1f} ms   cpu {st.median(nums(c)):>5.2f} s")
line(ta, aa, ca, ra)
line(tb, ab, cb, rb)
ma, mb = st.median(nums(aa)), st.median(nums(ab))
print(f"  nimony/bun throughput {100*mb/ma-100:+.1f}%, "
      f"CPU {st.median(nums(cb))/st.median(nums(ca)):.2f}x")
PY
done
