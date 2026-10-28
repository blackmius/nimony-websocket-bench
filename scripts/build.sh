#!/bin/bash
# Build the nimony servers with the nimony toolchain.
#
# `chatserver-conn` gives every connection a writer chain of its own, which is
# what the library's one-writer-per-connection rule forces an application
# into; `echoserver` is the plain echo.
#
#   NIMONY=/path/to/nimony scripts/build.sh [extra nimony flags]
#
# The default assumes this repository sits next to a nimony checkout; override
# NIMONY to point somewhere else.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NIMONY=${NIMONY:-$ROOT/../nimony}

if [ ! -x "$NIMONY/bin/nimony" ]; then
  echo "no nimony toolchain at $NIMONY/bin/nimony" >&2
  echo "set NIMONY=/path/to/nimony (it needs bin/nimony from 'hastur build nimony')" >&2
  exit 1
fi

mkdir -p "$ROOT/bin"
# -d:release is what the comparison uses: the server is CPU-bound, so an
# unoptimised build would measure the C compiler's -O1, not the design.
"$NIMONY/bin/nimony" c -d:release -o:"$ROOT/bin/chatserver-conn" "$@" "$ROOT/src/chatserver-conn.nim"
"$NIMONY/bin/nimony" c -d:release -o:"$ROOT/bin/echoserver" "$@" "$ROOT/src/echoserver.nim"
echo "built $ROOT/bin/chatserver-conn and bin/echoserver"
