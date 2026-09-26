# Phase 1 validation record

## Windows x64 run

Validated on 2026-09-22 with Go 1.27.1 `windows/amd64`, Odin
`dev-2026-09-nightly:a2fb372`, Rust 1.98.1, and SDL 3.4.2. Alicorn selected
Direct3D12. `tools/build.ps1` completed and produced:

| Artifact | Bytes |
| --- | ---: |
| `alicorn-scope.exe` | 4,278,272 |
| `scope_backend.dll` | 6,247,002 |
| `caliber_ffi.dll` | 165,888 |
| `SDL3.dll` | 2,790,400 |

`alicorn-scope.exe --smoke ..\testdata\smoke-trace.json` opened an envelope-format
trace passed by argument, loaded two supported events and one unsupported
phase, copied the SCTR/SCEV resources, rendered, and exited successfully.

The 30-second native idle proof used the same small trace with
`--idle-proof-seconds=30`:

```text
host ticks                         0
application tick max              0 ns
application wake callbacks        1
application builds (startup/load) 3
GPU submissions                   2
event waits                       1
resource copies                   2
cached events                     2
```

The one wake and two submissions correspond to startup/load; the host then
waited for the remainder of the interval. The OS process CPU percentage was
not sampled, so this record proves event-driven host idleness, not a numeric
CPU-noise-floor claim.

## Go parser and bounded-window stress

`go test ./...` and `go vet ./...` pass. The required 100,000-event streaming
test passes as part of the normal suite. The opt-in million-event test is run
with:

```powershell
$env:SCOPE_STRESS = '1'
go test ./backend/trace -run '^TestMillionEventStreamingStress$' -count=1 -v
```

Observed in this run:

| Fixture | Parse + query + 512-row window + SCEV encode |
| --- | ---: |
| 1,000,000 events, repeated names/categories | 1.83 s |
| 1,000,000 events, unique event names | 2.59 s |

Each case retained a single track, returned exactly 512 rows from the middle
of the million-row result, and kept the encoded event resource below 1 MiB.
These measurements exclude Caliber transport and Odin decoding.

## Remaining platform gate

This run was performed on Windows only. The macOS build, native open dialog,
keyboard/track toggling, and the same 30-second idle proof remain to be run on
the user's Mac. The original blocking-wake validation used Caliber
`4814a5161809f37d07f8456b81988013f038867a`; Phase 0B later moved the runtime
dependency through `caliber update caliber` after the candidate passed Scope's
build hook. The current authoritative revision is in
`dependencies.lock.json`.

## Prior managed dependency resolver check (historical)

Validated on Windows on 2026-09-23 after starting without a Scope-owned
`.deps/` directory and with the sibling roots unset:

- `tools/bootstrap.ps1` cloned Alicorn `a0387156cea706b36411c2961394c6d03d227fe9`
  and Caliber `4814a5161809f37d07f8456b81988013f038867a` into `.deps/` and
  resolved both at the exact lockfile revisions.
- `tools/build.ps1` built Caliber, the Go shared backend, and the Odin app via
  the managed roots and `-collection:alicorn=...`.
- `tools/run.ps1 -Trace testdata/smoke-trace.json -Smoke` rebuilt through that
  same path, loaded the trace, rendered, and exited with PASS.
- `tools/bootstrap.sh` and all POSIX scripts passed `sh -n` under Git Bash;
  the shell bootstrap resolved the same managed pins. This checks shell syntax
  and resolver behavior on Windows, not a macOS/Linux native build.

The fresh-checkout GitHub Actions workflow called these build scripts on
Windows and macOS. These notes describe the earlier project-local resolver;
the Phase 0B section below records its replacement by Caliber.

## Phase 0B: Caliber dependency CLI and Scope migration

Validated on Windows on 2026-09-25:

- The CLI bootstrapped from the pinned Caliber source into Scope-owned
  `.tools/` using a local mirror of the pushed source commit for this test. The
  wrapper defaults to the public Caliber repository and does not require that
  mirror or a sibling checkout for a fresh developer clone.
- `caliber status` reported both managed checkouts locally without remote
  access. A second `sync` also passed with Git restricted to the `file`
  protocol, proving already-materialized locked objects require no network.
- `caliber update caliber` moved Scope from the former `4814a51` revision to
  the current Caliber commit only after the configured hook built the Caliber
  candidate, Go backend, and Odin Scope application.
- `tools/run.ps1 -Smoke` rebuilt from the new lock and passed the native SDL
  smoke (`alicorn-scope PASS`).
- `go test ./...` passed for both Scope Go packages.
- A build using the developer-owned `../alicorn` override passed with
  `-DevDeps`; its HEAD and worktree stayed unchanged.
- The POSIX wrappers and candidate hook passed `sh -n` under Git Bash. The
  POSIX `status` and offline `sync` wrapper calls also passed there.

The hosted fresh-checkout workflow has not run on this change. macOS/Linux
native builds and interactive checks remain outstanding.
