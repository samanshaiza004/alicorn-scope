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
the user's Mac. Caliber's blocking wake ABI has since been committed and pushed
as `4814a5161809f37d07f8456b81988013f038867a`; `dependencies.lock.json` pins
that revision so a clean checkout can build against the published ABI.
