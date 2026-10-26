#!/bin/bash
# Refresh vendor/bun-websocket-server from oven-sh/bun's bench/websocket-server.
# The files are vendored so a run is reproducible without network access and
# so the exact workload this was measured against stays in the tree.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
dest="$ROOT/vendor/bun-websocket-server"
base="https://raw.githubusercontent.com/oven-sh/bun/main/bench/websocket-server"
mkdir -p "$dest"
for f in README.md package.json chat-client.mjs chat-server.bun.js \
         chat-server.node.mjs chat-server.deno.mjs tsconfig.json .gitignore; do
  curl -fsSL -o "$dest/$f" "$base/$f" || echo "skipped $f"
done
echo "vendored bun bench/websocket-server into $dest"
