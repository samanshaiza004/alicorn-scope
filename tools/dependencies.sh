#!/bin/sh
# Thin Scope adapter: Caliber owns Git lock parsing and managed checkout safety.

scope_resolve_dependencies() {
    SCOPE_ROOT=$1
    has_override=0
    [ -z "${ALICORN_ROOT:-}" ] || has_override=1
    [ -z "${CALIBER_ROOT:-}" ] || has_override=1
    allow_dev=0
    case "${SCOPE_DEV_DEPS:-}" in 1|true|TRUE|yes|YES) allow_dev=1 ;; esac
    if [ "$allow_dev" -eq 1 ] && [ "$has_override" -eq 0 ]; then
        printf 'SCOPE_DEV_DEPS=1 requires ALICORN_ROOT and/or CALIBER_ROOT.\n' >&2
        return 1
    fi
    set -- sync --project-root "$SCOPE_ROOT"
    if [ -n "${ALICORN_ROOT:-}" ]; then set -- "$@" --override "alicorn=$ALICORN_ROOT"; fi
    if [ -n "${CALIBER_ROOT:-}" ]; then set -- "$@" --override "caliber=$CALIBER_ROOT"; fi
    if [ "$allow_dev" -eq 1 ]; then set -- "$@" --allow-dirty-overrides; fi
    "$SCOPE_ROOT/tools/caliber.sh" "$@"

    if [ -n "${ALICORN_ROOT:-}" ]; then
        SCOPE_RESOLVED_ALICORN_ROOT=$(git -C "$ALICORN_ROOT" rev-parse --show-toplevel)
    else
        SCOPE_RESOLVED_ALICORN_ROOT="$SCOPE_ROOT/.deps/alicorn"
    fi
    if [ -n "${CALIBER_ROOT:-}" ]; then
        SCOPE_RESOLVED_CALIBER_ROOT=$(git -C "$CALIBER_ROOT" rev-parse --show-toplevel)
    else
        SCOPE_RESOLVED_CALIBER_ROOT="$SCOPE_ROOT/.deps/caliber"
    fi
    export SCOPE_RESOLVED_ALICORN_ROOT SCOPE_RESOLVED_CALIBER_ROOT
}
