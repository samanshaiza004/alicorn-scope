package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/samanshaiza004/alicorn-scope/backend/trace"
)

func TestInspectorArgumentsStayWithinLimits(t *testing.T) {
	input := []byte(`{"large":"` + strings.Repeat("界", 30<<10) + `","small":1}`)
	arguments, truncated := inspectorArguments(input)
	encoded, err := json.Marshal(arguments)
	if err != nil {
		t.Fatal(err)
	}
	if !truncated {
		t.Fatal("oversized inspector output was not marked truncated")
	}
	if len(arguments) > serviceMaxArguments {
		t.Fatalf("got %d arguments; limit is %d", len(arguments), serviceMaxArguments)
	}
	if len(encoded) > trace.MaxInspectorArgsBytes {
		t.Fatalf("encoded arguments are %d bytes; limit is %d", len(encoded), trace.MaxInspectorArgsBytes)
	}

	var array strings.Builder
	array.WriteByte('[')
	for i := 0; i < serviceMaxArguments+20; i++ {
		if i != 0 {
			array.WriteByte(',')
		}
		fmt.Fprint(&array, i)
	}
	array.WriteByte(']')
	arguments, _ = inspectorArguments([]byte(array.String()))
	if len(arguments) != serviceMaxArguments {
		t.Fatalf("got %d arguments; wanted cap %d", len(arguments), serviceMaxArguments)
	}
}

func TestInterruptibleReaderAccumulatesBytesAcrossReads(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "trace-reader-*.json")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	payload := []byte("0123456789")
	if _, err := file.Write(payload); err != nil {
		t.Fatal(err)
	}
	if _, err := file.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	service := &backendService{stop: make(chan struct{})}
	service.latestOpen.Store(5)
	reader := &interruptibleTraceReader{
		file:             file,
		service:          service,
		openSequence:     5,
		totalBytes:       uint64(len(payload)),
		lastProgressSent: time.Now().Add(time.Hour), // avoid requiring a Caliber context in this unit test
	}
	buffer := make([]byte, 4)
	for index, want := range []int{4, 4, 2} {
		if n, err := reader.Read(buffer); err != nil || n != want {
			t.Fatalf("read %d: n=%d err=%v; want n=%d", index, n, err, want)
		}
		wantRead := uint64((index + 1) * 4)
		if index == 2 {
			wantRead = uint64(len(payload))
		}
		if reader.bytesRead != wantRead {
			t.Fatalf("cumulative bytes_read = %d after read %d; want %d", reader.bytesRead, index, wantRead)
		}
	}
}

func TestParseTraceReportsRawFileByteCounts(t *testing.T) {
	payload := []byte(`{"traceEvents":[]}`)
	path := t.TempDir() + string(os.PathSeparator) + "trace.json"
	if err := os.WriteFile(path, payload, 0600); err != nil {
		t.Fatal(err)
	}
	service := &backendService{stop: make(chan struct{})}
	service.latestOpen.Store(3)
	model, bytesRead, bytesTotal, err := parseTrace(path, 1, service, 3)
	if err != nil {
		t.Fatal(err)
	}
	if model == nil || model.EventCount() != 0 {
		t.Fatalf("parsed model = %#v; want an empty trace model", model)
	}
	if bytesRead != uint64(len(payload)) || bytesTotal != uint64(len(payload)) {
		t.Fatalf("parse byte counts = (%d, %d); want raw file size %d", bytesRead, bytesTotal, len(payload))
	}
	words := progressTelemetryWords(telemetryReady, bytesRead, bytesTotal, 7, 11)
	want := [5]uint64{telemetryReady, uint64(len(payload)), uint64(len(payload)), 7, 11}
	if words != want {
		t.Fatalf("terminal telemetry words = %v; want phase/read-bytes/total-bytes/generations %v", words, want)
	}
}

func TestWindowCommandCoalescingKeepsNewest(t *testing.T) {
	var latest *serviceCommand
	latest = coalesceWindowCommand(latest, serviceCommand{Sequence: 7})
	latest = coalesceWindowCommand(latest, serviceCommand{Sequence: 9})
	latest = coalesceWindowCommand(latest, serviceCommand{Sequence: 8})
	if latest == nil || latest.Sequence != 9 {
		t.Fatalf("coalesced sequence = %v; want 9", latest)
	}
}

func TestTrackWindowCommandCoalescingKeepsNewest(t *testing.T) {
	var latest *serviceCommand
	latest = coalesceWindowCommand(latest, serviceCommand{Kind: "track_window", Sequence: 12, FirstRow: 0})
	latest = coalesceWindowCommand(latest, serviceCommand{Kind: "track_window", Sequence: 14, FirstRow: 1024})
	latest = coalesceWindowCommand(latest, serviceCommand{Kind: "track_window", Sequence: 13, FirstRow: 512})
	if latest == nil || latest.Sequence != 14 || latest.FirstRow != 1024 {
		t.Fatalf("coalesced track page = %+v; want newest request at row 1024", latest)
	}
}

func TestWindowFreshnessRejectsStaleGenerationAndRequest(t *testing.T) {
	request := serviceCommand{
		TraceGeneration: 3,
		QueryGeneration: 5,
		Sequence:        11,
		ControlEpoch:    17,
	}
	cases := []struct {
		name  string
		trace uint64
		query uint64
		seq   uint64
		epoch uint64
		want  bool
	}{
		{name: "current", trace: 3, query: 5, seq: 11, epoch: 17, want: true},
		{name: "old trace", trace: 2, query: 5, seq: 11, epoch: 17},
		{name: "old query", trace: 3, query: 4, seq: 11, epoch: 17},
		{name: "superseded request", trace: 3, query: 5, seq: 12, epoch: 17},
		{name: "changed controls", trace: 3, query: 5, seq: 11, epoch: 18},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			got := windowRequestIsCurrent(request, test.trace, test.query, test.seq, test.epoch)
			if got != test.want {
				t.Fatalf("freshness = %t; want %t", got, test.want)
			}
		})
	}
}

func TestTrackCommandRejectsPreviousTrace(t *testing.T) {
	command := serviceCommand{TraceGeneration: 8, TrackID: 44, Enabled: false}
	if !trackCommandMatches(command, 8) {
		t.Fatal("track command for current trace was rejected")
	}
	if trackCommandMatches(command, 9) {
		t.Fatal("track command from previous trace was accepted")
	}
}

func TestTrackWindowFreshnessRejectsStaleQuery(t *testing.T) {
	request := serviceCommand{
		Kind:            "track_window",
		TraceGeneration: 4,
		QueryGeneration: 9,
		Sequence:        21,
		ControlEpoch:    6,
	}
	if !windowRequestIsCurrent(request, 4, 9, 21, 6) {
		t.Fatal("current track page was rejected")
	}
	if windowRequestIsCurrent(request, 4, 10, 21, 6) {
		t.Fatal("track page from an earlier query was accepted")
	}
}

func TestServiceStateUsesNestedResourceHandles(t *testing.T) {
	encoded, err := json.Marshal(emptyServiceState())
	if err != nil {
		t.Fatal(err)
	}
	var state map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &state); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"tracks_resource", "window_resource"} {
		var handle map[string]uint64
		if err := json.Unmarshal(state[key], &handle); err != nil {
			t.Fatalf("decode %s: %v", key, err)
		}
		if _, ok := handle["id"]; !ok {
			t.Errorf("%s is missing id", key)
		}
		if _, ok := handle["generation"]; !ok {
			t.Errorf("%s is missing generation", key)
		}
	}
	for _, key := range []string{"matching_events", "visible_events", "tracks_first_row", "window_first_row", "total_events"} {
		if _, ok := state[key]; !ok {
			t.Errorf("state is missing %q", key)
		}
	}
	for _, obsolete := range []string{"tracks_resource_id", "tracks_resource_generation", "window_resource_id", "window_resource_generation"} {
		if _, ok := state[obsolete]; ok {
			t.Errorf("state unexpectedly contains flattened field %q", obsolete)
		}
	}
}
