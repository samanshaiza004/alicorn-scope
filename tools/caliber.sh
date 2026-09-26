#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
SCOPE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)

if [ -n "${CALIBER_CLI:-}" ]; then
    CALIBER_EXECUTABLE=$CALIBER_CLI
elif command -v caliber >/dev/null 2>&1; then
    CALIBER_EXECUTABLE=$(command -v caliber)
else
    command -v git >/dev/null 2>&1 || { printf 'Git is required to bootstrap Caliber.\n' >&2; exit 127; }
    command -v cargo >/dev/null 2>&1 || { printf 'Cargo is required to bootstrap Caliber. Install Rust/Cargo and retry.\n' >&2; exit 127; }
    REVISION=$(cat "$SCOPE_ROOT/.caliber-cli-revision")
    case "$REVISION" in *[!0-9a-f]*|'') printf 'Malformed Caliber CLI bootstrap revision.\n' >&2; exit 1 ;; esac
    [ "${#REVISION}" -eq 40 ] || { printf 'Malformed Caliber CLI bootstrap revision.\n' >&2; exit 1; }
    REPOSITORY=${CALIBER_CLI_REPOSITORY:-https://github.com/samanshaiza004/caliber.git}
    TOOLS_ROOT="$SCOPE_ROOT/.tools"
    SOURCE_ROOT="$TOOLS_ROOT/caliber-cli-source"
    mkdir -p "$TOOLS_ROOT"

    if [ ! -e "$SOURCE_ROOT" ]; then
        mkdir "$SOURCE_ROOT"
        git -C "$SOURCE_ROOT" init --quiet
        git -C "$SOURCE_ROOT" remote add origin "$REPOSITORY"
    else
        ROOT=$(git -C "$SOURCE_ROOT" rev-parse --show-toplevel 2>/dev/null) || { printf 'Caliber CLI bootstrap path is not a Git checkout: %s\n' "$SOURCE_ROOT" >&2; exit 1; }
        ROOT=$(CDPATH='' cd -- "$ROOT" && pwd -P)
        [ "$ROOT" = "$SOURCE_ROOT" ] || { printf 'Caliber CLI bootstrap path resolves elsewhere: %s\n' "$ROOT" >&2; exit 1; }
        ORIGIN=$(git -C "$SOURCE_ROOT" remote get-url origin) || { printf 'Caliber CLI bootstrap checkout has no origin.\n' >&2; exit 1; }
        [ "$ORIGIN" = "$REPOSITORY" ] || { printf 'Caliber CLI bootstrap origin mismatch; checkout left untouched.\n' >&2; exit 1; }
        DIRTY=$(git -C "$SOURCE_ROOT" status --porcelain --untracked-files=all) || { printf 'Could not inspect Caliber CLI bootstrap checkout.\n' >&2; exit 1; }
        [ -z "$DIRTY" ] || { printf 'Caliber CLI bootstrap checkout is dirty; checkout left untouched.\n' >&2; exit 1; }
    fi

    if ! git -C "$SOURCE_ROOT" cat-file -e "$REVISION^{commit}" 2>/dev/null; then
        git -C "$SOURCE_ROOT" fetch --quiet origin "$REVISION" || git -C "$SOURCE_ROOT" fetch --quiet origin main
    fi
    git -C "$SOURCE_ROOT" cat-file -e "$REVISION^{commit}" 2>/dev/null || { printf 'Pinned Caliber CLI commit is unavailable from %s: %s\n' "$REPOSITORY" "$REVISION" >&2; exit 1; }
    HEAD=$(git -C "$SOURCE_ROOT" rev-parse --verify HEAD 2>/dev/null || true)
    if [ "$HEAD" != "$REVISION" ]; then git -C "$SOURCE_ROOT" checkout --quiet --detach "$REVISION"; fi
    cargo build --locked --release --manifest-path "$SOURCE_ROOT/Cargo.toml" -p caliber --bin caliber
    CALIBER_EXECUTABLE="$SOURCE_ROOT/target/release/caliber"
    [ -x "$CALIBER_EXECUTABLE" ] || { printf 'Caliber CLI binary was not produced: %s\n' "$CALIBER_EXECUTABLE" >&2; exit 1; }
fi

exec "$CALIBER_EXECUTABLE" "$@"
