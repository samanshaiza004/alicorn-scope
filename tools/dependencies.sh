#!/bin/sh
# Sourced by bootstrap.sh and build.sh. It only mutates checkouts inside
# Scope-owned .deps; explicit ALICORN_ROOT/CALIBER_ROOT overrides are read-only.

scope_dependency_error() {
    printf 'Scope dependency resolver: %s\n' "$*" >&2
    return 1
}

scope_lock_value() {
    section=$1
    field=$2
    awk -v section="$section" -v field="$field" '
        $0 ~ ("\"" section "\"[[:space:]]*:") { in_section = 1; next }
        in_section && /^[[:space:]]*}/ { exit }
        in_section && $0 ~ ("\"" field "\"[[:space:]]*:") {
            sub(".*\"" field "\"[[:space:]]*:[[:space:]]*\"", "")
            sub(/".*/, "")
            print
            exit
        }
    ' "$SCOPE_ROOT/dependencies.lock.json"
}

scope_resolve_override() {
    name=$1
    requested_path=$2
    revision=$3
    allow_dev=$4

    if [ ! -d "$requested_path" ]; then
        scope_dependency_error "$name override directory does not exist: $requested_path"
        return 1
    fi
    root=$(git -C "$requested_path" rev-parse --show-toplevel 2>/dev/null) || {
        scope_dependency_error "$name override is not inside a Git checkout: $requested_path"
        return 1
    }
    root=$(CDPATH='' cd -- "$root" && pwd -P) || return 1
    actual=$(git -C "$root" rev-parse HEAD 2>/dev/null) || {
        scope_dependency_error "cannot read $name override HEAD at $root"
        return 1
    }
    dirty=$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null) || {
        scope_dependency_error "cannot inspect $name override at $root"
        return 1
    }

    if [ "$allow_dev" != 1 ]; then
        if [ "$actual" != "$revision" ]; then
            scope_dependency_error "$name override revision mismatch (expected $revision, found $actual). Set SCOPE_DEV_DEPS=1 to use this local revision. The checkout will not be changed."
            return 1
        fi
        if [ -n "$dirty" ]; then
            scope_dependency_error "$name override is dirty and therefore not exactly lockfile-reproducible. Set SCOPE_DEV_DEPS=1 to explicitly use the working tree; Scope will not change it."
            return 1
        fi
        printf '  %s pinned override ready: %.7s\n' "$name" "$actual" >&2
    else
        dirty_label=
        [ -z "$dirty" ] || dirty_label=' (working tree dirty)'
        printf 'WARNING: development dependency override is not lockfile-reproducible.\n  %s expected %.7s; using %.7s%s\n' "$name" "$revision" "$actual" "$dirty_label" >&2
    fi
    printf '%s\n' "$root"
}

scope_resolve_managed() {
    name=$1
    repository=$2
    revision=$3
    managed_path=$4
    managed_root=$5

    if [ ! -e "$managed_path" ]; then
        printf '  %s: cloning into %s\n' "$name" "$managed_path" >&2
        if ! git clone --quiet "$repository" "$managed_path"; then
            scope_dependency_error "$name clone failed. If it left a partial directory, inspect and remove only $managed_path before retrying."
            return 1
        fi
    fi

    root=$(git -C "$managed_path" rev-parse --show-toplevel 2>/dev/null) || {
        scope_dependency_error "$name managed path exists but is not a complete Git checkout: $managed_path. Inspect and remove that path explicitly before retrying."
        return 1
    }
    root=$(CDPATH='' cd -- "$root" && pwd -P) || return 1
    managed_prefix=${managed_root%/}/
    case "$root/" in
        "$managed_prefix"*) ;;
        *) scope_dependency_error "$name managed checkout resolves outside Scope's .deps directory: $root"; return 1 ;;
    esac

    origin=$(git -C "$root" remote get-url origin 2>/dev/null) || {
        scope_dependency_error "$name managed checkout has no origin: $root"
        return 1
    }
    if [ "$origin" != "$repository" ]; then
        scope_dependency_error "$name managed checkout origin mismatch. Expected $repository, found $origin. Scope will not repurpose it."
        return 1
    fi

    dirty=$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null) || {
        scope_dependency_error "cannot inspect managed $name checkout: $root"
        return 1
    }
    if [ -n "$dirty" ]; then
        scope_dependency_error "managed $name checkout has local edits; Scope leaves it untouched. Commit/stash those edits or explicitly move $managed_path aside before retrying."
        return 1
    fi

    actual=$(git -C "$root" rev-parse HEAD 2>/dev/null) || {
        scope_dependency_error "managed $name checkout has no valid HEAD: $root"
        return 1
    }
    if [ "$actual" != "$revision" ]; then
        printf '  %s: resolving pinned revision %.7s\n' "$name" "$revision" >&2
        if ! git -C "$root" cat-file -e "$revision^{commit}" 2>/dev/null; then
            git -C "$root" fetch --quiet origin || {
                scope_dependency_error "$name fetch failed"
                return 1
            }
        fi
        if ! git -C "$root" cat-file -e "$revision^{commit}" 2>/dev/null; then
            git -C "$root" fetch --quiet origin "$revision" || {
                scope_dependency_error "$name could not fetch locked commit $revision"
                return 1
            }
        fi
        git -C "$root" checkout --quiet --detach "$revision" || {
            scope_dependency_error "$name could not check out locked commit $revision"
            return 1
        }
    fi

    actual=$(git -C "$root" rev-parse HEAD 2>/dev/null) || return 1
    [ "$actual" = "$revision" ] || {
        scope_dependency_error "$name resolved to $actual instead of locked revision $revision"
        return 1
    }
    printf '  %s ready: %.7s\n' "$name" "$revision" >&2
    printf '%s\n' "$root"
}

scope_resolve_dependencies() {
    SCOPE_ROOT=$1
    alicorn_revision=$(scope_lock_value alicorn revision)
    caliber_revision=$(scope_lock_value caliber revision)
    alicorn_repository=$(scope_lock_value alicorn repository)
    caliber_repository=$(scope_lock_value caliber repository)
    case "$alicorn_revision" in *[!0-9a-f]*|'') scope_dependency_error 'invalid Alicorn revision in dependencies.lock.json'; return 1 ;; esac
    case "$caliber_revision" in *[!0-9a-f]*|'') scope_dependency_error 'invalid Caliber revision in dependencies.lock.json'; return 1 ;; esac
    case "${#alicorn_revision}" in 40|64) ;; *) scope_dependency_error 'Alicorn lock revision must be a full Git object ID'; return 1 ;; esac
    case "${#caliber_revision}" in 40|64) ;; *) scope_dependency_error 'Caliber lock revision must be a full Git object ID'; return 1 ;; esac
    [ -n "$alicorn_repository" ] || { scope_dependency_error 'Alicorn repository is missing from dependencies.lock.json'; return 1; }
    [ -n "$caliber_repository" ] || { scope_dependency_error 'Caliber repository is missing from dependencies.lock.json'; return 1; }

    allow_dev=0
    case "${SCOPE_DEV_DEPS:-}" in 1|true|TRUE|yes|YES) allow_dev=1 ;; esac
    has_override=0
    [ -z "${ALICORN_ROOT:-}" ] || has_override=1
    [ -z "${CALIBER_ROOT:-}" ] || has_override=1
    if [ "$allow_dev" -eq 1 ] && [ "$has_override" -eq 0 ]; then
        scope_dependency_error 'SCOPE_DEV_DEPS=1 requires ALICORN_ROOT and/or CALIBER_ROOT'
        return 1
    fi

    deps_dir="$SCOPE_ROOT/.deps"
    mkdir -p "$deps_dir" || { scope_dependency_error "cannot create managed dependency directory $deps_dir"; return 1; }
    managed_root=$(CDPATH='' cd -- "$deps_dir" && pwd -P) || return 1
    scope_prefix=${SCOPE_ROOT%/}/
    case "$managed_root/" in
        "$scope_prefix"*) ;;
        *) scope_dependency_error ".deps resolves outside Scope: $managed_root"; return 1 ;;
    esac

    if [ -n "${ALICORN_ROOT:-}" ]; then
        SCOPE_RESOLVED_ALICORN_ROOT=$(scope_resolve_override Alicorn "$ALICORN_ROOT" "$alicorn_revision" "$allow_dev") || return 1
    else
        SCOPE_RESOLVED_ALICORN_ROOT=$(scope_resolve_managed Alicorn "$alicorn_repository" "$alicorn_revision" "$managed_root/alicorn" "$managed_root") || return 1
    fi
    if [ -n "${CALIBER_ROOT:-}" ]; then
        SCOPE_RESOLVED_CALIBER_ROOT=$(scope_resolve_override Caliber "$CALIBER_ROOT" "$caliber_revision" "$allow_dev") || return 1
    else
        SCOPE_RESOLVED_CALIBER_ROOT=$(scope_resolve_managed Caliber "$caliber_repository" "$caliber_revision" "$managed_root/caliber" "$managed_root") || return 1
    fi
    export SCOPE_RESOLVED_ALICORN_ROOT SCOPE_RESOLVED_CALIBER_ROOT
}
