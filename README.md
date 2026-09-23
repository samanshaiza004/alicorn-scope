# Alicorn Scope

A read-only trace explorer built with a Go domain backend, Caliber's bounded
foreign boundary, and an Odin/Alicorn native frontend. Phase 1 provides trace
loading, filtering, tracks, a virtualized event table, and inspection. Phase 2
adds a directly manipulated timeline with bounded event and aggregate windows.

## Build and run

Install the toolchains below, clone Scope, then use one command. Alicorn and
Caliber are fetched automatically at the exact revisions in
[`dependencies.lock.json`](dependencies.lock.json); you do not need sibling
checkouts or to switch either repository to a detached commit. The first build
needs network access and stores its managed checkouts in the ignored `.deps/`
directory.

Prerequisites: Git, Odin, Go (64-bit, version 1.25 or newer), and Rust/Cargo.
Odin on Windows also requires the Microsoft C++ build tools and Windows SDK.
macOS/Linux builds need `pkg-config` and SDL3 development files; macOS requires
SDL 3.4.16 or newer.

### Windows

```powershell
.\tools\run.ps1
.\tools\run.ps1 -Trace 'C:\path\to\trace.json'
```

Omitting `-Trace` opens the native file dialog. Build without launching with
`.\tools\build.ps1`; run the startup/load/render/exit check with
`.\tools\run.ps1 -Smoke`, or print application usage with
`.\tools\run.ps1 -Help`.

### macOS and Linux

On macOS, install SDL3 with `brew install pkg-config sdl3`. On Linux, install
`pkg-config` and the SDL3 development package for your distribution, ensuring
`sdl3.pc` is discoverable. Then:

```sh
sh tools/run.sh
sh tools/run.sh /path/to/trace.json
```

Omitting the trace path opens the native file dialog. Use `sh tools/build.sh`
to build only, `sh tools/run.sh --smoke` for the startup smoke check, or
`sh tools/run.sh --help` for application usage.

The resolver and detailed prerequisite/override behavior are documented in
[`docs/development.md`](docs/development.md). The Go parser can be tested
independently with `go test ./...`; set `SCOPE_STRESS=1` to include the
1,000,000-event stress test. See [`docs/validation.md`](docs/validation.md)
and [`docs/phase-2.md`](docs/phase-2.md) for the recorded validation gates.
