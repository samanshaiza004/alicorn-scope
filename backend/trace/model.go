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

// TimelineMode selects whether a bounded timeline resource contains semantic
// event identities or fixed temporal summaries.
type TimelineMode uint32

const (
	TimelineRaw TimelineMode = iota + 1
	TimelineAggregate
)

// MaxTimelineRows bounds both raw event payloads and aggregate bucket count.
const MaxTimelineRows = 512

// MaxTimelineRawEvents stays below the Alicorn geometry vertex budget even
// when every item is an instant rendered as a filled circle.
const MaxTimelineRawEvents = 128

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

// TimelineRow is either a raw event (TimelineRaw) or a temporal bucket
// (TimelineAggregate). Fields not used by the selected mode remain zero.
type TimelineRow struct {
	EventID       uint64
	TrackID       uint64
	TimestampUS   float64
	DurationUS    float64
	Kind          EventKind
	BucketStartUS float64
	BucketEndUS   float64
	EventCount    uint64
	DurationSumUS float64
}

// TimelineWindow is an immutable, bounded projection of a time range.
type TimelineWindow struct {
	TraceGeneration uint64
	QueryGeneration uint64
	TrackID         uint64
	Mode            TimelineMode
	StartUS         float64
	EndUS           float64
	TotalEventCount uint64
	Rows            []TimelineRow
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
	trackEventIndices     map[uint64]*trackEventIndex
	traceStartUS          float64
	traceEndUS            float64
	hasTraceBounds        bool
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
	enabled map[uint64]struct{}
	filter  string
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
	return &EventQuery{model: m, indices: indices, enabled: enabled, filter: filter}
}

// TraceBounds returns the earliest event timestamp and an exclusive upper
// bound that includes the latest event end. An instant contributes its
// timestamp; a complete event contributes ts+dur. The extra representable
// step lets a half-open timeline query include an instant at the maximum
// timestamp.
func (m *Model) TraceBounds() (startUS, endUS float64, ok bool) {
	if m == nil || !m.hasTraceBounds {
		return 0, 0, false
	}
	endUS = math.Nextafter(m.traceEndUS, math.Inf(1))
	if math.IsInf(endUS, 1) {
		endUS = m.traceEndUS
	}
	return m.traceStartUS, endUS, true
}

// TimelineWindow queries one enabled track over [startUS,endUS), or all
// enabled tracks when trackID is zero. Intervals
// crossing the left boundary are included. If more than MaxTimelineRawEvents
// match, the result switches to bounded temporal buckets. Resolution is a
// semantic bucket-count hint, clamped to [1, MaxTimelineRows].
func (q *EventQuery) TimelineWindow(trackID uint64, startUS, endUS float64, resolution uint32, traceGeneration, queryGeneration uint64) TimelineWindow {
	result := TimelineWindow{
		TraceGeneration: traceGeneration,
		QueryGeneration: queryGeneration,
		TrackID:         trackID,
		Mode:            TimelineRaw,
		StartUS:         startUS,
		EndUS:           endUS,
		Rows:            []TimelineRow{},
	}
	if q == nil || q.model == nil || !finite(startUS) || !finite(endUS) || endUS <= startUS {
		return result
	}

	if resolution == 0 {
		resolution = 1
	}
	if resolution > MaxTimelineRows {
		resolution = MaxTimelineRows
	}
	trackIDs := make([]uint64, 0, 1)
	if trackID != 0 {
		if q.enabled != nil {
			if _, enabled := q.enabled[trackID]; !enabled {
				return result
			}
		}
		trackIDs = append(trackIDs, trackID)
	} else {
		for _, track := range q.model.tracks {
			if q.enabled != nil {
				if _, enabled := q.enabled[track.ID]; !enabled {
					continue
				}
			}
			trackIDs = append(trackIDs, track.ID)
			if len(trackIDs) == MaxTimelineRows {
				break
			}
		}
	}
	if len(trackIDs) == 0 {
		return result
	}
	var rawRows []TimelineRow
	var aggregateRows []TimelineRow
	var bucketBases map[uint64]int
	var bucketsPerTrack uint32
	rawRows = make([]TimelineRow, 0, MaxTimelineRawEvents+1)
	result.TotalEventCount = 0
	for _, currentTrackID := range trackIDs {
		index := q.model.trackEventIndices[currentTrackID]
		if index == nil {
			continue
		}
		index.visitOverlapping(q.model, startUS, endUS, func(event Event) bool {
			if q.filter != "" && !strings.Contains(strings.ToLower(event.Name), q.filter) && !strings.Contains(strings.ToLower(event.Category), q.filter) {
				return true
			}
			result.TotalEventCount++
			raw := TimelineRow{EventID: event.ID, TrackID: event.TrackID, TimestampUS: event.TimestampUS, DurationUS: event.DurationUS, Kind: event.Kind}
			if aggregateRows == nil {
				rawRows = append(rawRows, raw)
				if len(rawRows) > MaxTimelineRawEvents {
					aggregateRows, bucketBases, bucketsPerTrack = makeTimelineBuckets(trackIDs, startUS, endUS, resolution)
					for _, prior := range rawRows {
						accumulateTimelineEvent(aggregateRows, bucketBases, bucketsPerTrack, prior, startUS, endUS)
					}
					rawRows = nil
				}
			} else {
				accumulateTimelineEvent(aggregateRows, bucketBases, bucketsPerTrack, raw, startUS, endUS)
			}
			return true
		})
	}
	if aggregateRows != nil {
		result.Mode = TimelineAggregate
		result.Rows = aggregateRows
	} else {
		result.Rows = rawRows
	}
	return result
}

type trackEventIndex struct {
	eventIndices []int
	leafBase     int
	maxEndTree   []float64
}

func (idx *trackEventIndex) visitOverlapping(model *Model, startUS, endUS float64, visit func(Event) bool) {
	if idx == nil || len(idx.eventIndices) == 0 {
		return
	}
	end := sort.Search(len(idx.eventIndices), func(i int) bool {
		return model.events[idx.eventIndices[i]].TimestampUS >= endUS
	})
	if end == 0 {
		return
	}
	_ = idx.visitTreeRange(model, 1, 0, idx.leafBase, end, startUS, endUS, visit)
}

func (idx *trackEventIndex) visitTreeRange(model *Model, node, left, right, end int, startUS, endUS float64, visit func(Event) bool) bool {
	if left >= end || idx.maxEndTree[node] < startUS {
		return true
	}
	if right-left == 1 {
		if left < len(idx.eventIndices) {
			eventIndex := idx.eventIndices[left]
			event := model.events[eventIndex].Event
			if eventIntersectsRange(event, startUS, endUS) {
				return visit(event)
			}
		}
		return true
	}
	middle := left + (right-left)/2
	if !idx.visitTreeRange(model, node*2, left, middle, end, startUS, endUS, visit) {
		return false
	}
	return idx.visitTreeRange(model, node*2+1, middle, right, end, startUS, endUS, visit)
}

func makeTimelineBuckets(trackIDs []uint64, startUS, endUS float64, resolution uint32) ([]TimelineRow, map[uint64]int, uint32) {
	if len(trackIDs) == 0 {
		return nil, nil, 0
	}
	bucketsPerTrack := uint32(MaxTimelineRows / len(trackIDs))
	if bucketsPerTrack == 0 {
		bucketsPerTrack = 1
	}
	if bucketsPerTrack > resolution {
		bucketsPerTrack = resolution
	}
	buckets := make([]TimelineRow, 0, len(trackIDs)*int(bucketsPerTrack))
	bases := make(map[uint64]int, len(trackIDs))
	span := endUS - startUS
	for _, trackID := range trackIDs {
		bases[trackID] = len(buckets)
		for i := uint32(0); i < bucketsPerTrack; i++ {
			buckets = append(buckets, TimelineRow{
				TrackID:       trackID,
				BucketStartUS: startUS + span*float64(i)/float64(bucketsPerTrack),
				BucketEndUS:   startUS + span*float64(i+1)/float64(bucketsPerTrack),
			})
		}
	}
	return buckets, bases, bucketsPerTrack
}

func accumulateTimelineEvent(buckets []TimelineRow, bases map[uint64]int, bucketsPerTrack uint32, event TimelineRow, startUS, endUS float64) {
	base, exists := bases[event.TrackID]
	if !exists || bucketsPerTrack == 0 {
		return
	}
	span := endUS - startUS
	position := event.TimestampUS
	if position < startUS {
		position = startUS
	}
	if position >= endUS {
		position = math.Nextafter(endUS, startUS)
	}
	bucket := int((position - startUS) / span * float64(bucketsPerTrack))
	if bucket < 0 {
		bucket = 0
	} else if bucket >= int(bucketsPerTrack) {
		bucket = int(bucketsPerTrack) - 1
	}
	row := &buckets[base+bucket]
	row.EventCount++
	if event.Kind == EventComplete && event.DurationUS > 0 {
		overlapStart := math.Max(event.TimestampUS, startUS)
		overlapEnd := math.Min(event.TimestampUS+event.DurationUS, endUS)
		if overlapEnd > overlapStart {
			row.DurationSumUS += overlapEnd - overlapStart
		}
	}
}

func eventIntersectsRange(event Event, startUS, endUS float64) bool {
	if event.TimestampUS >= endUS {
		return false
	}
	if event.Kind == EventInstant || event.DurationUS <= 0 {
		return event.TimestampUS >= startUS
	}
	return eventEndUS(event) > startUS
}

func eventEndUS(event Event) float64 {
	if event.Kind != EventComplete || event.DurationUS <= 0 {
		return event.TimestampUS
	}
	end := event.TimestampUS + event.DurationUS
	if math.IsInf(end, 1) {
		return math.MaxFloat64
	}
	return end
}

func buildTrackEventIndex(events []eventRecord) map[uint64]*trackEventIndex {
	indices := make(map[uint64]*trackEventIndex)
	for i := range events {
		trackID := events[i].TrackID
		index := indices[trackID]
		if index == nil {
			index = &trackEventIndex{}
			indices[trackID] = index
		}
		index.eventIndices = append(index.eventIndices, i)
	}
	for _, index := range indices {
		index.leafBase = 1
		for index.leafBase < len(index.eventIndices) {
			index.leafBase *= 2
		}
		index.maxEndTree = make([]float64, index.leafBase*2)
		for i := range index.maxEndTree {
			index.maxEndTree[i] = -math.MaxFloat64
		}
		for i, eventIndex := range index.eventIndices {
			index.maxEndTree[index.leafBase+i] = eventEndUS(events[eventIndex].Event)
		}
		for i := index.leafBase - 1; i > 0; i-- {
			index.maxEndTree[i] = math.Max(index.maxEndTree[i*2], index.maxEndTree[i*2+1])
		}
	}
	return indices
}

// Count returns the exact number of matches in this immutable query.
func (q *EventQuery) Count() uint64 { return uint64(len(q.indices)) }

// RowForEventID finds the current query position for a stable source ordinal.
// It is intended for the comparatively rare selection reconciliation path,
// not for frame-time row lookup.
func (q *EventQuery) RowForEventID(ordinal uint64) (uint64, bool) {
	if q == nil || q.model == nil {
		return 0, false
	}
	eventIndex, exists := q.model.eventIndexByOrdinal[ordinal]
	if !exists {
		return 0, false
	}
	row := sort.Search(len(q.indices), func(i int) bool { return q.indices[i] >= eventIndex })
	if row == len(q.indices) || q.indices[row] != eventIndex {
		return 0, false
	}
	return uint64(row), true
}

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
