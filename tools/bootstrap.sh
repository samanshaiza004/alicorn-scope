#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
SCOPE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
. "$SCRIPT_DIR/dependencies.sh"
scope_resolve_dependencies "$SCOPE_ROOT"
printf 'Ready: Alicorn %s; Caliber %s\n' \
    "$(git -C "$SCOPE_RESOLVED_ALICORN_ROOT" rev-parse --short HEAD)" \
    "$(git -C "$SCOPE_RESOLVED_CALIBER_ROOT" rev-parse --short HEAD)"
