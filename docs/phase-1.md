# Phase 1 implementation contract

Scope is a read-only Chrome Trace Event explorer. Go owns trace bytes, parsed
records, query/filter semantics, stable identity and committed selection.
Caliber carries bounded commands, compact state, immutable track/event
resources and latest-value progress telemetry. Odin/Alicorn owns all
presentation state, interaction, virtualization and native wake integration.

## Resource formats

All integers are little-endian. UTF-8 strings are referenced by byte offset
and byte length in a resource-local string table; offsets are from the start
of that table. Producers must publish whole rows only and stay within both
the 512-row and 1 MiB payload limits. Consumers validate every size,
generation, range and string span before copying a row into frontend memory.

### `SCEV` event window, version 1

64-byte header: magic `SCEV`, `u16 version=1`, `u16 header_bytes=64`,
`u64 trace_generation`, `u64 query_generation`, `u64 first_row`,
`u64 total_count`, `u32 row_count`, `u32 row_bytes=56`, `u32 rows_offset=64`,
`u32 strings_offset`, `u32 strings_bytes`, `u32 reserved=0`.

Each 56-byte row contains `u64 event_ordinal`, `u64 track_id`, `f64 ts_us`,
`f64 dur_us`, `u32 flags` (`1=complete`, `2=instant`, `4=truncated strings`),
`u32 name_offset`, `u32 name_bytes`, `u32 category_offset`,
`u32 category_bytes`, `u32 reserved=0`.

### `SCTR` track catalog, version 1

The header uses the same layout with magic `SCTR`; `first_row` identifies the
track page and `query_generation` is the track-catalog revision. Each
64-byte row contains
`u64 track_id`, `i64 pid`, `i64 tid`, `i64 process_sort_index`,
`i64 thread_sort_index`, `u32 process_name_offset`, `u32 process_name_bytes`,
`u32 thread_name_offset`, `u32 thread_name_bytes`, `u32 flags`,
`u32 reserved=0`. Flag bits 0–6 describe identity/name/sort-index presence
and text truncation; bit 7 is `enabled`. Disabled tracks remain in the catalog
so the frontend can re-enable them. Track pages, like event windows, are
bounded to 512 rows and 1 MiB.

## Bounded inspector output

The selected-event inspector serializes arguments on demand. The serialized
output is capped at 64 KiB, nested values at depth 32, and displayed object
fields at 256. A result includes `truncated` and original serialized byte
length metadata. Arbitrary argument trees are not copied into every indexed
event.

## Window behavior

Track and event windows are bounded to 512 rows and slide around the requested
row, so a virtual-list viewport can straddle an old page edge without
alternating between two pages. Odin retains one decoded window of each kind,
including trace and query generations. Scrolling within a cached range performs
no foreign call. A missing range submits a per-domain latest-wins request. The
frontend rejects any response whose trace/query generation differs from current
state.

Caliber latest-value telemetry has five `size_t` values:
`phase`, `bytes_read`, `bytes_total`, `trace_generation`, and
`query_generation`. During JSON parsing the Go reader publishes progress at a
coalesced interval; Odin displays the latest percentage. Terminal phases
publish final byte counts. Telemetry notifications are transient and do not
cause periodic idle wakeups.

The Go shared library also exports `Scope_DirectEventWindow` as a benchmark-only
baseline. It requests the same query window and emits the same SCEV bytes, but
copies directly to caller memory without Caliber publish/map. It is not part
of the application-facing Odin function table.

## Shutdown

Stop backend work; stop Caliber wake waiters; join the Odin bridge thread;
release any outstanding mapped state/resource leases; then destroy the
Caliber context and Go backend. `context_destroy` is never used as a waiter
join operation.
