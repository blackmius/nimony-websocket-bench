#!/bin/bash
# Three-way interleaved runs: Bun, nimony and wtx (Rust) in rotation.
#
#   scripts/run-rust.sh              # 3 repetitions per side
#   REPS=5 scripts/run-rust.sh
#
# Why interleaved: the box is shared and drifts by ~10% between runs, so two
# servers measured minutes apart are not a comparison. Three servers measured
# in the same minute, in rotating order so no side is always measured first,
# are. A 3% difference is still not a result.
#
# `bin/wtx-echo` and `bin/wtx-chat` come from `scripts/build-rust.sh`.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
REPS=${REPS:-3}
export PATH="$HOME/.bun/bin:$PATH"

havebun=yes
command -v bun >/dev/null || havebun=no
if [ ! -x bin/wtx-echo ] || [ ! -x bin/wtx-chat ]; then
  echo "bin/wtx-echo or bin/wtx-chat missing; run scripts/build-rust.sh first" >&2
  exit 1
fi

# workload nprocs clients-per-proc rounds
configs=(
  "chat 1 32 10"
  "chat 4  8 10"
  "echo 1 32 20"
  "echo 4  8 20"
  "echobig 1 32 20"
)

declare -A AGG CPU RND

for cfg in "${configs[@]}"; do
  read -r workload nper per rounds <<< "$cfg"
  case "$workload" in
    chat)    size=chat;     cmdBun="bun vendor/bun-websocket-server/chat-server.bun.js"
                             cmdNimony="./bin/chatserver-conn"; cmdWtx="./bin/wtx-chat"; envs="";;
    echo)    size=echo;     cmdBun="bun src/echo-server.bun.js"
                             cmdNimony="./bin/echoserver"; cmdWtx="./bin/wtx-echo"
                             envs="READY=0 TOTAL_CLIENTS_OVERRIDE=1";;
    echobig) size=echo-big; cmdBun="bun src/echo-server.bun.js"
                             cmdNimony="./bin/echoserver"; cmdWtx="./bin/wtx-echo"
                             envs="READY=0 TOTAL_CLIENTS_OVERRIDE=1 MSG_SIZE=2000";;
  esac
  shape="${nper}x${per}"

  # One rotation per repetition: with three sides the side measured first — on
  # the coldest cache and the freshest neighbour load — moves each time.
  for ((i = 0; i < REPS; i++)); do
    case $((i % 3)) in
      0) order="bun nimony wtx" ;;
      1) order="nimony wtx bun" ;;
      2) order="wtx bun nimony" ;;
    esac
    for side in $order; do
      if [ "$side" = bun ] && [ "$havebun" = no ]; then continue; fi
      tag="$size-$side-$shape"
      case "$side" in
        bun)    cmd=$cmdBun;;
        nimony) cmd=$cmdNimony;;
        wtx)    cmd=$cmdWtx;;
      esac
      line=$(env $envs ROUNDS="$rounds" ./scripts/bench.sh "$tag" "$nper" "$per" $cmd | tail -1)
      AGG[$tag]+="$(sed -n 's/.*aggregate= *\([0-9]*\) msg\/s.*/\1/p' <<< "$line") "
      CPU[$tag]+="$(sed -n 's/.*server_cpu= *\([0-9.]*\)s.*/\1/p' <<< "$line") "
      RND[$tag]+="$(sed -n 's/.*round= *\([0-9.]*\) ms.*/\1/p' <<< "$line") "
    done
  done

  echo "$size, $nper client process(es) x $per clients, $rounds rounds, $REPS reps each"
  python3 - "$havebun" \
    "${AGG[$size-bun-$shape]}" "${CPU[$size-bun-$shape]}" "${RND[$size-bun-$shape]}" \
    "${AGG[$size-nimony-$shape]}" "${CPU[$size-nimony-$shape]}" "${RND[$size-nimony-$shape]}" \
    "${AGG[$size-wtx-$shape]}" "${CPU[$size-wtx-$shape]}" "${RND[$size-wtx-$shape]}" <<'PY'
import statistics as st, sys

havebun, *rest = sys.argv[1:]
ab, cb, rb, an, cn, rn, aw, cw, rw = rest

def nums(text):
    return [float(x) for x in text.split()]

def line(name, agg, cpu, rnd):
    if not nums(agg):
        return
    print(f"  {name:8s} median {int(st.median(nums(agg))):>9,} msg/s   "
          f"round {st.median(nums(rnd)):>6.1f} ms   cpu {st.median(nums(cpu)):>5.2f} s")

line("Bun", ab, cb, rb)
line("nimony", an, cn, rn)
line("wtx", aw, cw, rw)
base = st.median(nums(aw))
for name, agg in (("Bun", ab), ("nimony", an)):
    if name == "Bun" and havebun == "no":
        continue
    if nums(agg):
        print(f"  wtx vs {name}: {100 * base / st.median(nums(agg)) - 100:+.1f}%")
PY
done
