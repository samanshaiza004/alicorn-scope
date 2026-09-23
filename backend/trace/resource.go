package trace

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"unicode/utf8"
)

// Binary resource format constants. All integers and float bit patterns are
// little-endian. String offsets are relative to the UTF-8 string table.
const (
	EventResourceMagic   = "SCEV"
	TrackResourceMagic   = "SCTR"
	EventResourceVersion = uint16(1)
	TrackResourceVersion = uint16(1)
	ResourceHeaderSize   = uint16(64)
	EventResourceRowSize = uint32(56)
	TrackResourceRowSize = uint32(64)
	MaxResourceBytes     = 1 << 20
)

// Event row flags. Exactly one kind bit must be set. TextTruncated indicates
// that name and/or category was shortened to keep the resource under 1 MiB.
const (
	EventFlagComplete      uint32 = 1 << 0
	EventFlagInstant       uint32 = 1 << 1
	EventFlagTextTruncated uint32 = 1 << 2
)

// Track row flags describe optional pid/tid and metadata fields. TextTruncated
// marks a process or thread name shortened to fit the resource byte limit.
const (
	TrackFlagHasPID              uint32 = 1 << 0
	TrackFlagHasTID              uint32 = 1 << 1
	TrackFlagHasProcessName      uint32 = 1 << 2
	TrackFlagHasThreadName       uint32 = 1 << 3
	TrackFlagHasProcessSortIndex uint32 = 1 << 4
	TrackFlagHasThreadSortIndex  uint32 = 1 << 5
	TrackFlagTextTruncated       uint32 = 1 << 6
	TrackFlagEnabled             uint32 = 1 << 7
)

// ResourceHeader is the common decoded 64-byte resource header.
type ResourceHeader struct {
	Version         uint16
	HeaderSize      uint16
	TraceGeneration uint64
	QueryGeneration uint64
	FirstRow        uint64
	TotalCount      uint64
	RowCount        uint32
	RowSize         uint32
	RowsOffset      uint32
	StringsOffset   uint32
	StringsBytes    uint32
}

// EventResourceRow is one decoded 56-byte SCEV row with resolved strings.
type EventResourceRow struct {
	EventID     uint64
	TrackID     uint64
	TimestampUS float64
	DurationUS  float64
	Flags       uint32
	Name        string
	Category    string
}

// EventResource is the validated decoded form of a SCEV v1 payload.
type EventResource struct {
	Header ResourceHeader
	Rows   []EventResourceRow
}

// TrackResourceRow is one decoded 64-byte SCTR row.
type TrackResourceRow struct {
	Track   Track
	Flags   uint32
	Enabled bool
}

// TrackResource is the validated decoded form of a SCTR v1 payload.
type TrackResource struct {
	Header ResourceHeader
	Rows   []TrackResourceRow
}

// EncodeTrackCatalog produces a SCTR v1 page from the complete track catalog.
// enabledTrackIDs controls each row's enabled bit; nil means all tracks are
// enabled. Disabled tracks remain present so the UI can turn them back on.
func EncodeTrackCatalog(model *Model, enabledTrackIDs []uint64, firstRow, count, traceGeneration, queryGeneration uint64) ([]byte, error) {
	if model == nil {
		return nil, errors.New("track catalog requires a model")
	}
	var enabled map[uint64]struct{}
	if enabledTrackIDs != nil {
		enabled = make(map[uint64]struct{}, len(enabledTrackIDs))
		for _, id := range enabledTrackIDs {
			enabled[id] = struct{}{}
		}
	}
	page := model.TrackWindow(firstRow, count)
	return encodeTrackPage(traceGeneration, queryGeneration, page, enabled)
}

func encodeTrackPage(traceGeneration, queryGeneration uint64, page TrackPage, enabled map[uint64]struct{}) ([]byte, error) {
	if err := validatePage(page.FirstRow, page.TotalCount, len(page.Rows)); err != nil {
		return nil, err
	}
	rowsBytes := len(page.Rows) * int(TrackResourceRowSize)
	stringBudget := MaxResourceBytes - int(ResourceHeaderSize) - rowsBytes
	values := make([]string, 0, len(page.Rows)*2)
	for _, track := range page.Rows {
		values = append(values, track.ProcessName, track.ThreadName)
	}
	stringsData, refs, wasTruncated, err := makeStringTable(values, stringBudget)
	if err != nil {
		return nil, err
	}
	stringsOffset := int(ResourceHeaderSize) + rowsBytes
	totalBytes := stringsOffset + len(stringsData)
	if totalBytes > MaxResourceBytes {
		return nil, errors.New("track resource exceeds 1 MiB")
	}
	out := make([]byte, totalBytes)
	writeHeader(out, TrackResourceMagic, TrackResourceVersion, traceGeneration, queryGeneration, page.FirstRow, page.TotalCount, uint32(len(page.Rows)), TrackResourceRowSize, uint32(stringsOffset), uint32(len(stringsData)))
	for i, track := range page.Rows {
		row := out[int(ResourceHeaderSize)+i*int(TrackResourceRowSize) : int(ResourceHeaderSize)+(i+1)*int(TrackResourceRowSize)]
		binary.LittleEndian.PutUint64(row[0:8], track.ID)
		binary.LittleEndian.PutUint64(row[8:16], uint64(track.PID))
		binary.LittleEndian.PutUint64(row[16:24], uint64(track.TID))
		processSort := track.ProcessSortIndex
		if !track.HasProcessSortIndex {
			processSort = MissingSortIndex
		}
		threadSort := track.ThreadSortIndex
		if !track.HasThreadSortIndex {
			threadSort = MissingSortIndex
		}
		binary.LittleEndian.PutUint64(row[24:32], uint64(processSort))
		binary.LittleEndian.PutUint64(row[32:40], uint64(threadSort))
		writeStringRef(row[40:48], refs[track.ProcessName])
		writeStringRef(row[48:56], refs[track.ThreadName])
		flags := trackFlags(track)
		if enabled == nil {
			flags |= TrackFlagEnabled
		} else if _, ok := enabled[track.ID]; ok {
			flags |= TrackFlagEnabled
		}
		if wasTruncated[track.ProcessName] || wasTruncated[track.ThreadName] {
			flags |= TrackFlagTextTruncated
		}
		binary.LittleEndian.PutUint32(row[56:60], flags)
		// row[60:64] is reserved and remains zero.
	}
	copy(out[stringsOffset:], stringsData)
	return out, nil
}

// EncodeEventWindow produces a SCEV v1 resource from a bounded event page.
func EncodeEventWindow(query *EventQuery, page EventPage, traceGeneration, queryGeneration uint64) ([]byte, error) {
	if query == nil || page.query != query {
		return nil, errors.New("event page was not produced by the supplied query")
	}
	if page.TotalCount != uint64(len(query.indices)) || page.FirstRow > uint64(len(query.indices)) || uint64(len(page.Rows)) > uint64(len(query.indices))-page.FirstRow {
		return nil, errors.New("event page no longer matches its query")
	}
	for i, event := range page.Rows {
		want := query.model.events[query.indices[int(page.FirstRow)+i]].Event
		if event != want {
			return nil, errors.New("event page rows were modified after query extraction")
		}
	}
	return encodeEventPage(traceGeneration, queryGeneration, page)
}

func encodeEventPage(traceGeneration, queryGeneration uint64, page EventPage) ([]byte, error) {
	if err := validatePage(page.FirstRow, page.TotalCount, len(page.Rows)); err != nil {
		return nil, err
	}
	rowsBytes := len(page.Rows) * int(EventResourceRowSize)
	stringBudget := MaxResourceBytes - int(ResourceHeaderSize) - rowsBytes
	values := make([]string, 0, len(page.Rows)*2)
	for _, event := range page.Rows {
		values = append(values, event.Name, event.Category)
	}
	stringsData, refs, wasTruncated, err := makeStringTable(values, stringBudget)
	if err != nil {
		return nil, err
	}
	stringsOffset := int(ResourceHeaderSize) + rowsBytes
	totalBytes := stringsOffset + len(stringsData)
	if totalBytes > MaxResourceBytes {
		return nil, errors.New("event resource exceeds 1 MiB")
	}
	out := make([]byte, totalBytes)
	writeHeader(out, EventResourceMagic, EventResourceVersion, traceGeneration, queryGeneration, page.FirstRow, page.TotalCount, uint32(len(page.Rows)), EventResourceRowSize, uint32(stringsOffset), uint32(len(stringsData)))
	for i, event := range page.Rows {
		row := out[int(ResourceHeaderSize)+i*int(EventResourceRowSize) : int(ResourceHeaderSize)+(i+1)*int(EventResourceRowSize)]
		binary.LittleEndian.PutUint64(row[0:8], event.ID)
		binary.LittleEndian.PutUint64(row[8:16], event.TrackID)
		binary.LittleEndian.PutUint64(row[16:24], math.Float64bits(event.TimestampUS))
		binary.LittleEndian.PutUint64(row[24:32], math.Float64bits(event.DurationUS))
		flags := uint32(0)
		switch event.Kind {
		case EventComplete:
			flags = EventFlagComplete
		case EventInstant:
			flags = EventFlagInstant
		default:
			return nil, fmt.Errorf("event %d has unsupported kind %d", event.ID, event.Kind)
		}
		if wasTruncated[event.Name] || wasTruncated[event.Category] {
			flags |= EventFlagTextTruncated
		}
		binary.LittleEndian.PutUint32(row[32:36], flags)
		writeStringRef(row[36:44], refs[event.Name])
		writeStringRef(row[44:52], refs[event.Category])
		// row[52:56] is reserved and remains zero.
	}
	copy(out[stringsOffset:], stringsData)
	return out, nil
}

func makeTrackPage(tracks []Track, first, count uint64) TrackPage {
	total := uint64(len(tracks))
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
	return TrackPage{FirstRow: first, TotalCount: total, Rows: tracks[int(first):int(end)]}
}

// DecodeEventResource validates a complete SCEV v1 resource and resolves its
// UTF-8 string table. It is useful to validate the contract at the boundary.
func DecodeEventResource(data []byte) (EventResource, error) {
	header, stringsData, err := readHeader(data, EventResourceMagic, EventResourceVersion, EventResourceRowSize)
	if err != nil {
		return EventResource{}, err
	}
	resource := EventResource{Header: header, Rows: make([]EventResourceRow, header.RowCount)}
	for i := uint32(0); i < header.RowCount; i++ {
		start := int(header.RowsOffset) + int(i)*int(header.RowSize)
		row := data[start : start+int(header.RowSize)]
		flags := binary.LittleEndian.Uint32(row[32:36])
		kind := flags & (EventFlagComplete | EventFlagInstant)
		if (kind != EventFlagComplete && kind != EventFlagInstant) || flags&^(EventFlagComplete|EventFlagInstant|EventFlagTextTruncated) != 0 {
			return EventResource{}, fmt.Errorf("event row %d has invalid flags %#x", i, flags)
		}
		if binary.LittleEndian.Uint32(row[52:56]) != 0 {
			return EventResource{}, fmt.Errorf("event row %d has nonzero reserved field", i)
		}
		ts := math.Float64frombits(binary.LittleEndian.Uint64(row[16:24]))
		dur := math.Float64frombits(binary.LittleEndian.Uint64(row[24:32]))
		if !finite(ts) || !finite(dur) {
			return EventResource{}, fmt.Errorf("event row %d has non-finite time", i)
		}
		name, err := readStringRef(row[36:44], stringsData)
		if err != nil {
			return EventResource{}, fmt.Errorf("event row %d name: %w", i, err)
		}
		category, err := readStringRef(row[44:52], stringsData)
		if err != nil {
			return EventResource{}, fmt.Errorf("event row %d category: %w", i, err)
		}
		resource.Rows[i] = EventResourceRow{
			EventID:     binary.LittleEndian.Uint64(row[0:8]),
			TrackID:     binary.LittleEndian.Uint64(row[8:16]),
			TimestampUS: ts,
			DurationUS:  dur,
			Flags:       flags,
			Name:        name,
			Category:    category,
		}
	}
	return resource, nil
}

// DecodeTrackResource validates a complete SCTR v1 resource and resolves its
// UTF-8 string table.
func DecodeTrackResource(data []byte) (TrackResource, error) {
	header, stringsData, err := readHeader(data, TrackResourceMagic, TrackResourceVersion, TrackResourceRowSize)
	if err != nil {
		return TrackResource{}, err
	}
	resource := TrackResource{Header: header, Rows: make([]TrackResourceRow, header.RowCount)}
	const knownFlags = TrackFlagHasPID | TrackFlagHasTID | TrackFlagHasProcessName | TrackFlagHasThreadName | TrackFlagHasProcessSortIndex | TrackFlagHasThreadSortIndex | TrackFlagTextTruncated | TrackFlagEnabled
	for i := uint32(0); i < header.RowCount; i++ {
		start := int(header.RowsOffset) + int(i)*int(header.RowSize)
		row := data[start : start+int(header.RowSize)]
		flags := binary.LittleEndian.Uint32(row[56:60])
		if flags&^knownFlags != 0 {
			return TrackResource{}, fmt.Errorf("track row %d has unknown flags %#x", i, flags)
		}
		if binary.LittleEndian.Uint32(row[60:64]) != 0 {
			return TrackResource{}, fmt.Errorf("track row %d has nonzero reserved field", i)
		}
		processName, err := readStringRef(row[40:48], stringsData)
		if err != nil {
			return TrackResource{}, fmt.Errorf("track row %d process name: %w", i, err)
		}
		threadName, err := readStringRef(row[48:56], stringsData)
		if err != nil {
			return TrackResource{}, fmt.Errorf("track row %d thread name: %w", i, err)
		}
		processSort := int64(binary.LittleEndian.Uint64(row[24:32]))
		threadSort := int64(binary.LittleEndian.Uint64(row[32:40]))
		track := Track{
			ID:                  binary.LittleEndian.Uint64(row[0:8]),
			PID:                 int64(binary.LittleEndian.Uint64(row[8:16])),
			TID:                 int64(binary.LittleEndian.Uint64(row[16:24])),
			HasPID:              flags&TrackFlagHasPID != 0,
			HasTID:              flags&TrackFlagHasTID != 0,
			ProcessName:         processName,
			HasProcessName:      flags&TrackFlagHasProcessName != 0,
			ThreadName:          threadName,
			HasThreadName:       flags&TrackFlagHasThreadName != 0,
			ProcessSortIndex:    processSort,
			HasProcessSortIndex: flags&TrackFlagHasProcessSortIndex != 0,
			ThreadSortIndex:     threadSort,
			HasThreadSortIndex:  flags&TrackFlagHasThreadSortIndex != 0,
		}
		if !track.HasProcessSortIndex && processSort != MissingSortIndex {
			return TrackResource{}, fmt.Errorf("track row %d absent process sort index is not the sentinel", i)
		}
		if !track.HasThreadSortIndex && threadSort != MissingSortIndex {
			return TrackResource{}, fmt.Errorf("track row %d absent thread sort index is not the sentinel", i)
		}
		if track.HasProcessName != (processName != "") || track.HasThreadName != (threadName != "") {
			// Empty names are valid metadata, so only reject missing string bytes
			// when a nonempty name was explicitly encoded. Presence is carried by
			// flags and can therefore legitimately accompany an empty string.
			if processName != "" || threadName != "" {
				return TrackResource{}, fmt.Errorf("track row %d name presence flags disagree", i)
			}
		}
		resource.Rows[i] = TrackResourceRow{Track: track, Flags: flags, Enabled: flags&TrackFlagEnabled != 0}
	}
	return resource, nil
}

func validatePage(first, total uint64, rows int) error {
	if rows > MaxWindowRows {
		return fmt.Errorf("resource has %d rows; maximum is %d", rows, MaxWindowRows)
	}
	if first > total || uint64(rows) > total-first {
		return errors.New("resource page is outside total row count")
	}
	return nil
}

func writeHeader(out []byte, magic string, version uint16, traceGeneration, queryGeneration, firstRow, totalCount uint64, rowCount, rowSize, stringsOffset, stringsBytes uint32) {
	copy(out[0:4], magic)
	binary.LittleEndian.PutUint16(out[4:6], version)
	binary.LittleEndian.PutUint16(out[6:8], ResourceHeaderSize)
	binary.LittleEndian.PutUint64(out[8:16], traceGeneration)
	binary.LittleEndian.PutUint64(out[16:24], queryGeneration)
	binary.LittleEndian.PutUint64(out[24:32], firstRow)
	binary.LittleEndian.PutUint64(out[32:40], totalCount)
	binary.LittleEndian.PutUint32(out[40:44], rowCount)
	binary.LittleEndian.PutUint32(out[44:48], rowSize)
	binary.LittleEndian.PutUint32(out[48:52], uint32(ResourceHeaderSize))
	binary.LittleEndian.PutUint32(out[52:56], stringsOffset)
	binary.LittleEndian.PutUint32(out[56:60], stringsBytes)
	// Header reserved bytes [60:64] remain zero.
}

func readHeader(data []byte, magic string, version uint16, rowSize uint32) (ResourceHeader, []byte, error) {
	if len(data) < int(ResourceHeaderSize) {
		return ResourceHeader{}, nil, errors.New("resource is shorter than its header")
	}
	if string(data[0:4]) != magic {
		return ResourceHeader{}, nil, fmt.Errorf("resource magic is %q, want %q", data[0:4], magic)
	}
	if binary.LittleEndian.Uint16(data[4:6]) != version {
		return ResourceHeader{}, nil, errors.New("unsupported resource version")
	}
	if binary.LittleEndian.Uint16(data[6:8]) != ResourceHeaderSize {
		return ResourceHeader{}, nil, errors.New("invalid resource header size")
	}
	if binary.LittleEndian.Uint32(data[44:48]) != rowSize || binary.LittleEndian.Uint32(data[48:52]) != uint32(ResourceHeaderSize) {
		return ResourceHeader{}, nil, errors.New("invalid resource row layout")
	}
	if binary.LittleEndian.Uint32(data[60:64]) != 0 {
		return ResourceHeader{}, nil, errors.New("nonzero resource header reserved field")
	}
	header := ResourceHeader{
		Version:         version,
		HeaderSize:      ResourceHeaderSize,
		TraceGeneration: binary.LittleEndian.Uint64(data[8:16]),
		QueryGeneration: binary.LittleEndian.Uint64(data[16:24]),
		FirstRow:        binary.LittleEndian.Uint64(data[24:32]),
		TotalCount:      binary.LittleEndian.Uint64(data[32:40]),
		RowCount:        binary.LittleEndian.Uint32(data[40:44]),
		RowSize:         rowSize,
		RowsOffset:      binary.LittleEndian.Uint32(data[48:52]),
		StringsOffset:   binary.LittleEndian.Uint32(data[52:56]),
		StringsBytes:    binary.LittleEndian.Uint32(data[56:60]),
	}
	if header.RowCount > MaxWindowRows {
		return ResourceHeader{}, nil, errors.New("resource row count exceeds limit")
	}
	if header.FirstRow > header.TotalCount || uint64(header.RowCount) > header.TotalCount-header.FirstRow {
		return ResourceHeader{}, nil, errors.New("resource page exceeds total row count")
	}
	expectedStringsOffset := uint64(ResourceHeaderSize) + uint64(header.RowCount)*uint64(rowSize)
	if uint64(header.RowsOffset) != uint64(ResourceHeaderSize) || uint64(header.StringsOffset) != expectedStringsOffset {
		return ResourceHeader{}, nil, errors.New("resource offsets are inconsistent")
	}
	end := uint64(header.StringsOffset) + uint64(header.StringsBytes)
	if end != uint64(len(data)) || end > MaxResourceBytes {
		return ResourceHeader{}, nil, errors.New("resource length does not match header")
	}
	stringsData := data[header.StringsOffset:end]
	if !utf8.Valid(stringsData) {
		return ResourceHeader{}, nil, errors.New("resource string table is not valid UTF-8")
	}
	return header, stringsData, nil
}

type stringReference struct {
	offset uint32
	length uint32
}

func makeStringTable(values []string, budget int) ([]byte, map[string]stringReference, map[string]bool, error) {
	unique := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		if !utf8.ValidString(value) {
			return nil, nil, nil, errors.New("resource string is not valid UTF-8")
		}
		if value == "" {
			continue
		}
		if _, exists := seen[value]; !exists {
			seen[value] = struct{}{}
			unique = append(unique, value)
		}
	}
	caps, _ := fitStringLengths(unique, budget)
	refsByOriginal := make(map[string]stringReference, len(unique))
	wasTruncated := make(map[string]bool, len(unique))
	var table []byte
	refsByValue := make(map[string]stringReference, len(unique))
	for i, original := range unique {
		value := utf8Prefix(original, caps[i])
		wasTruncated[original] = len(value) != len(original)
		if value == "" {
			refsByOriginal[original] = stringReference{}
			continue
		}
		ref, exists := refsByValue[value]
		if !exists {
			if uint64(len(table))+uint64(len(value)) > uint64(budget) {
				return nil, nil, nil, errors.New("string table exceeds resource budget")
			}
			ref = stringReference{offset: uint32(len(table)), length: uint32(len(value))}
			refsByValue[value] = ref
			table = append(table, value...)
		}
		refsByOriginal[original] = ref
	}
	return table, refsByOriginal, wasTruncated, nil
}

func fitStringLengths(values []string, budget int) ([]int, bool) {
	caps := make([]int, len(values))
	total := 0
	maxLength := 0
	for _, value := range values {
		if len(value) > math.MaxInt-total {
			return caps, true
		}
		total += len(value)
		if len(value) > maxLength {
			maxLength = len(value)
		}
	}
	if total <= budget {
		for i, value := range values {
			caps[i] = len(value)
		}
		return caps, false
	}
	low, high := 0, maxLength
	for low < high {
		mid := low + (high-low+1)/2
		used := 0
		for _, value := range values {
			used += min(len(value), mid)
		}
		if used <= budget {
			low = mid
		} else {
			high = mid - 1
		}
	}
	used := 0
	for i, value := range values {
		caps[i] = min(len(value), low)
		used += caps[i]
	}
	remaining := budget - used
	for i, value := range values {
		if remaining == 0 {
			break
		}
		if len(value) > caps[i] {
			caps[i]++
			remaining--
		}
	}
	return caps, true
}

func utf8Prefix(value string, maxBytes int) string {
	if maxBytes >= len(value) {
		return value
	}
	if maxBytes <= 0 {
		return ""
	}
	end := maxBytes
	for end > 0 && !utf8.RuneStart(value[end]) {
		end--
	}
	return value[:end]
}

func writeStringRef(row []byte, ref stringReference) {
	binary.LittleEndian.PutUint32(row[0:4], ref.offset)
	binary.LittleEndian.PutUint32(row[4:8], ref.length)
}

func readStringRef(ref, table []byte) (string, error) {
	if len(ref) != 8 {
		return "", errors.New("invalid string reference width")
	}
	offset := uint64(binary.LittleEndian.Uint32(ref[0:4]))
	length := uint64(binary.LittleEndian.Uint32(ref[4:8]))
	if offset+length > uint64(len(table)) {
		return "", errors.New("string reference exceeds table")
	}
	value := table[offset : offset+length]
	if !utf8.Valid(value) {
		return "", errors.New("string table entry is not valid UTF-8")
	}
	return string(value), nil
}

func trackFlags(track Track) uint32 {
	var flags uint32
	if track.HasPID {
		flags |= TrackFlagHasPID
	}
	if track.HasTID {
		flags |= TrackFlagHasTID
	}
	if track.HasProcessName {
		flags |= TrackFlagHasProcessName
	}
	if track.HasThreadName {
		flags |= TrackFlagHasThreadName
	}
	if track.HasProcessSortIndex {
		flags |= TrackFlagHasProcessSortIndex
	}
	if track.HasThreadSortIndex {
		flags |= TrackFlagHasThreadSortIndex
	}
	return flags
}
