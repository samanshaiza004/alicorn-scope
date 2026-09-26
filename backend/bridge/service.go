package main

/*
#include "caliber_api.h"
*/
import "C"

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
	"unsafe"

	"github.com/samanshaiza004/alicorn-scope/backend/trace"
)

const (
	serviceStateSchema    = uint32(2)
	serviceCommandSchema  = uint32(2)
	serviceMaxBytes       = 1 << 20
	serviceMaxRows        = trace.MaxWindowRows
	serviceMaxArguments   = 256
	serviceProgressPeriod = 100 * time.Millisecond
	serviceStatusEmpty    = "empty"
	serviceStatusLoading  = "loading"
	serviceStatusReady    = "ready"
	serviceStatusFailed   = "failed"

	telemetryIdle    = uint64(0)
	telemetryLoading = uint64(1)
	telemetryReady   = uint64(2)
	telemetryFailed  = uint64(3)

	// CaliberStatus::Unavailable is 7 in the v1 ABI. The C header publishes
	// only the statuses needed by its callers, so the empty-queue value is
	// named here from the ABI contract.
	caliberUnavailable = int32(7)
)

type serviceCommand struct {
	Schema          uint32  `json:"schema"`
	Sequence        uint64  `json:"sequence"`
	ControlEpoch    uint64  `json:"control_epoch"`
	Kind            string  `json:"kind"`
	Path            string  `json:"path,omitempty"`
	Filter          string  `json:"filter,omitempty"`
	TrackID         uint64  `json:"track_id,omitempty"`
	Enabled         bool    `json:"enabled,omitempty"`
	TraceGeneration uint64  `json:"trace_generation,omitempty"`
	QueryGeneration uint64  `json:"query_generation,omitempty"`
	EventID         uint64  `json:"event_id,omitempty"`
	FirstRow        uint64  `json:"first_row,omitempty"`
	Count           uint32  `json:"count,omitempty"`
	StartUS         float64 `json:"start_us,omitempty"`
	EndUS           float64 `json:"end_us,omitempty"`
	ResolutionHint  uint32  `json:"resolution_hint,omitempty"`
}

type inspectorArgument struct {
	ID    uint64 `json:"id"`
	Name  string `json:"name"`
	Value string `json:"value"`
}

type selectedEventState struct {
	Available              bool                `json:"available"`
	ID                     uint64              `json:"id"`
	HasQueryRow            bool                `json:"has_query_row"`
	QueryRow               uint64              `json:"query_row"`
	Name                   string              `json:"name"`
	Category               string              `json:"category"`
	TimestampUS            float64             `json:"timestamp_us"`
	DurationUS             float64             `json:"duration_us"`
	Arguments              []inspectorArgument `json:"arguments"`
	ArgumentsTruncated     bool                `json:"arguments_truncated"`
	ArgumentsOriginalBytes uint64              `json:"arguments_original_bytes"`
}

type resourceHandleState struct {
	ID         uint64 `json:"id"`
	Generation uint64 `json:"generation"`
}

// serviceState is the stable state wire shape consumed by Odin. The same
// schema number is published through Caliber's outer state metadata.
type serviceState struct {
	Schema            uint32              `json:"schema"`
	TraceGeneration   uint64              `json:"trace_generation"`
	QueryGeneration   uint64              `json:"query_generation"`
	Status            string              `json:"status"`
	Path              string              `json:"path"`
	Message           string              `json:"message"`
	TrackCount        uint64              `json:"track_count"`
	TotalEvents       uint64              `json:"total_events"`
	MatchingEvents    uint64              `json:"matching_events"`
	VisibleEvents     uint64              `json:"visible_events"`
	UnsupportedPhases uint64              `json:"unsupported_phases"`
	TraceStartUS      float64             `json:"trace_start_us"`
	TraceEndUS        float64             `json:"trace_end_us"`
	TracksResource    resourceHandleState `json:"tracks_resource"`
	WindowResource    resourceHandleState `json:"window_resource"`
	TimelineResource  resourceHandleState `json:"timeline_resource"`
	TracksFirstRow    uint64              `json:"tracks_first_row"`
	WindowFirstRow    uint64              `json:"window_first_row"`
	SelectedEvent     selectedEventState  `json:"selected_event"`
}

type resourceRef struct {
	id         uint64
	generation uint64
}

func (r resourceRef) valid() bool { return r.id != 0 || r.generation != 0 }

type backendService struct {
	wake chan struct{}
	stop chan struct{}
	done chan struct{}

	stopped bool // protected by serviceMu

	sequence          uint64 // protected by serviceMu
	latestOpen        atomic.Uint64
	latestFilter      atomic.Uint64
	latestTrackWindow atomic.Uint64
	latestWindow      atomic.Uint64
	latestTimeline    atomic.Uint64
	controlEpoch      atomic.Uint64

	model            *trace.Model
	query            *trace.EventQuery
	traceGeneration  uint64
	queryGeneration  uint64
	filter           string
	disabledTracks   map[uint64]struct{}
	state            serviceState
	tracksResource   resourceRef
	windowResource   resourceRef
	timelineResource resourceRef
	retiredResources []resourceRef
}

var (
	serviceMu sync.Mutex
	service   *backendService
)

func emptySelectedEvent() selectedEventState {
	return selectedEventState{Arguments: []inspectorArgument{}}
}

func emptyServiceState() serviceState {
	return serviceState{
		Schema:        serviceStateSchema,
		Status:        serviceStatusEmpty,
		SelectedEvent: emptySelectedEvent(),
	}
}

func backendStart() error {
	serviceMu.Lock()
	defer serviceMu.Unlock()
	if service != nil {
		return errors.New("Alicorn Scope backend is already started")
	}

	s := &backendService{
		wake:           make(chan struct{}, 1),
		stop:           make(chan struct{}),
		done:           make(chan struct{}),
		disabledTracks: make(map[uint64]struct{}),
		state:          emptyServiceState(),
	}
	if status := publishServiceState(s.state); status != int32(C.CALIBER_OK) {
		return fmt.Errorf("publish initial state: Caliber status %d", status)
	}
	if status := publishProgress(telemetryIdle, 0, 0, 0, 0); status != int32(C.CALIBER_OK) {
		return fmt.Errorf("publish initial telemetry: Caliber status %d", status)
	}
	service = s
	go s.run()
	return nil
}

func backendStopWork() {
	serviceMu.Lock()
	s := service
	if s == nil {
		serviceMu.Unlock()
		return
	}
	if !s.stopped {
		s.stopped = true
		close(s.stop)
	}
	serviceMu.Unlock()
	<-s.done
}

// backendDestroy joins the worker and clears Go-owned bookkeeping. The C
// Caliber context remains the responsibility of exports.go.
func backendDestroy() {
	backendStopWork()
	serviceMu.Lock()
	service = nil
	serviceMu.Unlock()
}

func backendDispatchOpen(path string) int32 {
	if path == "" {
		return statusInvalidArgument
	}
	return dispatchServiceCommand(serviceCommand{Kind: "open", Path: path})
}

func backendDispatchFilter(value string) int32 {
	return dispatchServiceCommand(serviceCommand{Kind: "filter", Filter: value})
}

func backendDispatchTrack(traceGeneration, id uint64, enabled bool) int32 {
	return dispatchServiceCommand(serviceCommand{
		Kind:            "track",
		TraceGeneration: traceGeneration,
		TrackID:         id,
		Enabled:         enabled,
	})
}

func backendDispatchSelection(traceGen, eventID uint64) int32 {
	return dispatchServiceCommand(serviceCommand{Kind: "selection", TraceGeneration: traceGen, EventID: eventID})
}

func backendDispatchWindow(traceGen, queryGen, first uint64, count uint32) int32 {
	if !validWindowRange(first, count) {
		return statusInvalidArgument
	}
	return dispatchServiceCommand(serviceCommand{
		Kind:            "window",
		TraceGeneration: traceGen,
		QueryGeneration: queryGen,
		FirstRow:        first,
		Count:           count,
	})
}

func validWindowRange(first uint64, count uint32) bool {
	return count > 0 && count <= serviceMaxRows && first <= math.MaxUint64-uint64(count)
}

func backendDispatchTrackWindow(traceGen, queryGen, first uint64, count uint32) int32 {
	if !validWindowRange(first, count) {
		return statusInvalidArgument
	}
	return dispatchServiceCommand(serviceCommand{
		Kind:            "track_window",
		TraceGeneration: traceGen,
		QueryGeneration: queryGen,
		FirstRow:        first,
		Count:           count,
	})
}

func backendDispatchTimeline(traceGen, queryGen, trackID uint64, startUS, endUS float64, resolution uint32) int32 {
	if math.IsNaN(startUS) || math.IsInf(startUS, 0) || math.IsNaN(endUS) || math.IsInf(endUS, 0) || endUS <= startUS || resolution == 0 || resolution > trace.MaxTimelineRows {
		return statusInvalidArgument
	}
	return dispatchServiceCommand(serviceCommand{
		Kind: "timeline_window", TraceGeneration: traceGen, QueryGeneration: queryGen,
		TrackID: trackID, StartUS: startUS, EndUS: endUS, ResolutionHint: resolution,
	})
}

func dispatchServiceCommand(command serviceCommand) int32 {
	serviceMu.Lock()
	s := service
	if s == nil || s.stopped {
		serviceMu.Unlock()
		return statusUnavailable
	}
	if s.sequence == ^uint64(0) {
		serviceMu.Unlock()
		return statusInternal
	}
	s.sequence++
	command.Schema = serviceCommandSchema
	command.Sequence = s.sequence
	command.ControlEpoch = s.controlEpoch.Load()
	advancesControl := command.Kind == "open" || command.Kind == "filter" || command.Kind == "track"
	if advancesControl {
		if command.ControlEpoch == ^uint64(0) {
			serviceMu.Unlock()
			return statusInternal
		}
		command.ControlEpoch++
	}
	data, err := json.Marshal(command)
	if err != nil {
		serviceMu.Unlock()
		return statusInternal
	}
	if len(data) == 0 || len(data) > serviceMaxBytes {
		serviceMu.Unlock()
		return statusInvalidArgument
	}
	status := int32(C.scope_caliber_dispatch(
		(*C.uint8_t)(unsafe.Pointer(&data[0])),
		C.size_t(len(data)),
	))
	if status == int32(C.CALIBER_OK) {
		if advancesControl {
			s.controlEpoch.Store(command.ControlEpoch)
		}
		switch command.Kind {
		case "open":
			s.latestOpen.Store(command.Sequence)
		case "filter":
			s.latestFilter.Store(command.Sequence)
		case "window":
			s.latestWindow.Store(command.Sequence)
		case "track_window":
			s.latestTrackWindow.Store(command.Sequence)
		case "timeline_window":
			s.latestTimeline.Store(command.Sequence)
		}
		select {
		case s.wake <- struct{}{}:
		default:
		}
	}
	serviceMu.Unlock()
	return status
}

func (s *backendService) run() {
	defer close(s.done)
	defer s.releaseAllResources()
	commandBuffer := make([]byte, serviceMaxBytes)
	for {
		select {
		case <-s.stop:
			return
		case <-s.wake:
		}
		if s.isStopping() {
			return
		}
		if !s.drainCommands(commandBuffer) {
			return
		}
	}
}

func (s *backendService) isStopping() bool {
	select {
	case <-s.stop:
		return true
	default:
		return false
	}
}

func (s *backendService) drainCommands(buffer []byte) bool {
	var latestWindow *serviceCommand
	var latestTrackWindow *serviceCommand
	var latestTimeline *serviceCommand
	for !s.isStopping() {
		var length C.size_t
		serviceMu.Lock()
		if s.stopped {
			serviceMu.Unlock()
			return false
		}
		status := int32(C.scope_caliber_take_command(
			(*C.uint8_t)(unsafe.Pointer(&buffer[0])),
			C.size_t(len(buffer)),
			&length,
		))
		serviceMu.Unlock()

		if status == caliberUnavailable {
			break
		}
		if status == int32(C.CALIBER_STOPPED) {
			return false
		}
		if status != int32(C.CALIBER_OK) || uint64(length) > uint64(len(buffer)) {
			return false
		}
		var command serviceCommand
		if err := json.Unmarshal(buffer[:int(length)], &command); err != nil || command.Schema != serviceCommandSchema {
			continue
		}
		switch command.Kind {
		case "open":
			s.processOpen(command)
		case "filter":
			s.processFilter(command)
		case "track":
			s.processTrack(command)
		case "selection":
			s.processSelection(command)
		case "window":
			latestWindow = coalesceWindowCommand(latestWindow, command)
		case "track_window":
			latestTrackWindow = coalesceWindowCommand(latestTrackWindow, command)
		case "timeline_window":
			latestTimeline = coalesceWindowCommand(latestTimeline, command)
		}
	}
	if latestTrackWindow != nil && !s.isStopping() {
		s.processTrackWindow(*latestTrackWindow)
	}
	if latestWindow != nil && !s.isStopping() {
		s.processWindow(*latestWindow)
	}
	if latestTimeline != nil && !s.isStopping() {
		s.processTimelineWindow(*latestTimeline)
	}
	return !s.isStopping()
}

func (s *backendService) processOpen(command serviceCommand) {
	if command.Sequence != s.latestOpen.Load() || s.isStopping() {
		return
	}
	loading := s.state
	loading.Status = serviceStatusLoading
	loading.Message = boundedMessage("Loading " + command.Path)
	if !s.publishStateIfCurrent(loading, func() bool {
		return command.Sequence == s.latestOpen.Load()
	}) {
		return
	}
	if s.traceGeneration == ^uint64(0) || s.queryGeneration == ^uint64(0) {
		s.failOpen(command, errors.New("trace or query generation exhausted"), 0, 0)
		return
	}
	candidateTraceGeneration := s.traceGeneration + 1
	model, bytesRead, bytesTotal, err := parseTrace(command.Path, candidateTraceGeneration, s, command.Sequence)
	if err != nil {
		if command.Sequence == s.latestOpen.Load() && !s.isStopping() {
			s.failOpen(command, err, bytesRead, bytesTotal)
		}
		return
	}
	if command.Sequence != s.latestOpen.Load() || s.isStopping() {
		return
	}
	candidateQueryGeneration := s.queryGeneration + 1
	query := model.NewEventQuery(nil, s.filter)
	trackRef, windowRef, page, err := s.buildPairResources(model, query, nil, candidateTraceGeneration, candidateQueryGeneration, 0, serviceMaxRows)
	if err != nil {
		s.failOpen(command, err, bytesRead, bytesTotal)
		return
	}

	candidateState := s.state
	candidateState.Schema = serviceStateSchema
	candidateState.TraceGeneration = candidateTraceGeneration
	candidateState.QueryGeneration = candidateQueryGeneration
	candidateState.Status = serviceStatusReady
	candidateState.Path = boundedPath(command.Path)
	candidateState.Message = ""
	candidateState.TrackCount = model.TrackCount()
	candidateState.TotalEvents = model.EventCount()
	candidateState.MatchingEvents = query.Count()
	candidateState.VisibleEvents = uint64(len(page.Rows))
	candidateState.UnsupportedPhases = model.UnsupportedPhaseCount()
	candidateState.TraceStartUS, candidateState.TraceEndUS, _ = model.TraceBounds()
	candidateState.TracksResource = resourceHandleState{ID: trackRef.id, Generation: trackRef.generation}
	candidateState.WindowResource = resourceHandleState{ID: windowRef.id, Generation: windowRef.generation}
	candidateState.TimelineResource = resourceHandleState{}
	candidateState.TracksFirstRow = 0
	candidateState.WindowFirstRow = page.FirstRow
	candidateState.SelectedEvent = emptySelectedEvent()

	serviceMu.Lock()
	if s.stopped || command.Sequence != s.latestOpen.Load() {
		serviceMu.Unlock()
		s.releaseResource(trackRef)
		s.releaseResource(windowRef)
		return
	}
	status := publishServiceState(candidateState)
	if status != int32(C.CALIBER_OK) {
		serviceMu.Unlock()
		s.releaseResource(trackRef)
		s.releaseResource(windowRef)
		s.failOpen(command, fmt.Errorf("publish loaded trace state: Caliber status %d", status), bytesRead, bytesTotal)
		return
	}
	s.model = model
	s.query = query
	s.traceGeneration = candidateTraceGeneration
	s.queryGeneration = candidateQueryGeneration
	s.disabledTracks = make(map[uint64]struct{})
	s.state = candidateState
	s.commitResourcePair(trackRef, windowRef)
	serviceMu.Unlock()
	_ = publishProgress(telemetryReady, bytesRead, bytesTotal, s.traceGeneration, s.queryGeneration)
}

func parseTrace(path string, generation uint64, s *backendService, openSequence uint64) (*trace.Model, uint64, uint64, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("open %q: %w", boundedPath(path), err)
	}
	defer file.Close()
	fileInfo, err := file.Stat()
	if err != nil {
		return nil, 0, 0, fmt.Errorf("stat %q: %w", boundedPath(path), err)
	}
	totalBytes := uint64(0)
	if fileInfo.Size() > 0 {
		totalBytes = uint64(fileInfo.Size())
	}
	reader := &interruptibleTraceReader{
		file:             file,
		service:          s,
		openSequence:     openSequence,
		totalBytes:       totalBytes,
		traceGeneration:  s.traceGeneration,
		queryGeneration:  s.queryGeneration,
		lastProgressSent: time.Now(),
	}
	_ = publishProgress(telemetryLoading, 0, totalBytes, s.traceGeneration, s.queryGeneration)
	model, err := trace.Parse(reader, generation)
	if err != nil {
		return nil, reader.bytesRead, totalBytes, fmt.Errorf("parse %q: %w", boundedPath(path), err)
	}
	return model, reader.bytesRead, totalBytes, nil
}

type interruptibleTraceReader struct {
	file             *os.File
	service          *backendService
	openSequence     uint64
	bytesRead        uint64
	totalBytes       uint64
	traceGeneration  uint64
	queryGeneration  uint64
	lastProgressSent time.Time
}

var errTraceWorkStopped = errors.New("trace work stopped")
var errTraceOpenSuperseded = errors.New("trace open superseded")

func (r *interruptibleTraceReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if r.service.isStopping() {
		return 0, errTraceWorkStopped
	}
	if r.openSequence != r.service.latestOpen.Load() {
		return 0, errTraceOpenSuperseded
	}
	n, err := r.file.Read(p)
	if n > 0 {
		r.bytesRead += uint64(n)
		now := time.Now()
		if now.Sub(r.lastProgressSent) >= serviceProgressPeriod {
			// Caliber retains only the latest telemetry sample. These five words
			// are phase, bytes_read, bytes_total, trace_generation, query_generation.
			_ = publishProgress(telemetryLoading, r.bytesRead, r.totalBytes, r.traceGeneration, r.queryGeneration)
			r.lastProgressSent = now
		}
	}
	return n, err
}

func (s *backendService) failOpen(command serviceCommand, err error, bytesRead, bytesTotal uint64) {
	if command.Sequence != s.latestOpen.Load() || s.isStopping() {
		return
	}
	candidate := s.state
	candidate.Status = serviceStatusFailed
	candidate.Message = boundedMessage(fmt.Sprintf("Unable to load %q: %v", command.Path, err))
	if s.publishStateIfCurrent(candidate, func() bool {
		return command.Sequence == s.latestOpen.Load()
	}) {
		_ = publishProgress(telemetryFailed, bytesRead, bytesTotal, s.traceGeneration, s.queryGeneration)
	}
}

func (s *backendService) processFilter(command serviceCommand) {
	if command.Sequence != s.latestFilter.Load() || s.isStopping() || command.Filter == s.filter {
		return
	}
	if s.queryGeneration == ^uint64(0) {
		return
	}
	s.filter = command.Filter
	s.queryGeneration++
	if s.model == nil {
		candidate := s.state
		candidate.QueryGeneration = s.queryGeneration
		if s.publishStateIfCurrent(candidate, func() bool {
			return command.Sequence == s.latestFilter.Load()
		}) {
			s.state = candidate
		}
		return
	}
	s.rebuildQuery(command.ControlEpoch)
}

func (s *backendService) processTrack(command serviceCommand) {
	if s.isStopping() || s.model == nil || !trackCommandMatches(command, s.traceGeneration) || !s.modelHasTrack(command.TrackID) {
		return
	}
	_, disabled := s.disabledTracks[command.TrackID]
	currentlyEnabled := !disabled
	if currentlyEnabled == command.Enabled || s.queryGeneration == ^uint64(0) {
		return
	}
	if command.Enabled {
		delete(s.disabledTracks, command.TrackID)
	} else {
		s.disabledTracks[command.TrackID] = struct{}{}
	}
	s.queryGeneration++
	s.rebuildQuery(command.ControlEpoch)
}

func (s *backendService) rebuildQuery(controlEpoch uint64) {
	if s.model == nil || s.isStopping() {
		return
	}
	queryGeneration := s.queryGeneration
	enabledTrackIDs := s.enabledTrackIDs()
	query := s.model.NewEventQuery(enabledTrackIDs, s.filter)
	trackRef, windowRef, page, err := s.buildPairResources(s.model, query, enabledTrackIDs, s.traceGeneration, queryGeneration, 0, serviceMaxRows)
	if err != nil {
		return
	}
	candidate := s.state
	candidate.QueryGeneration = queryGeneration
	candidate.TrackCount = s.model.TrackCount()
	candidate.TotalEvents = s.model.EventCount()
	candidate.MatchingEvents = query.Count()
	candidate.VisibleEvents = uint64(len(page.Rows))
	candidate.UnsupportedPhases = s.model.UnsupportedPhaseCount()
	candidate.TracksResource = resourceHandleState{ID: trackRef.id, Generation: trackRef.generation}
	candidate.WindowResource = resourceHandleState{ID: windowRef.id, Generation: windowRef.generation}
	candidate.TimelineResource = resourceHandleState{}
	candidate.TracksFirstRow = 0
	candidate.WindowFirstRow = page.FirstRow

	serviceMu.Lock()
	if s.stopped || s.controlEpoch.Load() != controlEpoch {
		serviceMu.Unlock()
		s.releaseResource(trackRef)
		s.releaseResource(windowRef)
		return
	}
	status := publishServiceState(candidate)
	if status != int32(C.CALIBER_OK) {
		serviceMu.Unlock()
		s.releaseResource(trackRef)
		s.releaseResource(windowRef)
		return
	}
	s.query = query
	s.state = candidate
	s.commitResourcePair(trackRef, windowRef)
	serviceMu.Unlock()
}

func (s *backendService) processSelection(command serviceCommand) {
	if s.isStopping() || s.model == nil || command.TraceGeneration != s.traceGeneration {
		return
	}
	details, ok := s.model.LookupEvent(command.EventID)
	candidate := s.state
	if !ok {
		candidate.SelectedEvent = emptySelectedEvent()
	} else {
		arguments, wasTruncated := inspectorArguments(details.ArgsJSON)
		queryRow, hasQueryRow := s.query.RowForEventID(details.Event.ID)
		candidate.SelectedEvent = selectedEventState{
			Available:              true,
			ID:                     details.Event.ID,
			HasQueryRow:            hasQueryRow,
			QueryRow:               queryRow,
			Name:                   boundedStateText(details.Event.Name),
			Category:               boundedStateText(details.Event.Category),
			TimestampUS:            details.Event.TimestampUS,
			DurationUS:             details.Event.DurationUS,
			Arguments:              arguments,
			ArgumentsTruncated:     details.ArgsTruncated || wasTruncated,
			ArgumentsOriginalBytes: details.ArgsOriginalBytes,
		}
	}
	serviceMu.Lock()
	if s.stopped || command.TraceGeneration != s.traceGeneration {
		serviceMu.Unlock()
		return
	}
	if publishServiceState(candidate) == int32(C.CALIBER_OK) {
		s.state = candidate
	}
	serviceMu.Unlock()
}

func (s *backendService) processWindow(command serviceCommand) {
	if s.model == nil || s.query == nil || s.isStopping() ||
		!windowRequestIsCurrent(command, s.traceGeneration, s.queryGeneration, s.latestWindow.Load(), s.controlEpoch.Load()) {
		return
	}
	page := s.query.Window(command.FirstRow, uint64(command.Count))
	data, err := trace.EncodeEventWindow(s.query, page, s.traceGeneration, s.queryGeneration)
	if err != nil || len(data) > serviceMaxBytes {
		return
	}
	s.releaseRetiredResources()
	windowRef, status := publishServiceResource(data)
	if status != int32(C.CALIBER_OK) {
		return
	}
	candidate := s.state
	candidate.VisibleEvents = uint64(len(page.Rows))
	candidate.WindowResource = resourceHandleState{ID: windowRef.id, Generation: windowRef.generation}
	candidate.WindowFirstRow = page.FirstRow

	serviceMu.Lock()
	if s.stopped || !windowRequestIsCurrent(command, s.traceGeneration, s.queryGeneration, s.latestWindow.Load(), s.controlEpoch.Load()) {
		serviceMu.Unlock()
		s.releaseResource(windowRef)
		return
	}
	if publishServiceState(candidate) != int32(C.CALIBER_OK) {
		serviceMu.Unlock()
		s.releaseResource(windowRef)
		return
	}
	s.state = candidate
	s.commitWindowResource(windowRef)
	serviceMu.Unlock()
}

func (s *backendService) processTimelineWindow(command serviceCommand) {
	if s.model == nil || s.query == nil || s.isStopping() ||
		!timelineRequestIsCurrent(command, s.traceGeneration, s.queryGeneration, s.latestTimeline.Load(), s.controlEpoch.Load()) {
		return
	}
	window := s.query.TimelineWindow(command.TrackID, command.StartUS, command.EndUS, command.ResolutionHint, s.traceGeneration, s.queryGeneration)
	data, err := trace.EncodeTimelineWindow(window)
	if err != nil || len(data) > serviceMaxBytes {
		return
	}
	s.releaseRetiredResources()
	timelineRef, status := publishServiceResource(data)
	if status != int32(C.CALIBER_OK) {
		return
	}
	candidate := s.state
	candidate.TimelineResource = resourceHandleState{ID: timelineRef.id, Generation: timelineRef.generation}
	serviceMu.Lock()
	if s.stopped || !timelineRequestIsCurrent(command, s.traceGeneration, s.queryGeneration, s.latestTimeline.Load(), s.controlEpoch.Load()) {
		serviceMu.Unlock()
		s.releaseResource(timelineRef)
		return
	}
	if publishServiceState(candidate) != int32(C.CALIBER_OK) {
		serviceMu.Unlock()
		s.releaseResource(timelineRef)
		return
	}
	s.state = candidate
	s.commitTimelineResource(timelineRef)
	serviceMu.Unlock()
}

func (s *backendService) processTrackWindow(command serviceCommand) {
	if s.model == nil || s.isStopping() ||
		!windowRequestIsCurrent(command, s.traceGeneration, s.queryGeneration, s.latestTrackWindow.Load(), s.controlEpoch.Load()) {
		return
	}
	enabledTrackIDs := s.enabledTrackIDs()
	trackPage := s.model.TrackWindow(command.FirstRow, uint64(command.Count))
	data, err := trace.EncodeTrackCatalog(s.model, enabledTrackIDs, command.FirstRow, uint64(command.Count), s.traceGeneration, s.queryGeneration)
	if err != nil || len(data) > serviceMaxBytes {
		return
	}
	s.releaseRetiredResources()
	tracksRef, status := publishServiceResource(data)
	if status != int32(C.CALIBER_OK) {
		return
	}
	candidate := s.state
	candidate.TracksResource = resourceHandleState{ID: tracksRef.id, Generation: tracksRef.generation}
	candidate.TracksFirstRow = trackPage.FirstRow

	serviceMu.Lock()
	if s.stopped || !windowRequestIsCurrent(command, s.traceGeneration, s.queryGeneration, s.latestTrackWindow.Load(), s.controlEpoch.Load()) {
		serviceMu.Unlock()
		s.releaseResource(tracksRef)
		return
	}
	if publishServiceState(candidate) != int32(C.CALIBER_OK) {
		serviceMu.Unlock()
		s.releaseResource(tracksRef)
		return
	}
	s.state = candidate
	s.commitTracksResource(tracksRef)
	serviceMu.Unlock()
}

func coalesceWindowCommand(current *serviceCommand, next serviceCommand) *serviceCommand {
	if current != nil && current.Sequence >= next.Sequence {
		return current
	}
	copy := next
	return &copy
}

func windowRequestIsCurrent(command serviceCommand, traceGeneration, queryGeneration, latestSequence, controlEpoch uint64) bool {
	return command.TraceGeneration == traceGeneration &&
		command.QueryGeneration == queryGeneration &&
		command.Sequence == latestSequence &&
		command.ControlEpoch == controlEpoch
}

func timelineRequestIsCurrent(command serviceCommand, traceGeneration, queryGeneration, latestSequence, controlEpoch uint64) bool {
	return command.Kind == "timeline_window" && command.TraceGeneration == traceGeneration &&
		command.QueryGeneration == queryGeneration && command.Sequence == latestSequence &&
		command.ControlEpoch == controlEpoch &&
		!math.IsNaN(command.StartUS) && !math.IsInf(command.StartUS, 0) &&
		!math.IsNaN(command.EndUS) && !math.IsInf(command.EndUS, 0) && command.EndUS > command.StartUS &&
		command.ResolutionHint > 0 && command.ResolutionHint <= trace.MaxTimelineRows
}

func trackCommandMatches(command serviceCommand, traceGeneration uint64) bool {
	return command.TraceGeneration == traceGeneration
}

func (s *backendService) modelHasTrack(id uint64) bool {
	if s.model == nil {
		return false
	}
	total := s.model.TrackCount()
	for first := uint64(0); first < total; first += serviceMaxRows {
		page := s.model.TrackWindow(first, serviceMaxRows)
		for _, track := range page.Rows {
			if track.ID == id {
				return true
			}
		}
	}
	return false
}

func (s *backendService) enabledTrackIDs() []uint64 {
	if s.model == nil || len(s.disabledTracks) == 0 {
		return nil
	}
	ids := make([]uint64, 0, s.model.TrackCount()-uint64(len(s.disabledTracks)))
	for first, total := uint64(0), s.model.TrackCount(); first < total; first += serviceMaxRows {
		page := s.model.TrackWindow(first, serviceMaxRows)
		for _, track := range page.Rows {
			if _, disabled := s.disabledTracks[track.ID]; !disabled {
				ids = append(ids, track.ID)
			}
		}
	}
	return ids
}

func (s *backendService) buildPairResources(model *trace.Model, query *trace.EventQuery, enabledTrackIDs []uint64, traceGeneration, queryGeneration, first, count uint64) (resourceRef, resourceRef, trace.EventPage, error) {
	trackData, err := trace.EncodeTrackCatalog(model, enabledTrackIDs, 0, serviceMaxRows, traceGeneration, queryGeneration)
	if err != nil {
		return resourceRef{}, resourceRef{}, trace.EventPage{}, fmt.Errorf("encode track catalog: %w", err)
	}
	page := query.Window(first, count)
	eventData, err := trace.EncodeEventWindow(query, page, traceGeneration, queryGeneration)
	if err != nil {
		return resourceRef{}, resourceRef{}, trace.EventPage{}, fmt.Errorf("encode event window: %w", err)
	}
	if len(trackData) > serviceMaxBytes || len(eventData) > serviceMaxBytes {
		return resourceRef{}, resourceRef{}, trace.EventPage{}, errors.New("encoded resource exceeds 1 MiB")
	}
	s.releaseRetiredResources()
	trackRef, status := publishServiceResource(trackData)
	if status != int32(C.CALIBER_OK) {
		return resourceRef{}, resourceRef{}, trace.EventPage{}, fmt.Errorf("publish track catalog: Caliber status %d", status)
	}
	windowRef, status := publishServiceResource(eventData)
	if status != int32(C.CALIBER_OK) {
		s.releaseResource(trackRef)
		return resourceRef{}, resourceRef{}, trace.EventPage{}, fmt.Errorf("publish event window: Caliber status %d", status)
	}
	return trackRef, windowRef, page, nil
}

func (s *backendService) commitResourcePair(tracks, window resourceRef) {
	oldTracks, oldWindow := s.tracksResource, s.windowResource
	s.tracksResource, s.windowResource = tracks, window
	s.retireResource(oldTracks)
	s.retireResource(oldWindow)
	oldTimeline := s.timelineResource
	s.timelineResource = resourceRef{}
	s.retireResource(oldTimeline)
}

func (s *backendService) commitTimelineResource(timeline resourceRef) {
	old := s.timelineResource
	s.timelineResource = timeline
	s.retireResource(old)
}

func (s *backendService) commitWindowResource(window resourceRef) {
	old := s.windowResource
	s.windowResource = window
	s.retireResource(old)
}

func (s *backendService) commitTracksResource(tracks resourceRef) {
	old := s.tracksResource
	s.tracksResource = tracks
	s.retireResource(old)
}

func (s *backendService) retireResource(ref resourceRef) {
	if !ref.valid() || sameResource(ref, s.tracksResource) || sameResource(ref, s.windowResource) || sameResource(ref, s.timelineResource) {
		return
	}
	for _, prior := range s.retiredResources {
		if sameResource(ref, prior) {
			return
		}
	}
	s.retiredResources = append(s.retiredResources, ref)
}

func (s *backendService) releaseRetiredResources() {
	for _, ref := range s.retiredResources {
		s.releaseResource(ref)
	}
	s.retiredResources = nil
}

func (s *backendService) releaseAllResources() {
	seen := make(map[resourceRef]struct{}, len(s.retiredResources)+3)
	for _, ref := range append(append([]resourceRef{}, s.retiredResources...), s.tracksResource, s.windowResource, s.timelineResource) {
		if !ref.valid() {
			continue
		}
		if _, exists := seen[ref]; exists {
			continue
		}
		seen[ref] = struct{}{}
		s.releaseResource(ref)
	}
	s.retiredResources = nil
	s.tracksResource, s.windowResource, s.timelineResource = resourceRef{}, resourceRef{}, resourceRef{}
}

func (s *backendService) releaseResource(ref resourceRef) {
	if ref.valid() {
		_ = C.scope_caliber_release_resource(C.uint64_t(ref.id), C.uint64_t(ref.generation))
	}
}

func sameResource(a, b resourceRef) bool {
	return a.id == b.id && a.generation == b.generation
}

func (s *backendService) publishStateIfCurrent(candidate serviceState, current func() bool) bool {
	serviceMu.Lock()
	defer serviceMu.Unlock()
	if s.stopped || !current() {
		return false
	}
	if publishServiceState(candidate) != int32(C.CALIBER_OK) {
		return false
	}
	s.state = candidate
	return true
}

func publishServiceState(state serviceState) int32 {
	data, err := json.Marshal(state)
	if err != nil {
		return statusInternal
	}
	if len(data) > serviceMaxBytes {
		return statusInvalidArgument
	}
	var revision C.uint64_t
	return int32(C.scope_caliber_publish_state(
		C.uint32_t(serviceStateSchema),
		(*C.uint8_t)(unsafe.Pointer(&data[0])),
		C.size_t(len(data)),
		&revision,
	))
}

func publishServiceResource(data []byte) (resourceRef, int32) {
	if len(data) == 0 || len(data) > serviceMaxBytes {
		return resourceRef{}, statusInvalidArgument
	}
	var id, generation C.uint64_t
	status := int32(C.scope_caliber_publish_resource(
		(*C.uint8_t)(unsafe.Pointer(&data[0])),
		C.size_t(len(data)),
		&id,
		&generation,
	))
	if status != int32(C.CALIBER_OK) {
		return resourceRef{}, status
	}
	return resourceRef{id: uint64(id), generation: uint64(generation)}, status
}

// publishProgress sends [phase, bytes_read, bytes_total, trace_generation,
// query_generation]. Parse updates are throttled by serviceProgressPeriod;
// Caliber replaces older telemetry samples with the newest one.
func publishProgress(phase, bytesRead, bytesTotal, traceGeneration, queryGeneration uint64) int32 {
	words := progressTelemetryWords(phase, bytesRead, bytesTotal, traceGeneration, queryGeneration)
	values := [5]C.size_t{
		C.size_t(words[0]),
		C.size_t(words[1]),
		C.size_t(words[2]),
		C.size_t(words[3]),
		C.size_t(words[4]),
	}
	return int32(C.scope_caliber_publish_telemetry(&values[0], C.size_t(len(values))))
}

// Telemetry byte counts are raw input-file bytes, not parser records or
// resource bytes. Keep the five-word order synchronized with the Odin reader.
func progressTelemetryWords(phase, bytesRead, bytesTotal, traceGeneration, queryGeneration uint64) [5]uint64 {
	return [5]uint64{phase, bytesRead, bytesTotal, traceGeneration, queryGeneration}
}

func inspectorArguments(data []byte) ([]inspectorArgument, bool) {
	arguments := make([]inspectorArgument, 0)
	if len(data) == 0 {
		return arguments, false
	}
	trimmed := bytes.TrimSpace(data)
	switch {
	case len(trimmed) != 0 && trimmed[0] == '{':
		var fields map[string]json.RawMessage
		if json.Unmarshal(trimmed, &fields) != nil {
			return arguments, true
		}
		names := make([]string, 0, len(fields))
		for name := range fields {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			arguments = append(arguments, inspectorArgument{ID: stableArgumentID(name), Name: name, Value: argumentValue(fields[name])})
		}
	case len(trimmed) != 0 && trimmed[0] == '[':
		var values []json.RawMessage
		if json.Unmarshal(trimmed, &values) != nil {
			return arguments, true
		}
		for i, value := range values {
			name := fmt.Sprintf("%d", i)
			arguments = append(arguments, inspectorArgument{ID: stableArgumentID(name), Name: name, Value: argumentValue(value)})
		}
	default:
		arguments = append(arguments, inspectorArgument{ID: stableArgumentID("value"), Name: "value", Value: argumentValue(trimmed)})
	}
	if len(arguments) > serviceMaxArguments {
		arguments = arguments[:serviceMaxArguments]
	}
	return boundInspectorOutput(arguments)
}

func argumentValue(raw []byte) string {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return ""
	}
	if trimmed[0] == '"' {
		var value string
		if json.Unmarshal(trimmed, &value) == nil {
			return value
		}
	}
	var compact bytes.Buffer
	if json.Compact(&compact, trimmed) == nil {
		return compact.String()
	}
	return string(trimmed)
}

func boundInspectorOutput(arguments []inspectorArgument) ([]inspectorArgument, bool) {
	if len(arguments) > serviceMaxArguments {
		arguments = arguments[:serviceMaxArguments]
	}
	full, err := json.Marshal(arguments)
	if err == nil && len(full) <= trace.MaxInspectorArgsBytes {
		return arguments, false
	}
	out := make([]inspectorArgument, 0, len(arguments))
	for _, argument := range arguments {
		candidate := append(append([]inspectorArgument(nil), out...), argument)
		encoded, marshalErr := json.Marshal(candidate)
		if marshalErr == nil && len(encoded) <= trace.MaxInspectorArgsBytes {
			out = candidate
			continue
		}
		if len(out) >= serviceMaxArguments {
			break
		}
		base, _ := json.Marshal(out)
		remaining := trace.MaxInspectorArgsBytes - len(base)
		if remaining < 96 {
			break
		}
		nameLimit := remaining / 5
		valueLimit := remaining - nameLimit
		argument.Name = utf8Prefix(argument.Name, nameLimit)
		argument.Value = utf8Prefix(argument.Value, valueLimit)
		for {
			candidate = append(append([]inspectorArgument(nil), out...), argument)
			encoded, marshalErr = json.Marshal(candidate)
			if marshalErr == nil && len(encoded) <= trace.MaxInspectorArgsBytes {
				out = candidate
				break
			}
			if len(argument.Value) >= len(argument.Name) && len(argument.Value) != 0 {
				argument.Value = utf8Prefix(argument.Value, len(argument.Value)/2)
			} else if len(argument.Name) != 0 {
				argument.Name = utf8Prefix(argument.Name, len(argument.Name)/2)
			} else {
				break
			}
		}
		break
	}
	return out, true
}

func stableArgumentID(name string) uint64 {
	h := fnv.New64a()
	_, _ = io.WriteString(h, name)
	id := h.Sum64()
	if id == 0 {
		return 1
	}
	return id
}

func utf8Prefix(value string, maxBytes int) string {
	if maxBytes <= 0 {
		return ""
	}
	if len(value) <= maxBytes {
		return value
	}
	end := maxBytes
	for end > 0 && !utf8.RuneStart(value[end]) {
		end--
	}
	return value[:end]
}

func boundedPath(path string) string {
	return utf8Prefix(path, 4096)
}

func boundedStateText(value string) string {
	return utf8Prefix(value, 16<<10)
}

func boundedMessage(message string) string {
	return utf8Prefix(strings.ToValidUTF8(message, "�"), 4096)
}
