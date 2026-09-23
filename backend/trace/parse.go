package trace

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Inspector limits bound retained event arguments. Oversized or structurally
// complex values remain represented by ArgsTruncated and ArgsOriginalBytes.
const (
	MaxInspectorArgsBytes = 64 << 10
	MaxInspectorDepth     = 32
	MaxInspectorFields    = 256
)

// Load opens and streams a Chrome Trace Event JSON file into a private model.
// The caller supplies the trace generation used by subsequent resources.
func Load(path string, generation uint64) (*Model, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open trace %q: %w", path, err)
	}
	defer f.Close()
	model, err := Parse(f, generation)
	if err != nil {
		return nil, fmt.Errorf("parse trace %q: %w", path, err)
	}
	return model, nil
}

// Parse incrementally decodes either a top-level event array or a Chrome
// envelope containing a traceEvents array. It never unmarshals the full trace
// into a generic object tree.
func Parse(r io.Reader, generation uint64) (*Model, error) {
	decoder := json.NewDecoder(r)
	decoder.UseNumber()
	root, err := decoder.Token()
	if err != nil {
		return nil, fmt.Errorf("read trace root: %w", err)
	}
	model := &Model{
		traceGeneration:     generation,
		trackByKey:          make(map[trackKey]int),
		eventIndexByOrdinal: make(map[uint64]int),
	}
	b := &parseBuilder{
		model:        model,
		usedTrackIDs: make(map[uint64]trackKey),
		processes:    make(map[int64]processMetadata),
		threads:      make(map[trackKey]threadMetadata),
		strings:      make(map[string]string),
	}

	switch delim, ok := root.(json.Delim); {
	case ok && delim == '[':
		err = b.readEventArray(decoder)
	case ok && delim == '{':
		err = b.readEnvelope(decoder)
	default:
		err = fmt.Errorf("trace root must be an event array or object envelope")
	}
	if err != nil {
		return nil, err
	}
	if err := requireEOF(decoder); err != nil {
		return nil, err
	}
	b.finish()
	return model, nil
}

type parseBuilder struct {
	model        *Model
	usedTrackIDs map[uint64]trackKey
	processes    map[int64]processMetadata
	threads      map[trackKey]threadMetadata
	strings      map[string]string
}

type wireEvent struct {
	Name  string          `json:"name"`
	Cat   string          `json:"cat"`
	Phase string          `json:"ph"`
	TS    *float64        `json:"ts"`
	Dur   *float64        `json:"dur"`
	PID   json.RawMessage `json:"pid"`
	TID   json.RawMessage `json:"tid"`
	Args  json.RawMessage `json:"args"`
}

func (b *parseBuilder) readEnvelope(decoder *json.Decoder) error {
	foundEvents := false
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return fmt.Errorf("read envelope key: %w", err)
		}
		key, ok := keyToken.(string)
		if !ok {
			return errors.New("trace envelope contains a non-string key")
		}
		if key == "traceEvents" {
			if foundEvents {
				return errors.New("trace envelope has multiple traceEvents fields")
			}
			foundEvents = true
			value, err := decoder.Token()
			if err != nil {
				return fmt.Errorf("read traceEvents value: %w", err)
			}
			delim, ok := value.(json.Delim)
			if !ok || delim != '[' {
				return errors.New("traceEvents must be an array")
			}
			if err := b.readEventArray(decoder); err != nil {
				return err
			}
			continue
		}
		value, err := decoder.Token()
		if err != nil {
			return fmt.Errorf("read envelope field %q: %w", key, err)
		}
		if err := skipValue(decoder, value); err != nil {
			return fmt.Errorf("skip envelope field %q: %w", key, err)
		}
	}
	if _, err := decoder.Token(); err != nil { // closing object
		return fmt.Errorf("close trace envelope: %w", err)
	}
	if !foundEvents {
		return errors.New("trace envelope is missing traceEvents")
	}
	return nil
}

func (b *parseBuilder) readEventArray(decoder *json.Decoder) error {
	for decoder.More() {
		var wire wireEvent
		if err := decoder.Decode(&wire); err != nil {
			return fmt.Errorf("decode event record %d: %w", b.model.inputRecordCount, err)
		}
		if b.model.inputRecordCount == math.MaxUint64 {
			return errors.New("trace contains more records than can be identified")
		}
		ordinal := b.model.inputRecordCount
		b.model.inputRecordCount++
		if err := b.consume(ordinal, wire); err != nil {
			return fmt.Errorf("event record %d: %w", ordinal, err)
		}
	}
	if _, err := decoder.Token(); err != nil { // closing array
		return fmt.Errorf("close event array: %w", err)
	}
	return nil
}

func (b *parseBuilder) consume(ordinal uint64, wire wireEvent) error {
	switch wire.Phase {
	case "M":
		if wire.Name != "process_name" && wire.Name != "thread_name" && wire.Name != "process_sort_index" && wire.Name != "thread_sort_index" {
			return nil
		}
		key, err := makeTrackKey(wire.PID, wire.TID)
		if err != nil {
			return err
		}
		return b.consumeMetadata(key, wire)
	case "X", "I":
		key, err := makeTrackKey(wire.PID, wire.TID)
		if err != nil {
			return err
		}
		if wire.TS == nil || !finite(*wire.TS) {
			return errors.New("supported event is missing a finite ts")
		}
		kind := EventComplete
		duration := float64(0)
		if wire.Phase == "X" {
			if wire.Dur == nil || !finite(*wire.Dur) {
				return errors.New("complete event is missing a finite dur")
			}
			duration = *wire.Dur
		} else {
			kind = EventInstant
			if wire.Dur != nil {
				if !finite(*wire.Dur) {
					return errors.New("instant event has a non-finite dur")
				}
				duration = *wire.Dur
			}
		}
		trackID := b.ensureTrack(key)
		args, truncated, originalBytes, err := boundedArgs(wire.Args)
		if err != nil {
			return fmt.Errorf("decode args: %w", err)
		}
		b.model.events = append(b.model.events, eventRecord{
			Event: Event{
				ID:          ordinal,
				TrackID:     trackID,
				TimestampUS: *wire.TS,
				DurationUS:  duration,
				Kind:        kind,
				Name:        b.intern(wire.Name),
				Category:    b.intern(wire.Cat),
			},
			argsJSON:          args,
			argsTruncated:     truncated,
			argsOriginalBytes: originalBytes,
		})
	default:
		b.model.unsupportedPhaseCount++
	}
	return nil
}

func (b *parseBuilder) consumeMetadata(key trackKey, wire wireEvent) error {
	var args struct {
		Name      *string         `json:"name"`
		SortIndex json.RawMessage `json:"sort_index"`
	}
	if len(wire.Args) != 0 && !bytes.Equal(bytes.TrimSpace(wire.Args), []byte("null")) {
		if err := json.Unmarshal(wire.Args, &args); err != nil {
			return fmt.Errorf("metadata args must be an object: %w", err)
		}
	}
	switch wire.Name {
	case "process_name":
		if !key.hasPID {
			return errors.New("process_name metadata is missing pid")
		}
		meta := b.processes[key.pid]
		if args.Name != nil {
			meta.name, meta.hasName = *args.Name, true
		}
		if len(args.SortIndex) != 0 && !bytes.Equal(bytes.TrimSpace(args.SortIndex), []byte("null")) {
			value, err := parseInt64JSON(args.SortIndex)
			if err != nil {
				return fmt.Errorf("invalid process sort_index: %w", err)
			}
			meta.sortIndex, meta.hasSortIdx = value, true
		}
		b.processes[key.pid] = meta
	case "thread_name", "process_sort_index", "thread_sort_index":
		if wire.Name == "thread_name" && args.Name != nil {
			meta := b.threads[key]
			meta.name, meta.hasName = *args.Name, true
			b.threads[key] = meta
		}
		if wire.Name == "thread_name" && len(args.SortIndex) != 0 && !bytes.Equal(bytes.TrimSpace(args.SortIndex), []byte("null")) {
			// Some producers attach a thread sort index to thread_name metadata.
			value, err := parseInt64JSON(args.SortIndex)
			if err != nil {
				return fmt.Errorf("invalid thread sort_index: %w", err)
			}
			meta := b.threads[key]
			meta.sortIndex, meta.hasSortIdx = value, true
			b.threads[key] = meta
		}
		if wire.Name == "process_sort_index" {
			if !key.hasPID {
				return errors.New("process_sort_index metadata is missing pid")
			}
			value, err := parseInt64JSON(args.SortIndex)
			if err != nil {
				return fmt.Errorf("invalid process sort_index: %w", err)
			}
			meta := b.processes[key.pid]
			meta.sortIndex, meta.hasSortIdx = value, true
			b.processes[key.pid] = meta
		}
		if wire.Name == "thread_sort_index" {
			value, err := parseInt64JSON(args.SortIndex)
			if err != nil {
				return fmt.Errorf("invalid thread sort_index: %w", err)
			}
			meta := b.threads[key]
			meta.sortIndex, meta.hasSortIdx = value, true
			b.threads[key] = meta
		}
	}
	return nil
}

func (b *parseBuilder) ensureTrack(key trackKey) uint64 {
	if index, ok := b.model.trackByKey[key]; ok {
		return b.model.tracks[index].ID
	}
	id := stableTrackID(key, b.usedTrackIDs)
	b.usedTrackIDs[id] = key
	track := Track{ID: id, PID: key.pid, TID: key.tid, HasPID: key.hasPID, HasTID: key.hasTID}
	if !track.HasProcessSortIndex {
		track.ProcessSortIndex = MissingSortIndex
	}
	if !track.HasThreadSortIndex {
		track.ThreadSortIndex = MissingSortIndex
	}
	b.model.trackByKey[key] = len(b.model.tracks)
	b.model.tracks = append(b.model.tracks, track)
	return id
}

func (b *parseBuilder) intern(value string) string {
	if value == "" {
		return ""
	}
	if existing, ok := b.strings[value]; ok {
		return existing
	}
	b.strings[value] = value
	return value
}

func (b *parseBuilder) finish() {
	for i := range b.model.tracks {
		track := &b.model.tracks[i]
		key := trackKey{pid: track.PID, tid: track.TID, hasPID: track.HasPID, hasTID: track.HasTID}
		if track.HasPID {
			if meta, ok := b.processes[track.PID]; ok {
				track.ProcessName, track.HasProcessName = meta.name, meta.hasName
				if meta.hasSortIdx {
					track.ProcessSortIndex, track.HasProcessSortIndex = meta.sortIndex, true
				}
			}
		}
		if meta, ok := b.threads[key]; ok {
			track.ThreadName, track.HasThreadName = meta.name, meta.hasName
			if meta.hasSortIdx {
				track.ThreadSortIndex, track.HasThreadSortIndex = meta.sortIndex, true
			}
		}
		if !track.HasProcessSortIndex {
			track.ProcessSortIndex = MissingSortIndex
		}
		if !track.HasThreadSortIndex {
			track.ThreadSortIndex = MissingSortIndex
		}
	}
	sortTracks(b.model.tracks)
	// Keep metadata independent of record arrival order.
	sort.Slice(b.model.events, func(i, j int) bool {
		a, c := b.model.events[i].Event, b.model.events[j].Event
		if a.TimestampUS != c.TimestampUS {
			return a.TimestampUS < c.TimestampUS
		}
		return a.ID < c.ID
	})
	clear(b.model.eventIndexByOrdinal)
	for i := range b.model.events {
		b.model.eventIndexByOrdinal[b.model.events[i].ID] = i
	}
}

func makeTrackKey(pidRaw, tidRaw json.RawMessage) (trackKey, error) {
	key := trackKey{}
	if len(pidRaw) != 0 && !bytes.Equal(bytes.TrimSpace(pidRaw), []byte("null")) {
		value, err := parseInt64JSON(pidRaw)
		if err != nil {
			return key, fmt.Errorf("invalid pid: %w", err)
		}
		key.pid, key.hasPID = value, true
	}
	if len(tidRaw) != 0 && !bytes.Equal(bytes.TrimSpace(tidRaw), []byte("null")) {
		value, err := parseInt64JSON(tidRaw)
		if err != nil {
			return key, fmt.Errorf("invalid tid: %w", err)
		}
		key.tid, key.hasTID = value, true
	}
	return key, nil
}

func parseInt64JSON(raw json.RawMessage) (int64, error) {
	value := strings.TrimSpace(string(raw))
	if value == "" {
		return 0, errors.New("missing integer")
	}
	return strconv.ParseInt(value, 10, 64)
}

func boundedArgs(raw json.RawMessage) ([]byte, bool, uint64, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil, false, 0, nil
	}
	original := uint64(len(raw))
	if len(trimmed) > MaxInspectorArgsBytes {
		return nil, true, original, nil
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, trimmed); err != nil {
		return nil, false, original, err
	}
	if compact.Len() > MaxInspectorArgsBytes {
		return nil, true, original, nil
	}
	within, err := argsWithinStructure(compact.Bytes())
	if err != nil {
		return nil, false, original, err
	}
	if !within {
		return nil, true, original, nil
	}
	return append([]byte(nil), compact.Bytes()...), false, original, nil
}

func argsWithinStructure(data []byte) (bool, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	fields := 0
	within, err := inspectJSONValue(decoder, 0, &fields)
	if err != nil || !within {
		return within, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		if err == nil {
			return false, errors.New("trailing argument JSON")
		}
		return false, err
	}
	return true, nil
}

func inspectJSONValue(decoder *json.Decoder, depth int, fields *int) (bool, error) {
	token, err := decoder.Token()
	if err != nil {
		return false, err
	}
	delim, isDelim := token.(json.Delim)
	if !isDelim || (delim != '{' && delim != '[') {
		return true, nil
	}
	depth++
	if depth > MaxInspectorDepth {
		return false, nil
	}
	if delim == '{' {
		for decoder.More() {
			if _, err := decoder.Token(); err != nil { // object key
				return false, err
			}
			*fields++
			if *fields > MaxInspectorFields {
				return false, nil
			}
			within, err := inspectJSONValue(decoder, depth, fields)
			if err != nil || !within {
				return within, err
			}
		}
	} else {
		for decoder.More() {
			*fields++
			if *fields > MaxInspectorFields {
				return false, nil
			}
			within, err := inspectJSONValue(decoder, depth, fields)
			if err != nil || !within {
				return within, err
			}
		}
	}
	if _, err := decoder.Token(); err != nil { // closing delimiter
		return false, err
	}
	return true, nil
}

func skipValue(decoder *json.Decoder, token json.Token) error {
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		for decoder.More() {
			if _, err := decoder.Token(); err != nil { // field name
				return err
			}
			value, err := decoder.Token()
			if err != nil {
				return err
			}
			if err := skipValue(decoder, value); err != nil {
				return err
			}
		}
		_, err := decoder.Token()
		return err
	case '[':
		for decoder.More() {
			value, err := decoder.Token()
			if err != nil {
				return err
			}
			if err := skipValue(decoder, value); err != nil {
				return err
			}
		}
		_, err := decoder.Token()
		return err
	default:
		return fmt.Errorf("unexpected delimiter %q", delim)
	}
}

func requireEOF(decoder *json.Decoder) error {
	if _, err := decoder.Token(); err == io.EOF {
		return nil
	} else if err != nil {
		return fmt.Errorf("read trailing data: %w", err)
	}
	return errors.New("trace contains trailing JSON data")
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }
