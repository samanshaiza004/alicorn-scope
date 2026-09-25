package trace

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestParseEnvelopeMetadataOrderingAndStableIdentity(t *testing.T) {
	input := `{"displayTimeUnit":"ms","traceEvents":[
		{"ph":"X","name":"later","cat":"ÜNICODE","ts":20.5,"dur":3.25,"pid":7,"tid":2,"args":{"nested":{"ok":true},"list":[1,2]}},
		{"ph":"B","name":"unsupported","ts":1,"pid":7,"tid":2},
		{"ph":"M","name":"thread_name","pid":7,"tid":2,"args":{"name":"worker 雪","sort_index":9}},
		{"ph":"I","name":"earlier","cat":"Render","ts":10,"pid":7,"tid":2},
		{"ph":"M","name":"process_name","pid":7,"args":{"name":"プロセス"}},
		{"ph":"M","name":"process_sort_index","pid":7,"args":{"sort_index":2}},
		{"ph":"M","name":"thread_sort_index","pid":7,"tid":2,"args":{"sort_index":4}},
		{"ph":"M","name":"ignored_metadata","args":null},
		{"ph":"X","name":"missing ids","ts":20,"dur":0},
		{"ph":"I","name":"explicit zero","ts":20,"pid":0,"tid":0}
	]}`

	model, err := Parse(strings.NewReader(input), 41)
	if err != nil {
		t.Fatal(err)
	}
	if model.TraceGeneration() != 41 || model.EventCount() != 4 || model.TrackCount() != 3 {
		t.Fatalf("unexpected model counts/generation: gen=%d events=%d tracks=%d", model.TraceGeneration(), model.EventCount(), model.TrackCount())
	}
	if model.UnsupportedPhaseCount() != 1 || model.InputRecordCount() != 10 {
		t.Fatalf("unsupported/input records = %d/%d", model.UnsupportedPhaseCount(), model.InputRecordCount())
	}
	all := model.NewEventQuery(nil, "")
	if all.Count() != 4 {
		t.Fatalf("query count = %d, want 4", all.Count())
	}
	page := all.Window(0, 512)
	wantOrdinals := []uint64{3, 8, 9, 0}
	if len(page.Rows) != len(wantOrdinals) {
		t.Fatalf("got %d rows", len(page.Rows))
	}
	for i, want := range wantOrdinals {
		if page.Rows[i].ID != want {
			t.Fatalf("row %d ID=%d, want source ordinal %d", i, page.Rows[i].ID, want)
		}
		row, found := all.RowForEventID(want)
		if !found || row != uint64(i) {
			t.Fatalf("stable event %d maps to query row %d (found=%t), want %d", want, row, found, i)
		}
	}
	if page.Rows[3].TimestampUS != 20.5 || page.Rows[3].DurationUS != 3.25 || page.Rows[3].Kind != EventComplete {
		t.Fatalf("timestamp/duration/kind were not preserved: %+v", page.Rows[3])
	}
	if page.Rows[0].Kind != EventInstant || page.Rows[0].DurationUS != 0 {
		t.Fatalf("instant semantics incorrect: %+v", page.Rows[0])
	}

	var track Track
	for _, candidate := range model.TrackWindow(0, 512).Rows {
		if candidate.PID == 7 && candidate.TID == 2 {
			track = candidate
		}
	}
	if track.ID == 0 || track.ProcessName != "プロセス" || track.ThreadName != "worker 雪" || track.ProcessSortIndex != 2 || track.ThreadSortIndex != 4 {
		t.Fatalf("metadata that arrived after events was not applied: %+v", track)
	}
	if !track.HasPID || !track.HasTID || !track.HasProcessName || !track.HasThreadName || !track.HasProcessSortIndex || !track.HasThreadSortIndex {
		t.Fatalf("metadata-presence flags missing: %+v", track)
	}
	if track.ProcessSortIndex != 2 {
		t.Fatalf("process sort index = %d", track.ProcessSortIndex)
	}
	var missing, explicitZero Track
	for _, candidate := range model.TrackWindow(0, 512).Rows {
		if !candidate.HasPID && !candidate.HasTID {
			missing = candidate
		}
		if candidate.HasPID && candidate.PID == 0 && candidate.HasTID && candidate.TID == 0 {
			explicitZero = candidate
		}
	}
	if missing.ID == 0 || explicitZero.ID == 0 || missing.ID == explicitZero.ID {
		t.Fatalf("absent ids and explicit zero ids must form distinct tracks: missing=%+v zero=%+v", missing, explicitZero)
	}
	details, ok := model.LookupEvent(0)
	if !ok || details.Event.Name != "later" || !json.Valid(details.ArgsJSON) || details.ArgsTruncated {
		t.Fatalf("stable event lookup failed: %+v, found=%v", details, ok)
	}
	if _, ok := model.LookupEvent(1); ok {
		t.Fatal("unsupported source record must not be returned as an event")
	}

	second, err := Parse(strings.NewReader(input), 42)
	if err != nil {
		t.Fatal(err)
	}
	if second.TraceGeneration() == model.TraceGeneration() || second.NewEventQuery(nil, "").Window(0, 1).Rows[0].ID != page.Rows[0].ID {
		t.Fatal("trace generation should be separate from stable source ordinals")
	}
	if second.TrackWindow(0, 512).Rows[0].ID != model.TrackWindow(0, 512).Rows[0].ID {
		t.Fatal("track ids should be deterministic from pid/tid within each generation")
	}
}

func TestParseTopLevelArrayAndEnvelopeValidation(t *testing.T) {
	model, err := Parse(strings.NewReader(`[{"ph":"X","name":"array","ts":2,"dur":1}]`), 1)
	if err != nil {
		t.Fatal(err)
	}
	details, found := model.LookupEvent(0)
	if model.EventCount() != 1 || !found || details.Event.Name != "array" {
		t.Fatal("top-level array was not parsed")
	}
	for _, input := range []string{
		`{"traceEvents":{}}`,
		`{"other":[]}`,
		`[] {}`,
		`[{"ph":"X","name":"bad","ts":1}]`,
		`[{"ph":"I","name":"bad","ts":"NaN"}]`,
	} {
		if _, err := Parse(strings.NewReader(input), 1); err == nil {
			t.Errorf("Parse(%s) unexpectedly succeeded", input)
		}
	}
	wrapped, err := Parse(strings.NewReader(`{"metadata":{"nested":[1,{"x":true}]},"displayTimeUnit":"ms","traceEvents":[{"ph":"I","name":"wrapped","ts":3}]}`), 2)
	if err != nil {
		t.Fatalf("unknown envelope fields should be skipped incrementally: %v", err)
	}
	if details, ok := wrapped.LookupEvent(0); !ok || details.Event.Name != "wrapped" {
		t.Fatal("traceEvents after unknown envelope fields was not parsed")
	}
}

func TestLoadAndBoundedArguments(t *testing.T) {
	path := filepath.Join(t.TempDir(), "trace.json")
	large := strings.Repeat("x", MaxInspectorArgsBytes+100)
	input := fmt.Sprintf(`[{"ph":"X","name":"large","ts":0,"dur":1,"args":{"value":%q}},{"ph":"I","name":"deep","ts":1,"args":%s}]`, large, deepJSON(MaxInspectorDepth+2))
	if err := os.WriteFile(path, []byte(input), 0o600); err != nil {
		t.Fatal(err)
	}
	model, err := Load(path, 5)
	if err != nil {
		t.Fatal(err)
	}
	for _, ordinal := range []uint64{0, 1} {
		details, ok := model.LookupEvent(ordinal)
		if !ok || !details.ArgsTruncated || details.ArgsOriginalBytes == 0 || len(details.ArgsJSON) != 0 {
			t.Errorf("event %d arguments not bounded: %+v", ordinal, details)
		}
	}
}

func TestQueriesFilterTracksAndClampWindows(t *testing.T) {
	model, err := Parse(strings.NewReader(`[{"ph":"X","name":"Ünicode Name","cat":"Render","ts":4,"dur":1,"pid":1,"tid":2},{"ph":"X","name":"other","cat":"input","ts":3,"dur":1,"pid":2,"tid":3}]`), 2)
	if err != nil {
		t.Fatal(err)
	}
	tracks := model.TrackWindow(0, 512).Rows
	var firstID uint64
	for _, track := range tracks {
		if track.PID == 1 {
			firstID = track.ID
		}
	}
	if firstID == 0 {
		t.Fatal("track ID for pid=1 not found")
	}
	query := model.NewEventQuery([]uint64{firstID}, "ünICODE")
	if query.Count() != 1 || query.Window(99, 4).FirstRow != 1 || len(query.Window(0, 999).Rows) != 1 {
		t.Fatal("filtering, enabled tracks, or window clamping failed")
	}
	if model.NewEventQuery([]uint64{}, "").Count() != 0 {
		t.Fatal("non-nil empty enabled-track set should select no tracks")
	}
	if model.NewEventQuery(nil, "render").Count() != 1 {
		t.Fatal("nil enabled-track set should mean all tracks")
	}
	if _, found := model.NewEventQuery(nil, "render").RowForEventID(1); found {
		t.Fatal("filtered-out event unexpectedly resolved to a query row")
	}
}

func TestTimelineWindowUsesTrackIntervalIndexAndTraceBounds(t *testing.T) {
	input := `[
		{"ph":"X","name":"crossing","ts":0,"dur":20,"pid":1,"tid":1},
		{"ph":"I","name":"at-start","ts":10,"pid":1,"tid":1},
		{"ph":"X","name":"tie-b","ts":12,"dur":2,"pid":1,"tid":1},
		{"ph":"X","name":"tie-a","ts":12,"dur":1,"pid":1,"tid":1},
		{"ph":"X","name":"outside","ts":20,"dur":1,"pid":1,"tid":1},
		{"ph":"I","name":"other-track","ts":13,"pid":2,"tid":1}
	]`
	model, err := Parse(strings.NewReader(input), 8)
	if err != nil {
		t.Fatal(err)
	}
	start, end, ok := model.TraceBounds()
	if !ok || start != 0 || end != math.Nextafter(21, math.Inf(1)) {
		t.Fatalf("trace bounds=(%v,%v,%v), want (0,%v,true)", start, end, math.Nextafter(21, math.Inf(1)), ok)
	}
	tracks := model.TrackWindow(0, 512).Rows
	var trackID uint64
	for _, track := range tracks {
		if track.PID == 1 {
			trackID = track.ID
		}
	}
	query := model.NewEventQuery([]uint64{trackID}, "")
	window := query.TimelineWindow(trackID, 10, 15, 16, 8, 9)
	wantIDs := []uint64{0, 1, 2, 3}
	if window.Mode != TimelineRaw || window.TotalEventCount != uint64(len(wantIDs)) || len(window.Rows) != len(wantIDs) {
		t.Fatalf("unexpected time query shape: %+v", window)
	}
	for i, want := range wantIDs {
		if window.Rows[i].EventID != want {
			t.Errorf("timeline row %d id=%d, want %d", i, window.Rows[i].EventID, want)
		}
	}
	if got := query.TimelineWindow(trackID, 10, 15, 4, 8, 9).TotalEventCount; got != 4 {
		t.Fatalf("resolution hint changed raw match count: %d", got)
	}
	if got := query.TimelineWindow(tracks[1].ID, 10, 15, 8, 8, 9).TotalEventCount; got != 0 {
		t.Fatalf("disabled track returned timeline events: %d", got)
	}
	allTracks := model.NewEventQuery(nil, "").TimelineWindow(0, 0, 21, 16, 8, 9)
	if allTracks.TotalEventCount != 6 || len(allTracks.Rows) != 6 {
		t.Fatalf("all-track timeline returned %d events in %d rows, want 6", allTracks.TotalEventCount, len(allTracks.Rows))
	}
	seenTracks := map[uint64]bool{}
	for _, row := range allTracks.Rows {
		seenTracks[row.TrackID] = true
	}
	if len(seenTracks) != 2 {
		t.Fatalf("all-track timeline represented %d tracks, want 2", len(seenTracks))
	}
	filtered := model.NewEventQuery([]uint64{trackID}, "tie")
	if got := filtered.TimelineWindow(trackID, 10, 15, 8, 8, 10).TotalEventCount; got != 2 {
		t.Fatalf("timeline did not honor the immutable query filter: %d", got)
	}
	if got := query.TimelineWindow(trackID, math.NaN(), 15, 8, 8, 9); len(got.Rows) != 0 {
		t.Fatal("invalid time range should produce an empty bounded window")
	}
}

func TestTraceBoundsIncludeInstantAtMaximumTimestamp(t *testing.T) {
	input := `[
		{"ph":"X","name":"complete","ts":1,"dur":2,"pid":1,"tid":1},
		{"ph":"I","name":"last instant","ts":3,"pid":1,"tid":1}
	]`
	model, err := Parse(strings.NewReader(input), 12)
	if err != nil {
		t.Fatal(err)
	}

	startUS, endUS, ok := model.TraceBounds()
	if !ok || startUS != 1 || endUS != math.Nextafter(3, math.Inf(1)) {
		t.Fatalf("trace bounds=(%v,%v,%v), want (1,%v,true)", startUS, endUS, ok, math.Nextafter(3, math.Inf(1)))
	}

	window := model.NewEventQuery(nil, "").TimelineWindow(0, startUS, endUS, 16, 12, 1)
	if window.TotalEventCount != 2 || len(window.Rows) != 2 {
		t.Fatalf("full-trace timeline has %d events and %d rows, want 2", window.TotalEventCount, len(window.Rows))
	}
	if window.Rows[1].EventID != 1 {
		t.Fatalf("last timeline event id=%d, want instant id 1", window.Rows[1].EventID)
	}
}

func TestTimelineWindowSwitchesToBoundedAggregates(t *testing.T) {
	var input strings.Builder
	input.WriteByte('[')
	for i := range MaxTimelineRawEvents + 23 {
		if i > 0 {
			input.WriteByte(',')
		}
		fmt.Fprintf(&input, `{"ph":"X","name":"event","ts":%d,"dur":2,"pid":1,"tid":1}`, i)
	}
	input.WriteByte(']')
	model, err := Parse(strings.NewReader(input.String()), 17)
	if err != nil {
		t.Fatal(err)
	}
	trackID := model.tracks[0].ID
	query := model.NewEventQuery(nil, "")
	window := query.TimelineWindow(trackID, 0, MaxTimelineRawEvents+23, 48, 17, 21)
	if window.Mode != TimelineAggregate || window.TotalEventCount != MaxTimelineRawEvents+23 || len(window.Rows) != 48 {
		t.Fatalf("unbounded or incorrect aggregate response: mode=%d total=%d rows=%d", window.Mode, window.TotalEventCount, len(window.Rows))
	}
	var aggregated uint64
	for _, row := range window.Rows {
		aggregated += row.EventCount
	}
	if aggregated != window.TotalEventCount {
		t.Fatalf("aggregate buckets contain %d events, want %d", aggregated, window.TotalEventCount)
	}
}

func TestAllTrackTimelineAggregationStaysWithinSharedBudget(t *testing.T) {
	var input strings.Builder
	input.WriteByte('[')
	for track := 0; track < 2; track++ {
		for i := range MaxTimelineRawEvents + 1 {
			if input.Len() > 1 {
				input.WriteByte(',')
			}
			fmt.Fprintf(&input, `{"ph":"X","name":"event","ts":%d,"dur":2,"pid":%d,"tid":1}`, i, track+1)
		}
	}
	input.WriteByte(']')
	model, err := Parse(strings.NewReader(input.String()), 19)
	if err != nil {
		t.Fatal(err)
	}
	window := model.NewEventQuery(nil, "").TimelineWindow(0, 0, MaxTimelineRawEvents+2, 256, 19, 20)
	if window.Mode != TimelineAggregate || window.TotalEventCount != 2*(MaxTimelineRawEvents+1) || len(window.Rows) != MaxTimelineRows {
		t.Fatalf("all-track aggregate exceeded or underused its shared budget: mode=%d events=%d rows=%d", window.Mode, window.TotalEventCount, len(window.Rows))
	}
	counts := map[uint64]uint64{}
	for _, row := range window.Rows {
		counts[row.TrackID] += row.EventCount
	}
	if len(counts) != 2 {
		t.Fatalf("all-track aggregate counts do not preserve both tracks: %+v", counts)
	}
	for trackID, count := range counts {
		if trackID == 0 || count != MaxTimelineRawEvents+1 {
			t.Fatalf("all-track aggregate count for track %d is %d", trackID, count)
		}
	}
	resource, err := EncodeTimelineWindow(window)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeTimelineResource(resource)
	if err != nil || decoded.TrackID != 0 || len(decoded.Rows) != MaxTimelineRows {
		t.Fatalf("all-track resource failed validation: track=%d rows=%d err=%v", decoded.TrackID, len(decoded.Rows), err)
	}
}

func TestTimelineResourceRoundTripAndValidation(t *testing.T) {
	window := TimelineWindow{
		TraceGeneration: 5,
		QueryGeneration: 6,
		TrackID:         4,
		Mode:            TimelineRaw,
		StartUS:         10,
		EndUS:           20,
		TotalEventCount: 1,
		Rows:            []TimelineRow{{EventID: 0, TrackID: 4, TimestampUS: 12.5, DurationUS: 2, Kind: EventComplete}},
	}
	data, err := EncodeTimelineWindow(window)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeTimelineResource(data)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.TraceGeneration != 5 || decoded.QueryGeneration != 6 || decoded.Mode != TimelineRaw || len(decoded.Rows) != 1 || decoded.Rows[0] != window.Rows[0] {
		t.Fatalf("timeline round trip differs: %+v", decoded)
	}
	window.Mode = TimelineAggregate
	window.TotalEventCount = 1000
	window.Rows = []TimelineRow{{TrackID: 4, BucketStartUS: 10, BucketEndUS: 20, EventCount: 1000, DurationSumUS: 2}}
	data, err = EncodeTimelineWindow(window)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err = DecodeTimelineResource(data)
	if err != nil || decoded.Mode != TimelineAggregate || decoded.TotalEventCount != 1000 || decoded.Rows[0].EventCount != 1000 {
		t.Fatalf("aggregate timeline round trip failed: %+v, %v", decoded, err)
	}
	for i := 64; i < 72; i++ {
		data[i] = 0
	}
	if _, err := DecodeTimelineResource(data); err == nil {
		t.Fatal("decoder accepted a missing track identity")
	}
}

func TestEventResourceRoundTripAndGenerationHeader(t *testing.T) {
	model, err := Parse(strings.NewReader(`[{"ph":"X","name":"A name","cat":"cat","ts":12.5,"dur":2.25,"pid":7,"tid":9},{"ph":"I","name":"instant","cat":"cat","ts":12.5,"pid":7,"tid":9}]`), 77)
	if err != nil {
		t.Fatal(err)
	}
	query := model.NewEventQuery(nil, "")
	page := query.Window(0, 2)
	data, err := EncodeEventWindow(query, page, 77, 13)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) > MaxResourceBytes || string(data[:4]) != EventResourceMagic {
		t.Fatalf("invalid event resource envelope length=%d magic=%q", len(data), data[:4])
	}
	decoded, err := DecodeEventResource(data)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Header.TraceGeneration != 77 || decoded.Header.QueryGeneration != 13 || decoded.Header.FirstRow != 0 || decoded.Header.TotalCount != 2 || decoded.Header.RowCount != 2 || decoded.Header.RowSize != EventResourceRowSize {
		t.Fatalf("unexpected event resource header: %+v", decoded.Header)
	}
	if decoded.Rows[0].EventID != 0 || decoded.Rows[0].TimestampUS != 12.5 || decoded.Rows[0].DurationUS != 2.25 || decoded.Rows[0].Flags != EventFlagComplete || decoded.Rows[0].Name != "A name" || decoded.Rows[0].Category != "cat" {
		t.Fatalf("complete event round trip failed: %+v", decoded.Rows[0])
	}
	if decoded.Rows[1].EventID != 1 || decoded.Rows[1].Flags != EventFlagInstant {
		t.Fatalf("instant event round trip failed: %+v", decoded.Rows[1])
	}
	mutated := page
	mutated.Rows = append([]Event(nil), page.Rows...)
	mutated.Rows[0].Name = "tampered"
	if _, err := EncodeEventWindow(query, mutated, 77, 13); err == nil {
		t.Fatal("encoder accepted a page modified after query extraction")
	}
	if _, err := EncodeEventWindow(model.NewEventQuery(nil, ""), page, 77, 13); err == nil {
		t.Fatal("encoder accepted a page from a different query")
	}
}

func TestTrackCatalogEnabledFlagsAndRoundTrip(t *testing.T) {
	model, err := Parse(strings.NewReader(`[
		{"ph":"X","name":"one","ts":1,"dur":1,"pid":2,"tid":3},
		{"ph":"M","name":"process_name","pid":2,"args":{"name":"proc"}},
		{"ph":"M","name":"thread_name","pid":2,"tid":3,"args":{"name":"main"}},
		{"ph":"M","name":"process_sort_index","pid":2,"args":{"sort_index":7}},
		{"ph":"M","name":"thread_sort_index","pid":2,"tid":3,"args":{"sort_index":8}},
		{"ph":"X","name":"two","ts":2,"dur":1,"pid":4,"tid":5}
	]`), 9)
	if err != nil {
		t.Fatal(err)
	}
	tracks := model.TrackWindow(0, 512).Rows
	if len(tracks) != 2 {
		t.Fatalf("got %d tracks", len(tracks))
	}
	var enabledID uint64
	for _, track := range tracks {
		if track.PID == 2 {
			enabledID = track.ID
		}
	}
	data, err := EncodeTrackCatalog(model, []uint64{enabledID}, 0, 512, 9, 3)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeTrackResource(data)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Header.TraceGeneration != 9 || decoded.Header.QueryGeneration != 3 || decoded.Header.TotalCount != 2 || len(decoded.Rows) != 2 {
		t.Fatalf("track catalog page/header failed: %+v", decoded.Header)
	}
	var selected, disabled *TrackResourceRow
	for i := range decoded.Rows {
		if decoded.Rows[i].Track.ID == enabledID {
			selected = &decoded.Rows[i]
		} else {
			disabled = &decoded.Rows[i]
		}
	}
	if selected == nil || disabled == nil || !selected.Enabled || disabled.Enabled {
		t.Fatalf("track enabled flags were not preserved: %+v", decoded.Rows)
	}
	track := selected.Track
	if track.ID != enabledID || track.PID != 2 || track.TID != 3 || track.ProcessName != "proc" || track.ThreadName != "main" || track.ProcessSortIndex != 7 || track.ThreadSortIndex != 8 {
		t.Fatalf("track round trip failed: %+v", track)
	}
	if selected.Flags&TrackFlagHasPID == 0 || selected.Flags&TrackFlagHasThreadSortIndex == 0 || selected.Flags&TrackFlagEnabled == 0 {
		t.Fatalf("track flags missing: %#x", selected.Flags)
	}
	empty, err := EncodeTrackCatalog(model, []uint64{}, 0, 512, 9, 3)
	if err != nil {
		t.Fatal(err)
	}
	emptyDecoded, err := DecodeTrackResource(empty)
	if err != nil || len(emptyDecoded.Rows) != 2 || emptyDecoded.Header.TotalCount != 2 || emptyDecoded.Rows[0].Enabled || emptyDecoded.Rows[1].Enabled {
		t.Fatalf("empty enabled set should preserve disabled catalog rows: %+v err=%v", emptyDecoded, err)
	}
}

func TestResourceTruncationAndValidation(t *testing.T) {
	var source strings.Builder
	source.WriteByte('[')
	for i := 0; i < MaxWindowRows; i++ {
		if i != 0 {
			source.WriteByte(',')
		}
		name := strings.Repeat("雪", 900) + fmt.Sprintf("-%03d", i)
		encodedName, _ := json.Marshal(name)
		fmt.Fprintf(&source, `{"ph":"X","name":%s,"cat":%s,"ts":%d,"dur":1,"pid":1,"tid":1}`, encodedName, encodedName, i)
	}
	source.WriteByte(']')
	model, err := Parse(strings.NewReader(source.String()), 1)
	if err != nil {
		t.Fatal(err)
	}
	query := model.NewEventQuery(nil, "")
	data, err := EncodeEventWindow(query, query.Window(0, MaxWindowRows), 1, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) > MaxResourceBytes {
		t.Fatalf("event resource is %d bytes", len(data))
	}
	decoded, err := DecodeEventResource(data)
	if err != nil {
		t.Fatal(err)
	}
	for i, row := range decoded.Rows {
		if row.Flags&EventFlagTextTruncated == 0 || !utf8.ValidString(row.Name) {
			t.Fatalf("row %d should report safe UTF-8 text truncation: flags=%#x bytes=%d", i, row.Flags, len(row.Name))
		}
	}
	if _, err := DecodeEventResource(data[:len(data)-1]); err == nil {
		t.Fatal("decoder accepted truncated resource bytes")
	}
	tooMany := EventPage{TotalCount: MaxWindowRows + 1, Rows: make([]Event, MaxWindowRows+1)}
	if _, err := encodeEventPage(1, 2, tooMany); err == nil {
		t.Fatal("event encoder should enforce the 512-row cap")
	}
}

func TestTrackResourceBoundsAndMissingSortSentinels(t *testing.T) {
	var source strings.Builder
	source.WriteByte('[')
	for i := 0; i < MaxWindowRows; i++ {
		if i != 0 {
			source.WriteByte(',')
		}
		fmt.Fprintf(&source, `{"ph":"X","name":"event","ts":%d,"dur":1,"pid":%d}`, i, i+1)
		name := strings.Repeat("界", 900) + fmt.Sprintf("-%03d", i)
		encodedName, _ := json.Marshal(name)
		fmt.Fprintf(&source, `,{"ph":"M","name":"process_name","pid":%d,"args":{"name":%s}}`, i+1, encodedName)
	}
	source.WriteByte(']')
	model, err := Parse(strings.NewReader(source.String()), 4)
	if err != nil {
		t.Fatal(err)
	}
	data, err := EncodeTrackCatalog(model, nil, 0, MaxWindowRows, 4, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) > MaxResourceBytes {
		t.Fatalf("track resource is %d bytes", len(data))
	}
	decoded, err := DecodeTrackResource(data)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Header.RowCount != MaxWindowRows || decoded.Header.TotalCount != MaxWindowRows {
		t.Fatalf("unexpected track resource counts: %+v", decoded.Header)
	}
	for i, row := range decoded.Rows {
		if row.Flags&TrackFlagTextTruncated == 0 || !utf8.ValidString(row.Track.ProcessName) {
			t.Fatalf("track row %d should have safe UTF-8 truncation, flags=%#x", i, row.Flags)
		}
		if row.Track.HasTID || row.Track.ThreadSortIndex != MissingSortIndex || row.Track.ProcessSortIndex != MissingSortIndex {
			t.Fatalf("absent ids/sort indexes were not preserved: %+v", row.Track)
		}
	}
}

func TestHundredThousandEventStreamingAndBoundedWindows(t *testing.T) {
	const count = 100_000
	var source strings.Builder
	source.Grow(count * 75)
	source.WriteByte('[')
	for i := 0; i < count; i++ {
		if i != 0 {
			source.WriteByte(',')
		}
		fmt.Fprintf(&source, `{"ph":"X","name":"Repeated","cat":"render","ts":%d,"dur":2,"pid":1,"tid":1}`, count-i)
	}
	source.WriteByte(']')
	model, err := Parse(strings.NewReader(source.String()), 8)
	if err != nil {
		t.Fatal(err)
	}
	if model.EventCount() != count || model.TrackCount() != 1 {
		t.Fatalf("parsed event/track counts = %d/%d", model.EventCount(), model.TrackCount())
	}
	query := model.NewEventQuery(nil, "repeat")
	if query.Count() != count {
		t.Fatalf("query count = %d", query.Count())
	}
	page := query.Window(12_440, 512)
	if len(page.Rows) != 512 || page.Rows[0].TimestampUS >= page.Rows[1].TimestampUS {
		t.Fatal("100k query window is not bounded and timestamp-ordered")
	}
	resource, err := EncodeEventWindow(query, page, 8, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(resource) > MaxResourceBytes {
		t.Fatalf("bounded event window encoded to %d bytes", len(resource))
	}
	trackID := model.tracks[0].ID
	traceStart, traceEnd, ok := model.TraceBounds()
	if !ok {
		t.Fatal("100k trace is missing its time bounds")
	}
	timeline := query.TimelineWindow(0, traceStart, traceEnd, 256, 8, 2)
	if timeline.Mode != TimelineAggregate || timeline.TotalEventCount != count || len(timeline.Rows) > MaxTimelineRows {
		t.Fatalf("100k timeline exceeded its bounded aggregate: mode=%d events=%d rows=%d", timeline.Mode, timeline.TotalEventCount, len(timeline.Rows))
	}
	if timeline.Rows[0].TrackID != trackID {
		t.Fatal("100k timeline lost its stable track identity")
	}
	timelineResource, err := EncodeTimelineWindow(timeline)
	if err != nil {
		t.Fatal(err)
	}
	if len(timelineResource) > MaxResourceBytes {
		t.Fatalf("bounded timeline encoded to %d bytes", len(timelineResource))
	}
}

type generatedTraceReader struct {
	total        int
	next         int
	uniqueNames  bool
	startWritten bool
	endWritten   bool
	pending      []byte
}

func TestGeneratedStressReaderIsValidJSON(t *testing.T) {
	for _, uniqueNames := range []bool{false, true} {
		model, err := Parse(&generatedTraceReader{total: 3, uniqueNames: uniqueNames}, 1)
		if err != nil {
			t.Fatal(err)
		}
		if model.EventCount() != 3 {
			t.Fatalf("unique names %t: event count = %d", uniqueNames, model.EventCount())
		}
	}
}

func (r *generatedTraceReader) Read(dst []byte) (int, error) {
	if len(dst) == 0 {
		return 0, nil
	}
	written := 0
	for written < len(dst) {
		if len(r.pending) == 0 {
			switch {
			case !r.startWritten:
				r.pending = []byte{'['}
				r.startWritten = true
			case r.next < r.total:
				ordinal := r.next
				r.next++
				line := make([]byte, 0, 128)
				if ordinal != 0 {
					line = append(line, ',')
				}
				line = append(line, `{"ph":"X","name":"`...)
				if r.uniqueNames {
					line = append(line, "event-"...)
					line = strconv.AppendInt(line, int64(ordinal), 10)
				} else {
					line = append(line, "Repeated"...)
				}
				line = append(line, `","cat":"render","ts":`...)
				line = strconv.AppendInt(line, int64(r.total-ordinal), 10)
				line = append(line, `,"dur":2,"pid":1,"tid":1}`...)
				r.pending = line
			case !r.endWritten:
				r.pending = []byte{']'}
				r.endWritten = true
			default:
				if written == 0 {
					return 0, io.EOF
				}
				return written, nil
			}
		}
		n := copy(dst[written:], r.pending)
		written += n
		r.pending = r.pending[n:]
	}
	return written, nil
}

func TestMillionEventStreamingStress(t *testing.T) {
	if os.Getenv("SCOPE_STRESS") != "1" {
		t.Skip("set SCOPE_STRESS=1 to run the 1,000,000-event memory/throughput stress")
	}
	for _, uniqueNames := range []bool{false, true} {
		name := "repeated names/categories"
		if uniqueNames {
			name = "unique event names"
		}
		t.Run(name, func(t *testing.T) {
			model, err := Parse(&generatedTraceReader{total: 1_000_000, uniqueNames: uniqueNames}, 77)
			if err != nil {
				t.Fatal(err)
			}
			if model.EventCount() != 1_000_000 || model.TrackCount() != 1 {
				t.Fatalf("parsed counts = events:%d tracks:%d", model.EventCount(), model.TrackCount())
			}
			query := model.NewEventQuery(nil, "")
			page := query.Window(500_000, 512)
			if page.FirstRow != 500_000 || len(page.Rows) != 512 || page.TotalCount != 1_000_000 {
				t.Fatalf("bounded window = first:%d rows:%d total:%d", page.FirstRow, len(page.Rows), page.TotalCount)
			}
			resource, err := EncodeEventWindow(query, page, 77, 5)
			if err != nil {
				t.Fatal(err)
			}
			if len(resource) > MaxResourceBytes {
				t.Fatalf("event resource has %d bytes", len(resource))
			}
			traceStart, traceEnd, ok := model.TraceBounds()
			if !ok {
				t.Fatal("million-event trace is missing its time bounds")
			}
			timelineStarted := time.Now()
			timeline := query.TimelineWindow(0, traceStart, traceEnd, 256, 77, 6)
			t.Logf("full-range timeline extraction: %s", time.Since(timelineStarted))
			if timeline.Mode != TimelineAggregate || timeline.TotalEventCount != 1_000_000 || len(timeline.Rows) != 256 {
				t.Fatalf("million-event timeline was not bounded: mode=%d total=%d rows=%d", timeline.Mode, timeline.TotalEventCount, len(timeline.Rows))
			}
			timelineResource, err := EncodeTimelineWindow(timeline)
			if err != nil {
				t.Fatal(err)
			}
			if len(timelineResource) > MaxResourceBytes {
				t.Fatalf("million-event timeline resource has %d bytes", len(timelineResource))
			}
		})
	}
}

func TestResourceRejectsBadFlagsAndOversizedPages(t *testing.T) {
	page := EventPage{TotalCount: MaxWindowRows + 1, Rows: make([]Event, MaxWindowRows+1)}
	if _, err := encodeEventPage(1, 1, page); err == nil {
		t.Fatal("encoder accepted more than 512 rows")
	}
	model, err := Parse(strings.NewReader(`[{"ph":"I","name":"one","ts":1}]`), 1)
	if err != nil {
		t.Fatal(err)
	}
	query := model.NewEventQuery(nil, "")
	data, err := EncodeEventWindow(query, query.Window(0, 1), 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	data[64+32] = 0xff
	if _, err := DecodeEventResource(data); err == nil {
		t.Fatal("decoder accepted an unknown event flag")
	}
}

func deepJSON(levels int) string {
	return strings.Repeat("[", levels) + `0` + strings.Repeat("]", levels)
}

func TestResourcePreservesFloatingPointBits(t *testing.T) {
	model, err := Parse(strings.NewReader(`[{"ph":"X","name":"precise","ts":0.0000001,"dur":-0.25}]`), 1)
	if err != nil {
		t.Fatal(err)
	}
	query := model.NewEventQuery(nil, "")
	data, err := EncodeEventWindow(query, query.Window(0, 1), 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeEventResource(data)
	if err != nil {
		t.Fatal(err)
	}
	if math.Float64bits(decoded.Rows[0].TimestampUS) != math.Float64bits(0.0000001) || math.Float64bits(decoded.Rows[0].DurationUS) != math.Float64bits(-0.25) {
		t.Fatal("event times did not round-trip as float64")
	}
}
