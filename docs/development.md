# Building and developing Scope

## Ordinary developer workflow

Scope owns its exact source dependency lock. The first invocation bootstraps
the pinned Caliber CLI into project-owned `.tools/`, then `caliber sync`
materializes the lock into `.deps/alicorn` and `.deps/caliber`. Subsequent
builds reuse those clean pinned checkouts. No sibling repository is required.

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

The first run fetches the pinned Caliber CLI source and locked dependency
revisions; then Cargo builds Caliber and Go/Odin build Scope.
`tools/bootstrap.ps1` or `sh tools/bootstrap.sh` synchronizes dependencies
without building the application. CI uses the same managed workflow and does
not require sibling checkouts.

The Caliber CLI bootstrap pin is recorded separately in
`.caliber-cli-revision`; it pins the tool that reads the dependency lock. The
application dependency revisions are authoritative only in
`dependencies.lock.json`.

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

Use the same dependency CLI that normal builds invoke. `status` is local and
does not check remotes; `sync` never updates revisions. To deliberately update
one dependency, Caliber resolves its `ref`, runs the Scope build validation
hook, then atomically updates the lock:

```powershell
& .\tools\caliber.ps1 status
& .\tools\caliber.ps1 sync
& .\tools\caliber.ps1 update alicorn
& .\tools\caliber.ps1 update caliber
& .\tools\caliber.ps1 pin alicorn ..\alicorn
& .\tools\caliber.ps1 pin caliber ..\caliber
```

POSIX users can call the corresponding wrapper, for example
`sh tools/caliber.sh status` or `sh tools/caliber.sh update alicorn`.
`CALIBER_CLI` may name an explicitly supplied CLI; otherwise the wrapper uses
`caliber` from `PATH` and then bootstraps the pinned source. `CALIBER_CLI_REPOSITORY`
may point the bootstrap at a trusted mirror. Do not pin an unpushed commit: a
fresh clone must be able to fetch every locked object from its repository.

## Caliber diagnostics

After building Scope, run the project-owned diagnostics without launching its
window:

Windows:
    .\tools\caliber.ps1 doctor
    .\tools\caliber.ps1 check

macOS/Linux:
    sh tools/caliber.sh doctor
    sh tools/caliber.sh check

Doctor reports the local lock and managed dependency state, project-declared
tools, the produced Caliber library's loadability and host architecture
compatibility, ABI version/table extent, and required functions. Check also
exercises context creation/destruction, command/state/resource round trips,
and wake/wait/stop/join. These commands do not install toolchains or build
Scope; build Scope first so its native Caliber library exists.
