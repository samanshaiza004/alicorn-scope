#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
SCOPE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
REMOVE_DEPS=0
FORCE_DEPS=0
for option in "$@"; do
    case "$option" in
        --deps) REMOVE_DEPS=1 ;;
        --force-deps) FORCE_DEPS=1 ;;
        *) printf 'Usage: sh tools/clean.sh [--deps] [--force-deps]\n' >&2; exit 2 ;;
    esac
done
if [ "$FORCE_DEPS" -eq 1 ] && [ "$REMOVE_DEPS" -eq 0 ]; then
    printf '%s\n' '--force-deps requires --deps.' >&2
    exit 2
fi

DEPS_DIR="$SCOPE_ROOT/.deps"
if [ "$REMOVE_DEPS" -eq 1 ] && [ -e "$DEPS_DIR" ]; then
    if [ -L "$DEPS_DIR" ]; then printf 'Refusing to clean .deps/: it is a symlink.\n' >&2; exit 1; fi
    DEPS_REAL=$(CDPATH='' cd -- "$DEPS_DIR" && pwd -P)
    [ "$DEPS_REAL" = "$SCOPE_ROOT/.deps" ] || { printf 'Refusing unexpected dependency path: %s\n' "$DEPS_REAL" >&2; exit 1; }
    for NAME in alicorn caliber; do
        TARGET="$DEPS_DIR/$NAME"
        [ -e "$TARGET" ] || continue
        if [ -L "$TARGET" ] || [ ! -d "$TARGET/.git" ]; then
            printf 'Refusing to remove unrecognized managed dependency path: %s\n' "$TARGET" >&2
            exit 1
        fi
        REPOSITORY_ROOT=$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null) || {
            printf 'Refusing to remove invalid Git checkout: %s\n' "$TARGET" >&2
            exit 1
        }
        REPOSITORY_ROOT=$(CDPATH='' cd -- "$REPOSITORY_ROOT" && pwd -P)
        TARGET_REAL=$(CDPATH='' cd -- "$TARGET" && pwd -P)
        [ "$REPOSITORY_ROOT" = "$TARGET_REAL" ] || { printf 'Refusing non-root dependency checkout: %s\n' "$TARGET" >&2; exit 1; }
        DIRTY=$(git -C "$TARGET" status --porcelain --untracked-files=all)
        if [ -n "$DIRTY" ] && [ "$FORCE_DEPS" -eq 0 ]; then
            printf '%s has local edits. Preserve them, or explicitly pass --force-deps to remove this managed checkout.\n' "$TARGET" >&2
            exit 1
        fi
    done
fi

# All requested dependency targets are validated before any deletion begins.
OUT_DIR="$SCOPE_ROOT/out"
if [ -e "$OUT_DIR" ]; then
    if [ -L "$OUT_DIR" ]; then printf 'Refusing to clean out/: it is a symlink.\n' >&2; exit 1; fi
    OUT_REAL=$(CDPATH='' cd -- "$OUT_DIR" && pwd -P)
    [ "$OUT_REAL" = "$SCOPE_ROOT/out" ] || { printf 'Refusing unexpected output path: %s\n' "$OUT_REAL" >&2; exit 1; }
fi

if [ -e "$OUT_DIR" ]; then
    rm -rf -- "$OUT_DIR"
    printf 'Removed generated output: %s\n' "$OUT_DIR"
fi
if [ "$REMOVE_DEPS" -eq 1 ]; then
    for NAME in alicorn caliber; do
        TARGET="$DEPS_DIR/$NAME"
        if [ -e "$TARGET" ]; then rm -rf -- "$TARGET"; printf 'Removed managed dependency: %s\n' "$TARGET"; fi
    done
fi
