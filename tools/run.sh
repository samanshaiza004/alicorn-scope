#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
SCOPE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
if [ "$#" -gt 0 ]; then
    case "$1" in
        -*) ;;
        *)
            if [ -f "$1" ]; then
                TRACE_PATH=$(CDPATH='' cd -- "$(dirname -- "$1")" && pwd -P)/$(basename -- "$1")
                shift
                set -- "$TRACE_PATH" "$@"
            fi
            ;;
    esac
fi
sh "$SCRIPT_DIR/build.sh"
cd "$SCOPE_ROOT/out"
case "$(uname -s)" in
    Darwin)
        SDL_LIB_DIR=$(pkg-config --variable=libdir sdl3)
        export DYLD_LIBRARY_PATH="$SDL_LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
        ;;
    Linux)
        SDL_LIB_DIR=$(pkg-config --variable=libdir sdl3)
        export LD_LIBRARY_PATH="$SDL_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        ;;
esac
exec ./alicorn-scope "$@"
