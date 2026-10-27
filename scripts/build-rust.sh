#!/bin/bash
# Build the two wtx servers and drop them next to the other rows in `bin/`.
#
#   scripts/build-rust.sh
#
# Needs cargo (the crate pins `wtx = 0.52`, which needs rustc >= 1.96) and a
# network connection the first time, for the crates.io index and the crates
# themselves; afterwards `Cargo.lock` makes the build reproducible offline.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)

if ! command -v cargo >/dev/null; then
  echo "no cargo on PATH; install the Rust toolchain first" >&2
  exit 1
fi

cd "$ROOT/rust"
# `--locked` when a lockfile is committed: the benchmark must not silently
# pick up a different wtx version from one run to the next.
if [ -f Cargo.lock ]; then
  cargo build --release --locked
else
  cargo build --release
fi

mkdir -p "$ROOT/bin"
cp target/release/wtx-echo "$ROOT/bin/wtx-echo"
cp target/release/wtx-chat "$ROOT/bin/wtx-chat"
echo "built $ROOT/bin/wtx-echo and bin/wtx-chat with $(cargo --version)"
