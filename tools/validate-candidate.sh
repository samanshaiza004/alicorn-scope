#!/bin/sh
set -eu

SCOPE_ROOT=$CALIBER_PROJECT_ROOT
CANDIDATE=$CALIBER_CANDIDATE_ROOT
case "$CALIBER_DEPENDENCY" in
    alicorn) export ALICORN_ROOT=$CANDIDATE; export CALIBER_ROOT="$SCOPE_ROOT/.deps/caliber" ;;
    caliber) export ALICORN_ROOT="$SCOPE_ROOT/.deps/alicorn"; export CALIBER_ROOT=$CANDIDATE ;;
    *) printf 'Unexpected candidate dependency: %s\n' "$CALIBER_DEPENDENCY" >&2; exit 1 ;;
esac
export SCOPE_DEV_DEPS=1
sh "$SCOPE_ROOT/tools/build.sh"
