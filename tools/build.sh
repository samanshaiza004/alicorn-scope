#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
SCOPE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
ALICORN_ROOT=${ALICORN_ROOT:-"$SCOPE_ROOT/../alicorn"}
CALIBER_ROOT=${CALIBER_ROOT:-"$SCOPE_ROOT/../caliber"}
ODIN=${ALICORN_ODIN:-odin}
GO=${SCOPE_GO:-go}

LOCK_ALICORN=$(sed -n 's/.*"revision": "\([0-9a-f]*\)".*/\1/p' "$SCOPE_ROOT/dependencies.lock.json" | sed -n '1p')
LOCK_CALIBER=$(sed -n 's/.*"revision": "\([0-9a-f]*\)".*/\1/p' "$SCOPE_ROOT/dependencies.lock.json" | sed -n '2p')
ACTUAL_ALICORN=$(git -C "$ALICORN_ROOT" rev-parse HEAD)
ACTUAL_CALIBER=$(git -C "$CALIBER_ROOT" rev-parse HEAD)
[ "$ACTUAL_ALICORN" = "$LOCK_ALICORN" ] || { echo "Alicorn must be at $LOCK_ALICORN (found $ACTUAL_ALICORN)" >&2; exit 1; }
[ "$ACTUAL_CALIBER" = "$LOCK_CALIBER" ] || { echo "Caliber must be at $LOCK_CALIBER (found $ACTUAL_CALIBER)" >&2; exit 1; }
grep -q 'context_wait_wake\|context_stop_wake_waiters' "$CALIBER_ROOT/crates/caliber-ffi/src/lib.rs" || {
    echo "Pinned Caliber checkout is missing the blocking wake ABI." >&2; exit 1;
}
command -v "$ODIN" >/dev/null 2>&1 || { echo "Odin not found: $ODIN" >&2; exit 127; }
command -v "$GO" >/dev/null 2>&1 || { echo "Go not found: $GO" >&2; exit 127; }

OUT_DIR="$SCOPE_ROOT/out"
mkdir -p "$OUT_DIR"
export CGO_ENABLED=1
export GOCACHE=${GOCACHE:-"$OUT_DIR/go-cache"}
export GOTELEMETRY=off

cargo build --release --manifest-path "$CALIBER_ROOT/Cargo.toml" -p caliber-ffi
case "$(uname -s)" in
    Darwin) CALIBER_LIB="$CALIBER_ROOT/target/release/libcaliber_ffi.dylib"; BACKEND_LIB="$OUT_DIR/libscope_backend.dylib" ;;
    *)      CALIBER_LIB="$CALIBER_ROOT/target/release/libcaliber_ffi.so"; BACKEND_LIB="$OUT_DIR/libscope_backend.so" ;;
esac
"$GO" build -buildmode=c-shared -o "$BACKEND_LIB" ./backend/bridge
"$ODIN" build . "-out:$OUT_DIR/alicorn-scope"
cp "$CALIBER_LIB" "$OUT_DIR/$(basename "$CALIBER_LIB")"
