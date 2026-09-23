# Phase 2 — interactive timeline

## Implementation

Scope adds a time-indexed view beside the existing event table. Go keeps the
immutable trace and per-track indexes; Odin owns the viewport transform and
gesture state; Caliber carries one coalesced timeline request and one bounded
`SCTW` resource. A timeline request uses track ID `0` for all enabled tracks
when no track is selected, or the stable selected track ID for a focused
detailed lane. Track selection therefore changes the timeline at every catalog
size, not only when the track list exceeds its first 512-row page. The
unselected view presents a single collapsed all-track density overview; the
event table remains the place to inspect exact rows until a track is selected.

`Model.TraceBounds` returns the earliest event timestamp through the latest
complete-event end. Per-track interval indexes are sorted by `(timestamp,
source ordinal)` and use a max-end tree, so a time query includes complete
events that cross the viewport's left edge without scanning unrelated earlier
events. Windows use `[start,end)` semantics.

At most 128 matching events cross as raw identities. Above that threshold Go
emits temporal summaries with a shared 512-row budget across tracks. The
frontend projects raw complete events as spans and instant events as markers
in the selected track's full-height lane. Aggregate rows are combined into a
bounded 128-bin density overview (or focused-track density), with occupancy and
event count shaping the bars. A dark plot backing, restrained time grid/ruler,
and selected-event cursor make the visualization legible independently of the
event table. The same stable event ID selects the inspector and reveals the
corresponding event-table row. No trace-sized timeline payload or per-event
foreign calls are used.

### `SCTW` timeline resource, version 1

The resource is little-endian and string-free. Its 64-byte header contains:

```text
0..3    magic "SCTW"
4..5    u16 version = 1
6..7    u16 header size = 64
8..15   u64 trace generation
16..23  u64 query generation
24..27  u32 mode (1 raw, 2 aggregate)
28..31  u32 row count
32..39  u64 matching event count
40..47  f64 requested start timestamp (microseconds)
48..55  f64 requested end timestamp (microseconds)
56..63  u64 track ID (0 means all enabled tracks)
```

Each 40-byte raw row contains event ordinal, track ID, timestamp, duration,
event kind, and zeroed reserved bytes. Each aggregate row contains track ID,
bucket start/end, event count, and summed clipped duration. Odin validates the
header, generations, bounds, row limit, track identities, and finite numeric
fields before copying rows into its cache.

## Interaction and idle behavior

- Horizontal drag pans locally; the gesture submits at most one range request
  when released outside the current overscan cache.
- Ctrl+wheel zooms around the pointer on Windows/Linux; Command+wheel does so
  on macOS. Positive SDL wheel motion zooms in.
- Clicking a raw span/marker selects by event ID. Aggregate bars intentionally
  do not invent an event identity.
- `Home` fits the trace; `F` fits the selected event.
- Alicorn sends pointer-capture cancellation on focus loss. Scope drops an
  interrupted drag without leaving local capture state stuck.
- Timeline pointer events, range submissions, cache hits, decoded resources,
  and geometry updates are reported as `scope_timeline_metrics` at shutdown.

## Validation recorded on Windows x64

Using Odin `dev-2026-09-nightly:a2fb372`, Go 1.27.1 `windows/amd64`, Rust
1.98.1, and SDL 3.4.2:

- `go test ./...` and `go vet ./...` pass.
- The normal suite parses and queries a 100,000-event fixture and validates
  the bounded aggregate resource.
- The opt-in million-event stress passes with repeated and unique names. A
  full-range timeline extraction measured 20.5 ms and 20.2 ms respectively;
  each result encoded no more than 512 rows.
- Alicorn foundation tests pass, and both the SDL host and Scope executable
  compile.
- `--smoke` loads the small trace, decodes SCTR/SCEV/SCTW, updates timeline
  geometry, and exits cleanly.
- A five-second `--idle-proof-seconds=5` run produced 2 GPU submissions,
  3 application builds, 8 worker wake callbacks, 1 event wait, and 0 app ticks.
  It submitted one timeline request, decoded one timeline resource, and made
  3 geometry updates. The test did not sample process CPU; the settled period
  showed no recurring tick or presentation submissions.

The macOS native build and interactive pan/zoom/selection check remain to be
run. The Windows visual-control attempt was unavailable because the desktop
automation approval timed out; the native smoke and idle proof ran normally.

The timeline gesture path adds a public pointer callback, cancellation event,
and modifier state to Alicorn. These framework changes are committed and
published as `a0387156cea706b36411c2961394c6d03d227fe9`; Scope pins that exact
revision. The pinned `tools/build.ps1` packaging path has been run successfully
against the updated dependency lock.
