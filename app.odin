package main

import "core:dynlib"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import alicorn "../alicorn/runtime"
import frontend "./frontend"
import host "../alicorn/native/sdl_gpu"

SCOPE_RESOURCE_LIMIT :: 1 << 20
SCOPE_EVENT_WINDOW_ROWS :: 512

Caliber_Status_OK      :: i32(0)
Caliber_Status_Stopped :: i32(11)

Scope_Backend_API :: struct {
	create: proc "c" (path: cstring, length: uintptr) -> i32 `dynlib:"Scope_Create"`,
	stop_work: proc "c" () -> i32 `dynlib:"Scope_StopWork"`,
	stop_waiters: proc "c" () -> i32 `dynlib:"Scope_StopWakeWaiters"`,
	destroy: proc "c" () `dynlib:"Scope_Destroy"`,
	wake_sequence: proc "c" (out: ^u64) -> i32 `dynlib:"Scope_WakeSequence"`,
	wait_wake: proc "c" (observed: u64, out: ^u64) -> i32 `dynlib:"Scope_WaitWake"`,
	open_trace: proc "c" (path: cstring, length: uintptr) -> i32 `dynlib:"Scope_OpenTrace"`,
	set_filter: proc "c" (filter: cstring, length: uintptr) -> i32 `dynlib:"Scope_SetFilter"`,
	set_track_enabled: proc "c" (trace_generation, track_id: u64, enabled: i32) -> i32 `dynlib:"Scope_SetTrackEnabled"`,
	request_tracks: proc "c" (trace_generation, query_generation, first: u64, count: u32) -> i32 `dynlib:"Scope_RequestTrackWindow"`,
	select_event: proc "c" (trace_generation, event_id: u64) -> i32 `dynlib:"Scope_SelectEvent"`,
	request_window: proc "c" (trace_generation, query_generation, first: u64, count: u32) -> i32 `dynlib:"Scope_RequestEventWindow"`,
	read_state: proc "c" (dst: ^u8, capacity: uintptr, out_length: ^uintptr, revision: ^u64, schema: ^u32) -> i32 `dynlib:"Scope_ReadState"`,
	read_resource: proc "c" (id, generation: u64, dst: ^u8, capacity: uintptr, out_length: ^uintptr) -> i32 `dynlib:"Scope_ReadResource"`,
	read_telemetry: proc "c" (dst: ^uintptr, capacity: uintptr, out_count: ^uintptr, sequence: ^u64) -> i32 `dynlib:"Scope_ReadTelemetry"`,
	_library: dynlib.Library,
}

Scope_Argument_State :: struct {
	id: u64 `json:"id"`,
	name: string `json:"name"`,
	value: string `json:"value"`,
}

Scope_Selected_Event_State :: struct {
	available: bool `json:"available"`,
	id: u64 `json:"id"`,
	name: string `json:"name"`,
	category: string `json:"category"`,
	timestamp_us: f64 `json:"timestamp_us"`,
	duration_us: f64 `json:"duration_us"`,
	arguments: []Scope_Argument_State `json:"arguments"`,
	arguments_truncated: bool `json:"arguments_truncated"`,
	arguments_original_bytes: u64 `json:"arguments_original_bytes"`,
}

Scope_Resource_Handle :: struct {
	id: u64 `json:"id"`,
	generation: u64 `json:"generation"`,
}

Scope_Published_State :: struct {
	schema: u32 `json:"schema"`,
	trace_generation: u64 `json:"trace_generation"`,
	query_generation: u64 `json:"query_generation"`,
	status: string `json:"status"`,
	path: string `json:"path"`,
	message: string `json:"message"`,
	track_count: u64 `json:"track_count"`,
	total_events: u64 `json:"total_events"`,
	matching_events: u64 `json:"matching_events"`,
	visible_events: u64 `json:"visible_events"`,
	unsupported_phases: u64 `json:"unsupported_phases"`,
	tracks_resource: Scope_Resource_Handle `json:"tracks_resource"`,
	window_resource: Scope_Resource_Handle `json:"window_resource"`,
	window_first_row: u64 `json:"window_first_row"`,
	tracks_first_row: u64 `json:"tracks_first_row"`,
	selected_event: Scope_Selected_Event_State `json:"selected_event"`,
}

Scope_App :: struct {
	backend: Scope_Backend_API,
	backend_created: bool,
	view: frontend.Scope_View,
	tracks: [dynamic]frontend.Scope_Track,
	events: [dynamic]frontend.Scope_Event_Row,
	arguments: [dynamic]frontend.Scope_Argument,
	state: Scope_Published_State,
	state_bytes: []byte,
	resource_scratch: []byte,
	state_revision: u64,
	track_resource: Scope_Resource_Handle,
	window_resource: Scope_Resource_Handle,
	loaded_track_resource: Scope_Resource_Handle,
	loaded_window_resource: Scope_Resource_Handle,
	tracks_first_row: u64,
	window_first_row: u64,
	view_trace_generation: u64,
	view_query_generation: u64,
	last_interaction_sequence: u64,
	telemetry_sequence: u64,
	requested_trace: string,
	progress_message: string,
	waker: host.Application_Waker,
	bridge_thread: ^thread.Thread,
	bridge_stop: u32,
	bridge_sequence: u64,
	dialogs: host.Dialog_Service,
	build_count: u64,
	wake_count: u64,
	resource_copy_count: u64,
	error: string,
}

scope_app_new :: proc(backend: Scope_Backend_API, trace_path: string) -> ^Scope_App {
	app := new(Scope_App)
	app.backend = backend
	app.tracks = make([dynamic]frontend.Scope_Track, 0, 256)
	app.events = make([dynamic]frontend.Scope_Event_Row, 0, SCOPE_EVENT_WINDOW_ROWS)
	app.arguments = make([dynamic]frontend.Scope_Argument, 0, 32)
	app.state_bytes = make([]byte, SCOPE_RESOURCE_LIMIT)
	app.resource_scratch = make([]byte, SCOPE_RESOURCE_LIMIT)
	app.requested_trace, _ = strings.clone(trace_path)
	app.view.load_status = .Empty
	return app
}

scope_state_destroy :: proc(state: ^Scope_Published_State) {
	if state == nil { return }
	if len(state.status) > 0 { delete(state.status) }
	if len(state.path) > 0 { delete(state.path) }
	if len(state.message) > 0 { delete(state.message) }
	if len(state.selected_event.name) > 0 { delete(state.selected_event.name) }
	if len(state.selected_event.category) > 0 { delete(state.selected_event.category) }
	for &argument in state.selected_event.arguments {
		if len(argument.name) > 0 { delete(argument.name) }
		if len(argument.value) > 0 { delete(argument.value) }
	}
	if len(state.selected_event.arguments) > 0 { delete(state.selected_event.arguments) }
	state^ = {}
}

scope_release_rows :: proc(app: ^Scope_App) {
	for &track in app.tracks {
		if len(track.name) > 0 { delete(track.name) }
	}
	for &event in app.events {
		if len(event.category) > 0 { delete(event.category) }
		if len(event.name) > 0 { delete(event.name) }
	}
	clear(&app.tracks)
	clear(&app.events)
	app.view.tracks = app.tracks[:]
	app.view.events = app.events[:]
}

scope_app_destroy :: proc(app: ^Scope_App) {
	if app == nil { return }
	scope_release_rows(app)
	delete(app.tracks)
	delete(app.events)
	delete(app.arguments)
	scope_state_destroy(&app.state)
	if app.view.ui.filter_owned && len(app.view.filter) > 0 { delete(app.view.filter) }
	if len(app.requested_trace) > 0 { delete(app.requested_trace) }
	if len(app.error) > 0 { delete(app.error) }
	if len(app.progress_message) > 0 { delete(app.progress_message) }
	if len(app.view.trace_summary) > 0 { delete(app.view.trace_summary) }
	delete(app.state_bytes)
	delete(app.resource_scratch)
	free(app)
}

scope_read_state :: proc(app: ^Scope_App) -> bool {
	length: uintptr
	revision: u64
	schema: u32
	status := app.backend.read_state(raw_data(app.state_bytes), uintptr(len(app.state_bytes)), &length, &revision, &schema)
	if status != Caliber_Status_OK || length == 0 || length > uintptr(len(app.state_bytes)) {
		return false
	}
	if revision == app.state_revision { return false }
	next: Scope_Published_State
	if json.unmarshal(app.state_bytes[:int(length)], &next, allocator=context.allocator) != nil {
		scope_state_destroy(&next)
		app.error = "Caliber state had an invalid JSON payload"
		return false
	}
	if next.schema != schema || next.schema != 1 {
		scope_state_destroy(&next)
		app.error = "Unsupported Scope state schema"
		return false
	}
	old_trace_generation := app.state.trace_generation
	old_query_generation := app.state.query_generation
	scope_state_destroy(&app.state)
	app.state = next
	app.state_revision = revision
	app.view.trace_path = app.state.path
	app.view.trace_track_count = int(app.state.track_count)
	app.view.track_total_count = int(app.state.track_count)
	app.view.event_total_count = int(app.state.matching_events)
	app.view.load_status = .Empty
	switch app.state.status {
	case "loading": app.view.load_status = .Loading
	case "ready": app.view.load_status = .Ready
	case "failed": app.view.load_status = .Failed
	}
	app.view.load_message = app.state.message
	app.view_trace_generation = app.state.trace_generation
	app.view_query_generation = app.state.query_generation
	app.view.selected_event = frontend.Scope_Event_Detail{
		available=app.state.selected_event.available,
		id=app.state.selected_event.id,
		timestamp_us=app.state.selected_event.timestamp_us,
		duration_us=app.state.selected_event.duration_us,
		name=app.state.selected_event.name,
		category=app.state.selected_event.category,
	}
	app.view.ui.has_selected_event = app.state.selected_event.available
	app.view.ui.selected_event_id = app.state.selected_event.id
	clear(&app.arguments)
	if old_trace_generation != app.state.trace_generation {
		scope_release_rows(app)
		app.track_resource = {}
		app.window_resource = {}
		app.loaded_track_resource = {}
		app.loaded_window_resource = {}
		app.tracks_first_row = 0
		app.window_first_row = 0
		app.view.track_first_row = 0
		app.view.event_first_row = 0
		app.view.ui.has_pending_track_window_request = false
		app.view.ui.has_pending_window_request = false
		app.view.ui.has_selected_track = false
		app.view.ui.selected_track_id = 0
		app.view.ui.has_selected_event = false
		app.view.ui.selected_event_id = 0
	}
	if old_query_generation != app.state.query_generation && old_trace_generation == app.state.trace_generation {
		scope_release_rows(app)
		scope_release_events(app)
		app.track_resource = {}
		app.window_resource = {}
		app.loaded_track_resource = {}
		app.loaded_window_resource = {}
		app.view.track_first_row = 0
		app.view.event_first_row = 0
		app.view.ui.has_pending_track_window_request = false
		app.view.ui.has_pending_window_request = false
	}
	if app.view.ui.has_selected_event {
		for source, i in app.state.selected_event.arguments {
			append(&app.arguments, frontend.Scope_Argument{id=source.id, name=source.name, value=source.value})
		}
		app.view.selected_event.arguments = app.arguments[:]
		app.view.selected_event.arguments_truncated = app.state.selected_event.arguments_truncated
		app.view.selected_event.arguments_original_bytes = app.state.selected_event.arguments_original_bytes
	} else {
		app.view.selected_event.arguments = app.arguments[:0]
		app.view.selected_event.arguments_truncated = false
		app.view.selected_event.arguments_original_bytes = 0
	}
	app.track_resource = app.state.tracks_resource
	app.window_resource = app.state.window_resource
	app.tracks_first_row = app.state.tracks_first_row
	app.view.track_first_row = int(app.state.tracks_first_row)
	app.window_first_row = app.state.window_first_row
	if len(app.view.trace_summary) > 0 { delete(app.view.trace_summary) }
	app.view.trace_summary, _ = strings.clone(fmt.tprintf("%d tracks  ·  %d events  ·  %d unsupported phases", app.state.track_count, app.state.total_events, app.state.unsupported_phases))
	return true
}

scope_release_events :: proc(app: ^Scope_App) {
	for &event in app.events {
		if len(event.category) > 0 { delete(event.category) }
		if len(event.name) > 0 { delete(event.name) }
	}
	clear(&app.events)
	app.view.events = app.events[:]
	app.view.event_first_row = 0
}

scope_wire_u16 :: proc(data: []byte, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset+1])<<8
}

scope_wire_u32 :: proc(data: []byte, offset: int) -> u32 {
	return u32(data[offset]) | u32(data[offset+1])<<8 | u32(data[offset+2])<<16 | u32(data[offset+3])<<24
}

scope_wire_u64 :: proc(data: []byte, offset: int) -> u64 {
	return u64(scope_wire_u32(data, offset)) | u64(scope_wire_u32(data, offset+4))<<32
}

scope_wire_string :: proc(data: []byte, strings_offset, strings_bytes, offset, byte_count: u32) -> (string, bool) {
	if offset > strings_bytes || byte_count > strings_bytes-offset { return "", false }
	start := int(strings_offset+offset)
	end := start + int(byte_count)
	if start < 0 || end < start || end > len(data) { return "", false }
	copy, err := strings.clone(string(data[start:end]), allocator=context.allocator)
	return copy, err == nil
}

scope_copy_resource :: proc(app: ^Scope_App, handle: Scope_Resource_Handle) -> (data: []byte, ok: bool) {
	if handle.id == 0 { return nil, false }
	length: uintptr
	status := app.backend.read_resource(handle.id, handle.generation, raw_data(app.resource_scratch), uintptr(len(app.resource_scratch)), &length)
	if status != Caliber_Status_OK || length > uintptr(len(app.resource_scratch)) { return nil, false }
	app.resource_copy_count += 1
	return app.resource_scratch[:int(length)], true
}

scope_decode_tracks :: proc(app: ^Scope_App) -> bool {
	if app.track_resource.id == 0 { return false }
	data, ok := scope_copy_resource(app, app.track_resource)
	if !ok || len(data) < 64 || string(data[:4]) != "SCTR" || scope_wire_u16(data, 4) != 1 || scope_wire_u16(data, 6) != 64 { return false }
	if scope_wire_u64(data, 8) != app.state.trace_generation || scope_wire_u64(data, 16) != app.state.query_generation { return false }
	if scope_wire_u32(data, 60) != 0 { return false }
	first_row := scope_wire_u64(data, 24)
	total_count := scope_wire_u64(data, 32)
	row_count := scope_wire_u32(data, 40)
	row_bytes := scope_wire_u32(data, 44)
	rows_offset := scope_wire_u32(data, 48)
	strings_offset := scope_wire_u32(data, 52)
	strings_bytes := scope_wire_u32(data, 56)
	if first_row != app.state.tracks_first_row || total_count != app.state.track_count || first_row > total_count || u64(row_count) > total_count-first_row || row_count > SCOPE_EVENT_WINDOW_ROWS || row_bytes != 64 || rows_offset != 64 { return false }
	rows_end := u64(rows_offset) + u64(row_count)*u64(row_bytes)
	if rows_end != u64(strings_offset) || u64(strings_offset)+u64(strings_bytes) != u64(len(data)) { return false }
	decoded := make([dynamic]frontend.Scope_Track, 0, int(row_count))
	for row_index in 0..<int(row_count) {
		base := int(rows_offset)+row_index*64
		track_id := scope_wire_u64(data, base)
		pid := transmute(i64)scope_wire_u64(data, base+8)
		tid := transmute(i64)scope_wire_u64(data, base+16)
		process_offset := scope_wire_u32(data, base+40)
		process_length := scope_wire_u32(data, base+44)
		thread_offset := scope_wire_u32(data, base+48)
		thread_length := scope_wire_u32(data, base+52)
		flags := scope_wire_u32(data, base+56)
		if (flags & 0xffff_ff00) != 0 || scope_wire_u32(data, base+60) != 0 {
			for &track in decoded { if len(track.name) > 0 { delete(track.name) } }
			delete(decoded)
			return false
		}
		process_name, process_ok := scope_wire_string(data, strings_offset, strings_bytes, process_offset, process_length)
		thread_name, thread_ok := scope_wire_string(data, strings_offset, strings_bytes, thread_offset, thread_length)
		if !process_ok || !thread_ok {
			if process_ok && len(process_name) > 0 { delete(process_name) }
			if thread_ok && len(thread_name) > 0 { delete(thread_name) }
			for &track in decoded { if len(track.name) > 0 { delete(track.name) } }
			delete(decoded)
			return false
		}
		label := fmt.tprintf("%s / %s  (%d:%d)", process_name, thread_name, pid, tid)
		if process_name == "" { label = fmt.tprintf("Process %d  ·  Thread %d", pid, tid) }
		if thread_name == "" && process_name != "" { label = fmt.tprintf("%s  ·  Thread %d", process_name, tid) }
		owned_label, clone_err := strings.clone(label, allocator=context.allocator)
		if len(process_name) > 0 { delete(process_name) }
		if len(thread_name) > 0 { delete(thread_name) }
		if clone_err != nil {
			for &track in decoded { if len(track.name) > 0 { delete(track.name) } }
			delete(decoded)
			return false
		}
		append(&decoded, frontend.Scope_Track{id=track_id, name=owned_label, enabled=(flags&(1<<7)) != 0})
	}
	scope_release_rows(app)
	for track in decoded { append(&app.tracks, track) }
	for &track in decoded { track.name = "" }
	delete(decoded)
	app.view.tracks = app.tracks[:]
	app.tracks_first_row = first_row
	app.view.track_first_row = int(first_row)
	app.view.track_total_count = int(total_count)
	return true
}

scope_decode_events :: proc(app: ^Scope_App) -> bool {
	if app.window_resource.id == 0 { return false }
	data, ok := scope_copy_resource(app, app.window_resource)
	if !ok || len(data) < 64 || string(data[:4]) != "SCEV" || scope_wire_u16(data, 4) != 1 || scope_wire_u16(data, 6) != 64 { return false }
	if scope_wire_u64(data, 8) != app.state.trace_generation || scope_wire_u64(data, 16) != app.state.query_generation { return false }
	if scope_wire_u32(data, 60) != 0 { return false }
	first_row := scope_wire_u64(data, 24)
	total_count := scope_wire_u64(data, 32)
	row_count := scope_wire_u32(data, 40)
	row_bytes := scope_wire_u32(data, 44)
	rows_offset := scope_wire_u32(data, 48)
	strings_offset := scope_wire_u32(data, 52)
	strings_bytes := scope_wire_u32(data, 56)
	if first_row != app.state.window_first_row || total_count != app.state.matching_events || row_count > SCOPE_EVENT_WINDOW_ROWS || row_bytes != 56 || rows_offset != 64 { return false }
	rows_end := u64(rows_offset) + u64(row_count)*u64(row_bytes)
	if rows_end != u64(strings_offset) || u64(strings_offset)+u64(strings_bytes) != u64(len(data)) || first_row > total_count || u64(row_count) > total_count-first_row { return false }
	decoded := make([dynamic]frontend.Scope_Event_Row, 0, int(row_count))
	for row_index in 0..<int(row_count) {
		base := int(rows_offset)+row_index*56
		event_id := scope_wire_u64(data, base)
		timestamp := transmute(f64)scope_wire_u64(data, base+16)
		duration := transmute(f64)scope_wire_u64(data, base+24)
		flags := scope_wire_u32(data, base+32)
		kind := flags & 3
		if (kind != 1 && kind != 2) || (flags & 0xffff_fff8) != 0 || scope_wire_u32(data, base+52) != 0 {
			for &event in decoded {
				if len(event.category) > 0 { delete(event.category) }
				if len(event.name) > 0 { delete(event.name) }
			}
			delete(decoded)
			return false
		}
		category_offset := scope_wire_u32(data, base+44)
		category_length := scope_wire_u32(data, base+48)
		name_offset := scope_wire_u32(data, base+36)
		name_length := scope_wire_u32(data, base+40)
		category, category_ok := scope_wire_string(data, strings_offset, strings_bytes, category_offset, category_length)
		name, name_ok := scope_wire_string(data, strings_offset, strings_bytes, name_offset, name_length)
		if !category_ok || !name_ok {
			if category_ok && len(category) > 0 { delete(category) }
			if name_ok && len(name) > 0 { delete(name) }
			for &event in decoded {
				if len(event.category) > 0 { delete(event.category) }
				if len(event.name) > 0 { delete(event.name) }
			}
			delete(decoded)
			return false
		}
		append(&decoded, frontend.Scope_Event_Row{id=event_id, timestamp_us=timestamp, duration_us=duration, category=category, name=name})
	}
	scope_release_events(app)
	for event in decoded { append(&app.events, event) }
	for &event in decoded { event.category = ""; event.name = "" }
	delete(decoded)
	app.window_first_row = first_row
	app.view.event_first_row = int(first_row)
	app.view.event_total_count = int(total_count)
	app.view.events = app.events[:]
	return true
}

scope_refresh_view :: proc(app: ^Scope_App) -> bool {
	if !scope_read_state(app) { return false }
	changed := true
	if app.track_resource.id != 0 && (app.track_resource.id != app.loaded_track_resource.id || app.track_resource.generation != app.loaded_track_resource.generation || app.tracks_first_row != u64(app.view.track_first_row)) {
		if scope_decode_tracks(app) {
			app.loaded_track_resource = app.track_resource
			frontend.scope_ack_cached_tracks(&app.view)
			changed = true
		}
	}
	if app.window_resource.id != 0 && (app.window_resource.id != app.loaded_window_resource.id || app.window_resource.generation != app.loaded_window_resource.generation || app.window_first_row != u64(app.view.event_first_row)) {
		if scope_decode_events(app) {
			app.loaded_window_resource = app.window_resource
			frontend.scope_ack_cached_window(&app.view)
			changed = true
		}
	}
	return changed
}

scope_bridge_proc :: proc(data: rawptr) {
	app := cast(^Scope_App)data
	sequence := app.bridge_sequence
	for sync.atomic_load_explicit(&app.bridge_stop, .Acquire) == 0 {
		following: u64
		status := app.backend.wait_wake(sequence, &following)
		if status == Caliber_Status_Stopped || sync.atomic_load_explicit(&app.bridge_stop, .Acquire) != 0 { break }
		if status != Caliber_Status_OK { break }
		if following != sequence {
			sequence = following
			if sync.atomic_load_explicit(&app.bridge_stop, .Acquire) == 0 {
				host.application_wake(app.waker)
			}
		}
	}
}

scope_open_trace :: proc(app: ^Scope_App, path: string) -> bool {
	if len(path) == 0 { return false }
	path_ptr := strings.unsafe_string_to_cstring(path)
	status := app.backend.open_trace(path_ptr, uintptr(len(path)))
	return status == Caliber_Status_OK
}

scope_open_trace_dialog :: proc(app: ^Scope_App, rt: ^alicorn.Runtime) {
	filters := []host.Dialog_Filter{{name="Chrome Trace Event JSON", pattern="*.json"}}
	request := host.File_Dialog_Request{
		id=host.Dialog_ID(1),
		kind=.Open_File,
		title="Open Chrome Trace Event JSON",
		initial_location="",
		filters=filters,
		allow_many=false,
		accept_label="Open",
		cancel_label="Cancel",
	}
	if !host.ShowFileDialog(app.dialogs, request) {
		app.error = "Trace dialog is busy or unavailable"
		alicorn.invalidate_root(rt, "scope trace dialog unavailable")
	}
}

scope_consume_interaction :: proc(app: ^Scope_App, rt: ^alicorn.Runtime) {
	interaction := app.view.interaction
	if interaction.sequence == 0 || interaction.sequence == app.last_interaction_sequence { return }
	app.last_interaction_sequence = interaction.sequence
	#partial switch interaction.kind {
	case .Open_Trace:
		scope_open_trace_dialog(app, rt)
	case .Filter_Changed:
		filter_ptr := strings.unsafe_string_to_cstring(app.view.filter)
		_ = app.backend.set_filter(filter_ptr, uintptr(len(app.view.filter)))
	case .Track_Toggled:
		enabled := i32(0)
		if interaction.enabled { enabled = 1 }
		_ = app.backend.set_track_enabled(app.state.trace_generation, interaction.track_id, enabled)
	case .Track_Window_Requested:
		first := u64(max(0, interaction.first_row))
		aligned := (first/u64(SCOPE_EVENT_WINDOW_ROWS))*u64(SCOPE_EVENT_WINDOW_ROWS)
		_ = app.backend.request_tracks(app.state.trace_generation, app.state.query_generation, aligned, SCOPE_EVENT_WINDOW_ROWS)
	case .Event_Selected:
		_ = app.backend.select_event(app.state.trace_generation, interaction.event_id)
	case .Window_Requested:
		first := u64(max(0, interaction.first_row))
		aligned := (first/u64(SCOPE_EVENT_WINDOW_ROWS))*u64(SCOPE_EVENT_WINDOW_ROWS)
		_ = app.backend.request_window(app.state.trace_generation, app.state.query_generation, aligned, SCOPE_EVENT_WINDOW_ROWS)
	}
	frontend.scope_clear_interaction(&app.view)
}

scope_build :: proc(state: rawptr, rt: ^alicorn.Runtime, logical_width, logical_height: int, dpi_scale: f32) -> alicorn.Node_ID {
	app := cast(^Scope_App)state
	app.build_count += 1
	root := frontend.scope_render(&app.view, rt)
	scope_consume_interaction(app, rt)
	return root
}

scope_on_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^Scope_App)state
	frontend.scope_on_text_change(&app.view, rt, change)
}

scope_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	app := cast(^Scope_App)state
	if app.view.ui.filter_node != 0 && rt.focused == app.view.ui.filter_node { return false }
	#partial switch key {
	case .Up:        return frontend.scope_on_navigation_key(&app.view, rt, .Up)
	case .Down:      return frontend.scope_on_navigation_key(&app.view, rt, .Down)
	case .Page_Up:   return frontend.scope_on_navigation_key(&app.view, rt, .Page_Up)
	case .Page_Down: return frontend.scope_on_navigation_key(&app.view, rt, .Page_Down)
	}
	return false
}

scope_on_start :: proc(state: rawptr, waker: host.Application_Waker) {
	app := cast(^Scope_App)state
	app.waker = waker
	if app.backend.wake_sequence(&app.bridge_sequence) != Caliber_Status_OK {
		app.view.load_status = .Failed
		app.view.load_message = "Caliber wake sequence could not be read"
		return
	}
	sync.atomic_store_explicit(&app.bridge_stop, 0, .Release)
	app.bridge_thread = thread.create_and_start_with_data(rawptr(app), scope_bridge_proc, name="alicorn-scope-caliber-wake")
	if app.bridge_thread == nil {
		app.view.load_status = .Failed
		app.view.load_message = "Caliber wake bridge thread could not start"
		return
	}
	if len(app.requested_trace) > 0 && !scope_open_trace(app, app.requested_trace) {
		app.view.load_status = .Failed
		app.view.load_message = "Could not submit trace load request"
	}
}

scope_on_services :: proc(state: rawptr, services: host.Application_Services) {
	app := cast(^Scope_App)state
	app.dialogs = services.dialogs
}

scope_on_dialog :: proc(state: rawptr, rt: ^alicorn.Runtime, result: ^host.File_Dialog_Result) {
	app := cast(^Scope_App)state
	if result == nil || result.status != .Accepted || len(result.paths) == 0 { return }
	if !scope_open_trace(app, result.paths[0]) {
		app.view.load_status = .Failed
		app.view.load_message = "Could not submit trace load request"
		alicorn.invalidate_root(rt, "scope trace request rejected")
	}
}

scope_on_wake :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Scope_App)state
	app.wake_count += 1
	state_changed := scope_refresh_view(app)
	telemetry_changed := scope_refresh_telemetry(app)
	if state_changed || telemetry_changed {
		alicorn.invalidate_root(rt, "Caliber published Scope state or bounded resource")
	}
}

scope_refresh_telemetry :: proc(app: ^Scope_App) -> bool {
	values: [8]uintptr
	count: uintptr
	sequence: u64
	status := app.backend.read_telemetry(&values[0], uintptr(len(values)), &count, &sequence)
	if status != Caliber_Status_OK || count < 5 || sequence == app.telemetry_sequence { return false }
	app.telemetry_sequence = sequence
	if app.view.load_status != .Loading || u64(values[0]) != 1 { return false }
	completed := u64(values[1])
	total := u64(values[2])
	message := "Loading trace..."
	if total > 0 {
		percentage := min(100.0, f64(completed)*100.0/f64(total))
		message = fmt.tprintf("Loading trace... %.0f%%", percentage)
	}
	copy, err := strings.clone(message, allocator=context.allocator)
	if err != nil { return false }
	if len(app.progress_message) > 0 { delete(app.progress_message) }
	app.progress_message = copy
	app.view.load_message = app.progress_message
	return true
}

scope_on_stop :: proc(state: rawptr) {
	app := cast(^Scope_App)state
	if !app.backend_created { return }
	_ = app.backend.stop_work()
	_ = app.backend.stop_waiters()
	sync.atomic_store_explicit(&app.bridge_stop, 1, .Release)
	if app.bridge_thread != nil {
		thread.join(app.bridge_thread)
		thread.destroy(app.bridge_thread)
		app.bridge_thread = nil
	}
	app.backend.destroy()
	app.backend_created = false
}

scope_open_backend :: proc(path: string) -> (api: Scope_Backend_API, ok: bool) {
	count, initialized := dynlib.initialize_symbols(&api, path, "", "_library")
	if !initialized || count < 15 {
		if api._library != nil { _ = dynlib.unload_library(api._library) }
		return {}, false
	}
	return api, true
}

scope_backend_library_name :: proc() -> string {
	when ODIN_OS == .Windows { return "scope_backend."+dynlib.LIBRARY_FILE_EXTENSION }
	else { return "libscope_backend."+dynlib.LIBRARY_FILE_EXTENSION }
}

scope_caliber_library_name :: proc() -> string {
	when ODIN_OS == .Windows { return "caliber_ffi."+dynlib.LIBRARY_FILE_EXTENSION }
	when ODIN_OS == .Darwin  { return "libcaliber_ffi.dylib" }
	else { return "libcaliber_ffi."+dynlib.LIBRARY_FILE_EXTENSION }
}

scope_adjacent_path :: proc(executable, name: string) -> string {
	directory := filepath.dir(executable)
	if len(directory) == 0 { return name }
	joined, err := filepath.join([]string{directory, name}, allocator=context.temp_allocator)
	if err != nil { return name }
	return joined
}

scope_load_frontend_resources :: proc(app: ^Scope_App) {
	if app.track_resource.id != 0 && (app.track_resource.id != app.loaded_track_resource.id || app.track_resource.generation != app.loaded_track_resource.generation || app.tracks_first_row != u64(app.view.track_first_row)) {
		if scope_decode_tracks(app) {
			app.loaded_track_resource = app.track_resource
			frontend.scope_ack_cached_tracks(&app.view)
		}
	}
	if app.window_resource.id != 0 && (app.window_resource.id != app.loaded_window_resource.id || app.window_resource.generation != app.loaded_window_resource.generation) {
		if scope_decode_events(app) {
			app.loaded_window_resource = app.window_resource
			frontend.scope_ack_cached_window(&app.view)
		}
	}
}

scope_open_trace_if_loaded :: proc(app: ^Scope_App) {
	if app.state.status == "ready" && app.track_resource.id != 0 { scope_load_frontend_resources(app) }
}

scope_app_startup_sync :: proc(app: ^Scope_App) {
	if scope_read_state(app) {
		app.track_resource = app.state.tracks_resource
		app.window_resource = app.state.window_resource
		app.tracks_first_row = app.state.tracks_first_row
		app.window_first_row = app.state.window_first_row
		scope_open_trace_if_loaded(app)
	}
}

scope_app_run :: proc(app: ^Scope_App, smoke: bool) {
	application := host.Application{
		state=rawptr(app),
		title="Alicorn Scope",
		width=1440,
		height=900,
		build=scope_build,
		on_text_change=scope_on_text_change,
		on_key=scope_on_key,
		on_tick=nil,
		on_services=scope_on_services,
		on_start=scope_on_start,
		on_dialog=scope_on_dialog,
		on_wake=scope_on_wake,
		on_stop=scope_on_stop,
	}
	host.Run(application, smoke)
}
