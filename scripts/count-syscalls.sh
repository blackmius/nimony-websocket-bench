#!/bin/bash
# Count the server's syscalls over one round: strace -c -f around the server.
#   scripts/count-syscalls.sh <tag> <server-cmd...>
set -u
cd "$(dirname "$0")/.."
tag=$1; shift
out=results/$tag
mkdir -p "$out"
CLIENTS_COUNT=32 setsid strace -c -f -o "$out/strace.txt" "$@" > "$out/server.log" 2>&1 &
pid=$!
sleep 2
CLIENTS_COUNT=32 TOTAL_CLIENTS=32 ROUNDS=1 node src/bench-client.mjs > "$out/client.log" 2>&1
sleep 0.5
# The server's own exit is what makes strace flush its summary; killing strace
# first leaves an empty file.
pkill -TERM -x "$(basename "$1")"
wait "$pid" 2>/dev/null
head -20 "$out/strace.txt"
