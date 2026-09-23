#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
SCOPE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
sh "$SCRIPT_DIR/build.sh"
cd "$SCOPE_ROOT/out"
exec ./alicorn-scope "$@"
