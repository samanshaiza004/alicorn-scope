#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
SCOPE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
ODIN=${ALICORN_ODIN:-odin}
GO=${SCOPE_GO:-go}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing prerequisite: %s. %s\n' "$1" "$2" >&2
        exit 127
    }
}

require_command git 'Install Git, add it to PATH, and rerun tools/run.sh.'
require_command cargo 'Install Rust using https://rustup.rs, then rerun tools/run.sh.'
require_command "$ODIN" 'Install the Odin compiler from https://odin-lang.org/docs/install/ and add it to PATH, or set ALICORN_ODIN.'
require_command "$GO" 'Install Go and add it to PATH, or set SCOPE_GO.'

GOARCH=$($GO env GOARCH)
case "$GOARCH" in amd64|arm64) ;; *) printf 'Scope requires 64-bit Go; selected GOARCH=%s.\n' "$GOARCH" >&2; exit 1 ;; esac

case "$(uname -s)" in
    Darwin)
        require_command pkg-config 'Install pkg-config and SDL3 (for example: brew install pkg-config sdl3).'
        if ! pkg-config --atleast-version=3.4.16 sdl3; then
            SDL_VERSION=$(pkg-config --modversion sdl3 2>/dev/null || printf 'not found')
            printf 'Scope requires SDL 3.4.16 or newer on macOS; found %s. Install/update with: brew install sdl3\n' "$SDL_VERSION" >&2
            exit 1
        fi
        SDL_LINK_FLAGS=$(pkg-config --libs sdl3)
        ;;
    Linux)
        require_command pkg-config 'Install pkg-config and the SDL3 development package for your Linux distribution.'
        if ! pkg-config --exists sdl3; then
            printf 'SDL3 development files were not found through pkg-config. Install SDL3 development headers/library and ensure sdl3.pc is on PKG_CONFIG_PATH.\n' >&2
            exit 1
        fi
        SDL_LINK_FLAGS=$(pkg-config --libs sdl3)
        ;;
    *) printf 'Unsupported build host: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac

. "$SCRIPT_DIR/dependencies.sh"
scope_resolve_dependencies "$SCOPE_ROOT"
ALICORN_ROOT=$SCOPE_RESOLVED_ALICORN_ROOT
CALIBER_ROOT=$SCOPE_RESOLVED_CALIBER_ROOT

if ! grep -Eq 'context_wait_wake|context_stop_wake_waiters' "$CALIBER_ROOT/include/caliber.h"; then
    printf 'Resolved Caliber checkout is missing the blocking wake ABI required by Scope.\n' >&2
    exit 1
fi

OUT_DIR="$SCOPE_ROOT/out"
mkdir -p "$OUT_DIR"
export CGO_ENABLED=1
export CGO_CFLAGS="${CGO_CFLAGS:-} -I$CALIBER_ROOT/include"
export GOCACHE=${GOCACHE:-"$OUT_DIR/go-cache"}
export GOTELEMETRY=off
cd "$SCOPE_ROOT"

printf 'Building Caliber FFI...\n'
cargo build --release --manifest-path "$CALIBER_ROOT/Cargo.toml" -p caliber-ffi
case "$(uname -s)" in
    Darwin) CALIBER_LIB="$CALIBER_ROOT/target/release/libcaliber_ffi.dylib"; BACKEND_LIB="$OUT_DIR/libscope_backend.dylib" ;;
    Linux) CALIBER_LIB="$CALIBER_ROOT/target/release/libcaliber_ffi.so"; BACKEND_LIB="$OUT_DIR/libscope_backend.so" ;;
esac

printf 'Building Scope Go backend...\n'
"$GO" build -buildmode=c-shared -o "$BACKEND_LIB" ./backend/bridge
printf 'Building Alicorn Scope...\n'
"$ODIN" build . "-collection:alicorn=$ALICORN_ROOT" "-extra-linker-flags:$SDL_LINK_FLAGS" "-out:$OUT_DIR/alicorn-scope"
if [ ! -f "$CALIBER_LIB" ]; then printf 'Caliber library was not produced: %s\n' "$CALIBER_LIB" >&2; exit 1; fi
cp "$CALIBER_LIB" "$OUT_DIR/$(basename "$CALIBER_LIB")"
printf 'Build complete: %s/alicorn-scope\n' "$OUT_DIR"
