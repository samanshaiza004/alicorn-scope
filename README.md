# Alicorn Scope

A read-only trace explorer built with a Go domain backend, Caliber's bounded foreign boundary, and an Odin/Alicorn native frontend.

Phase 1 opens Chrome Trace Event JSON, indexes complete (`X`) and instant (`I`) events, displays tracks and a virtualized event window, and inspects a selected event. The full trace remains in Go; only bounded, versioned resources cross into Odin.

This repository pins Alicorn and Caliber to exact revisions. Caliber remains experimental and no ABI stability is promised.

## Build and run

The application expects sibling checkouts `../alicorn` and `../caliber` at
the revisions in [`dependencies.lock.json`](dependencies.lock.json), including
Caliber's blocking wake ABI extension. On Windows, run `tools/build.ps1` and
then `tools/run.ps1 --Trace <path-to-trace.json>`. On macOS/Linux, install the
SDL3 development library first (the native host links `system:SDL3`; macOS
requires SDL 3.4.16), then run `sh tools/build.sh` or
`sh tools/run.sh <path-to-trace.json>`. Omitting a path opens the native file
dialog. `--help` prints the command-line usage and `--smoke` runs a short
startup/load/render/exit check.

The Go parser is independently testable with `go test ./...`; set
`SCOPE_STRESS=1` to include the 1,000,000-event repeated/unique-name stress.
See [`docs/validation.md`](docs/validation.md) for the Windows build, idle
proof, stress timings, and remaining macOS gate.
