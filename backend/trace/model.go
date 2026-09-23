// Package trace parses and indexes the supported subset of Chrome Trace Event
// JSON. It is deliberately independent of Alicorn and Caliber.
package trace

import (
	"crypto/sha256"
	"encoding/binary"
	"math"
	"sort"
	"strings"
)

// MissingSortIndex is written to track resources when a sort index is absent.
const MissingSortIndex int64 = math.MinInt64

// MaxWindowRows is the maximum number of rows returned by a model window or
// encoded into a SCTR/SCEV resource.
const MaxWindowRows = 512

// EventKind identifies the supported Chrome event record kinds.
type EventKind uint8

const (
	EventComplete EventKind = iota + 1
	EventInstant
)

// Event is the compact indexed representation used in event windows. ID is
// the source-record ordinal; it is not a row number or timestamp. The trace
// generation is carried separately by Model and resource headers.
type Event struct {
	ID          uint64
	TrackID     uint64
	TimestampUS float64
	DurationUS  float64
	Kind        EventKind
	Name        string
	Category    string
}

// EventDetails is returned only for an explicit stable-ID lookup. Arguments
// are retained as compact JSON only when they fit the inspector limits.
type EventDetails struct {
	Event             Event
	ArgsJSON          []byte
	ArgsTruncated     bool
	ArgsOriginalBytes uint64
}

// Track describes one pid/tid pair. Has* fields distinguish absent metadata
// from values such as pid=0 or an empty process name.
type Track struct {
	ID                  uint64
	PID                 int64
	TID                 int64
	HasPID              bool
	HasTID              bool
	ProcessName         string
	HasProcessName      bool
	ThreadName          string
	HasThreadName       bool
	ProcessSortIndex    int64
	HasProcessSortIndex bool
	ThreadSortIndex     int64
	HasThreadSortIndex  bool
}

type eventRecord struct {
	Event
	argsJSON          []byte
	argsTruncated     bool
	argsOriginalBytes uint64
}

type trackKey struct {
	pid    int64
	tid    int64
	hasPID bool
	hasTID bool
}

type processMetadata struct {
	name       string
	hasName    bool
	sortIndex  int64
	hasSortIdx bool
}

type threadMetadata struct {
	name       string
	hasName    bool
	sortIndex  int64
	hasSortIdx bool
}

// Model is an immutable, timestamp-sorted trace snapshot. A new Model should
// be built privately and published only after Parse succeeds.
type Model struct {
	traceGeneration       uint64
	events                []eventRecord
	tracks                []Track
	trackByKey            map[trackKey]int
	eventIndexByOrdinal   map[uint64]int
	unsupportedPhaseCount uint64
	inputRecordCount      uint64
}

// TraceGeneration returns the caller-supplied generation associated with the
// parsed snapshot. It is not folded into event ordinals or track IDs.
func (m *Model) TraceGeneration() uint64 { return m.traceGeneration }

// EventCount returns the number of accepted X and I records.
func (m *Model) EventCount() uint64 { return uint64(len(m.events)) }

// TrackCount returns the number of distinct pid/tid tracks represented by
// accepted events.
func (m *Model) TrackCount() uint64 { return uint64(len(m.tracks)) }

// UnsupportedPhaseCount returns the number of records whose phase was not
// X, I, or M. Metadata records with unknown metadata names are still phase M.
func (m *Model) UnsupportedPhaseCount() uint64 { return m.unsupportedPhaseCount }

// InputRecordCount includes accepted events, metadata records, and
// unsupported-phase records.
func (m *Model) InputRecordCount() uint64 { return m.inputRecordCount }

// TrackPage is a bounded slice of the stable track catalog.
type TrackPage struct {
	FirstRow   uint64
	TotalCount uint64
	Rows       []Track
}

// TrackWindow returns at most MaxWindowRows tracks in deterministic display
// order. Out-of-range offsets are clamped to the end of the catalog.
func (m *Model) TrackWindow(first, count uint64) TrackPage {
	total := uint64(len(m.tracks))
	if first > total {
		first = total
	}
	if count > MaxWindowRows {
		count = MaxWindowRows
	}
	end := first + count
	if end < first || end > total {
		end = total
	}
	rows := append([]Track(nil), m.tracks[int(first):int(end)]...)
	return TrackPage{FirstRow: first, TotalCount: total, Rows: rows}
}

// EventPage is a bounded slice of a stable query result.
type EventPage struct {
	FirstRow   uint64
	TotalCount uint64
	Rows       []Event
	query      *EventQuery
}

// EventQuery is an immutable filtered view over a Model. A nil enabledTrackIDs
// means all tracks; a non-nil empty slice means no tracks. Constructing a
// query computes its ordered matching index once, so subsequent windows do
// not rescan the trace.
type EventQuery struct {
	model   *Model
	indices []int
}

// NewEventQuery builds a timestamp-ordered query over enabled tracks and an
// optional case-insensitive substring filter matching event name or category.
func (m *Model) NewEventQuery(enabledTrackIDs []uint64, textFilter string) *EventQuery {
	var enabled map[uint64]struct{}
	if enabledTrackIDs != nil {
		enabled = make(map[uint64]struct{}, len(enabledTrackIDs))
		for _, id := range enabledTrackIDs {
			enabled[id] = struct{}{}
		}
	}
	filter := strings.ToLower(textFilter)
	capacity := min(len(m.events), 4096)
	indices := make([]int, 0, capacity)
	for i := range m.events {
		e := &m.events[i].Event
		if enabled != nil {
			if _, ok := enabled[e.TrackID]; !ok {
				continue
			}
		}
		if filter != "" && !strings.Contains(strings.ToLower(e.Name), filter) && !strings.Contains(strings.ToLower(e.Category), filter) {
			continue
		}
		indices = append(indices, i)
	}
	return &EventQuery{model: m, indices: indices}
}

// Count returns the exact number of matches in this immutable query.
func (q *EventQuery) Count() uint64 { return uint64(len(q.indices)) }

// Window returns at most MaxWindowRows rows. Argument payloads are omitted
// from windows; use LookupEvent for the bounded inspector detail.
func (q *EventQuery) Window(first, count uint64) EventPage {
	total := uint64(len(q.indices))
	if first > total {
		first = total
	}
	if count > MaxWindowRows {
		count = MaxWindowRows
	}
	end := first + count
	if end < first || end > total {
		end = total
	}
	rows := make([]Event, int(end-first))
	for row, queryIndex := first, 0; row < end; row, queryIndex = row+1, queryIndex+1 {
		rows[queryIndex] = q.model.events[q.indices[int(row)]].Event
	}
	return EventPage{FirstRow: first, TotalCount: total, Rows: rows, query: q}
}

// LookupEvent resolves an event by its original source-record ordinal. It is
// independent of timestamp sorting, filtering, and row position.
func (m *Model) LookupEvent(ordinal uint64) (EventDetails, bool) {
	i, ok := m.eventIndexByOrdinal[ordinal]
	if !ok {
		return EventDetails{}, false
	}
	record := &m.events[i]
	details := EventDetails{
		Event:             record.Event,
		ArgsJSON:          append([]byte(nil), record.argsJSON...),
		ArgsTruncated:     record.argsTruncated,
		ArgsOriginalBytes: record.argsOriginalBytes,
	}
	return details, true
}

func stableTrackID(key trackKey, used map[uint64]trackKey) uint64 {
	var input [20]byte
	input[0], input[1] = 'T', 'R'
	if key.hasPID {
		input[2] = 1
	}
	if key.hasTID {
		input[3] = 1
	}
	binary.LittleEndian.PutUint64(input[4:12], uint64(key.pid))
	binary.LittleEndian.PutUint64(input[12:20], uint64(key.tid))
	hash := sha256.Sum256(input[:])
	id := binary.LittleEndian.Uint64(hash[:8])
	if id == 0 {
		id = 1
	}
	for {
		if prior, exists := used[id]; !exists || prior == key {
			return id
		}
		id++
		if id == 0 {
			id = 1
		}
	}
}

func sortTracks(tracks []Track) {
	knownFirst := func(aKnown, bKnown bool, a, b int64) int {
		if aKnown != bKnown {
			if aKnown {
				return -1
			}
			return 1
		}
		if !aKnown || a == b {
			return 0
		}
		if a < b {
			return -1
		}
		return 1
	}
	sort.Slice(tracks, func(i, j int) bool {
		a, b := tracks[i], tracks[j]
		if c := knownFirst(a.HasProcessSortIndex, b.HasProcessSortIndex, a.ProcessSortIndex, b.ProcessSortIndex); c != 0 {
			return c < 0
		}
		if a.HasPID != b.HasPID {
			return a.HasPID
		}
		if a.PID != b.PID {
			return a.PID < b.PID
		}
		if c := knownFirst(a.HasThreadSortIndex, b.HasThreadSortIndex, a.ThreadSortIndex, b.ThreadSortIndex); c != 0 {
			return c < 0
		}
		if a.HasTID != b.HasTID {
			return a.HasTID
		}
		if a.TID != b.TID {
			return a.TID < b.TID
		}
		return a.ID < b.ID
	})
}
