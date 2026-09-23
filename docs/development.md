# Building and developing Scope

## Ordinary developer workflow

Scope owns its pinned source dependencies. The first invocation reads
`dependencies.lock.json`, clones Alicorn and Caliber into `.deps/alicorn` and
`.deps/caliber`, checks out the locked commits, and then builds the application.
Subsequent builds reuse those clean pinned checkouts. The resolver never uses
or changes a sibling `../alicorn` or `../caliber` directory unless you
explicitly supply it as an override.

Install Git, Odin, 64-bit Go 1.25+, and Rust/Cargo first. The Odin compiler's
Windows release also requires the Microsoft C++ build tools and Windows SDK.
On macOS install Xcode command-line tools, `pkg-config`, and SDL3 3.4.16+; on
Linux install `pkg-config` and the SDL3 development package for your
distribution. Scope's build scripts diagnose missing tools instead of
installing toolchains automatically.

The POSIX build checks SDL through `pkg-config`, passes its linker search
flags to Odin, and the run script adds the SDL library directory to the
platform's dynamic-loader search path. The Windows build uses the SDL3 DLL
shipped with the Odin distribution and copies it beside Scope's executable.

Windows:

```powershell
git clone https://github.com/samanshaiza004/alicorn-scope.git
cd alicorn-scope
.\tools\run.ps1
```

Open a trace directly with:

```powershell
.\tools\run.ps1 -Trace 'C:\traces\capture.json'
```

macOS/Linux:

```sh
git clone https://github.com/samanshaiza004/alicorn-scope.git
cd alicorn-scope
sh tools/run.sh
```

Pass a trace as the first application argument to skip the file dialog:

```sh
sh tools/run.sh /path/to/capture.json
```

The first run fetches the locked source revisions and may take longer while
Cargo builds Caliber and Go/Odin build Scope. `tools/bootstrap.ps1` or
`sh tools/bootstrap.sh` can resolve the dependencies without building. The
same build entry points are used by the `fresh-dependency-build` CI workflow;
CI starts without preexisting sibling checkouts.

## Developing Alicorn or Caliber alongside Scope

Use explicit checkout overrides. Without `-DevDeps`, an override must be clean
and at exactly the lockfile revision. Scope only reads override checkouts; it
never fetches, checks out, resets, or cleans them.

For a local revision or uncommitted framework work, opt in explicitly:

```powershell
.\tools\run.ps1 `
    -AlicornRoot ..\alicorn `
    -CaliberRoot ..\caliber `
    -DevDeps
```

`-DevDeps` emits a warning showing expected and actual revisions and marks the
build as not lockfile-reproducible. Supplying only one override leaves the
other dependency managed and pinned.

In a POSIX shell, the equivalent is:

```sh
ALICORN_ROOT=../alicorn \
CALIBER_ROOT=../caliber \
SCOPE_DEV_DEPS=1 \
sh tools/run.sh
```

Without the development opt-in, set `ALICORN_ROOT` and/or `CALIBER_ROOT` to a
clean checkout at the exact lockfile revision. These environment variables are
explicit overrides; unset them to use `.deps`.

## Managed dependency safety and cleanup

Only Scope-owned `.deps/` checkouts may be moved to the lockfile revision.
Before doing so, the resolver verifies the checkout's origin and working tree.
If it finds edits, it stops and leaves them untouched; inspect/commit/stash
those edits or move that specific managed directory aside yourself. It never
silently runs `reset`, `clean`, or a forced checkout.

Remove generated build artifacts with:

```powershell
.\tools\clean.ps1
```

Dependencies are preserved unless explicitly requested:

```powershell
.\tools\clean.ps1 -Deps
```

The command refuses to remove edited managed checkouts unless you additionally
pass `-ForceDeps`. POSIX equivalents are `sh tools/clean.sh` and
`sh tools/clean.sh --deps [--force-deps]`. Cleanup targets only Scope's
`out/` and named `.deps/alicorn` / `.deps/caliber` directories.

## Updating a pinned dependency

Update the full commit ID in `dependencies.lock.json`, then validate the
ordinary managed path from a clean checkout (or after explicitly moving the
old managed directory aside):

```powershell
.\tools\bootstrap.ps1
.\tools\build.ps1
```

The lockfile remains the single source of truth. Do not pin an unpushed commit:
a fresh clone must be able to fetch every locked object from its repository.
