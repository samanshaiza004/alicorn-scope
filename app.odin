package main

import "core:dynlib"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import math "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import utf8 "core:unicode/utf8"
import alicorn "alicorn:runtime"
import frontend "./frontend"
import host "alicorn:native/sdl_gpu"

SCOPE_RESOURCE_LIMIT :: 1 << 20
SCOPE_EVENT_WINDOW_ROWS :: 512
SCOPE_TIMELINE_DENSITY_BUCKETS :: 128

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
	request_timeline: proc "c" (trace_generation, query_generation, track_id: u64, start_us, end_us: f64, resolution: u32) -> i32 `dynlib:"Scope_RequestTimelineWindow"`,
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
	has_query_row: bool `json:"has_query_row"`,
	query_row: u64 `json:"query_row"`,
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
	trace_start_us: f64 `json:"trace_start_us"`,
	trace_end_us: f64 `json:"trace_end_us"`,
	tracks_resource: Scope_Resource_Handle `json:"tracks_resource"`,
	window_resource: Scope_Resource_Handle `json:"window_resource"`,
	timeline_resource: Scope_Resource_Handle `json:"timeline_resource"`,
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
	timeline_rows: [dynamic]frontend.Scope_Timeline_Row,
	arguments: [dynamic]frontend.Scope_Argument,
	state: Scope_Published_State,
	state_bytes: []byte,
	resource_scratch: []byte,
	state_revision: u64,
	track_resource: Scope_Resource_Handle,
	window_resource: Scope_Resource_Handle,
	loaded_track_resource: Scope_Resource_Handle,
	loaded_window_resource: Scope_Resource_Handle,
	timeline_resource: Scope_Resource_Handle,
	loaded_timeline_resource: Scope_Resource_Handle,
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
	timeline_pointer_events: u64,
	timeline_requests: u64,
	timeline_cache_hits: u64,
	timeline_resource_decodes: u64,
	timeline_geometry_updates: u64,
	error: string,
	dialog_error: string,
	dialog_error_owned: bool,
	file_menu_items: [1]host.Application_Menu_Item,
	view_menu_items: [3]host.Application_Menu_Item,
	navigate_menu_items: [5]host.Application_Menu_Item,
	menus: [3]host.Application_Menu,
	runtime_inspection: string,
	runtime_activity: [dynamic]frontend.Scope_Runtime_Activity,
	last_trace_sequence: u64,
	geometry_selected_event_id: u64,
}

scope_app_new :: proc(backend: Scope_Backend_API, trace_path: string) -> ^Scope_App {
	app := new(Scope_App)
	app.backend = backend
	app.tracks = make([dynamic]frontend.Scope_Track, 0, 256)
	app.events = make([dynamic]frontend.Scope_Event_Row, 0, SCOPE_EVENT_WINDOW_ROWS)
	app.timeline_rows = make([dynamic]frontend.Scope_Timeline_Row, 0, 512)
	app.arguments = make([dynamic]frontend.Scope_Argument, 0, 32)
	app.runtime_activity = make([dynamic]frontend.Scope_Runtime_Activity, 0, 64)
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
	delete(app.timeline_rows)
	delete(app.arguments)
	scope_state_destroy(&app.state)
	if app.view.ui.filter_owned && len(app.view.filter) > 0 { delete(app.view.filter) }
	if len(app.requested_trace) > 0 { delete(app.requested_trace) }
	if len(app.error) > 0 { delete(app.error) }
	if app.dialog_error_owned && len(app.dialog_error) > 0 { delete(app.dialog_error) }
	if len(app.progress_message) > 0 { delete(app.progress_message) }
	if len(app.view.trace_summary) > 0 { delete(app.view.trace_summary) }
	if len(app.view.ui.command_palette_query) > 0 && app.view.ui.command_palette_query_owned { delete(app.view.ui.command_palette_query) }
	if len(app.runtime_inspection) > 0 { delete(app.runtime_inspection) }
	for &activity in app.runtime_activity {
		if len(activity.text) > 0 { delete(activity.text) }
	}
	delete(app.runtime_activity)
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
	if next.schema != schema || next.schema != 2 {
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
	app.view.trace_start_us = app.state.trace_start_us
	app.view.trace_end_us = app.state.trace_end_us
	app.view.selected_event = frontend.Scope_Event_Detail{
		available=app.state.selected_event.available,
		id=app.state.selected_event.id,
		has_query_row=app.state.selected_event.has_query_row,
		query_row=int(app.state.selected_event.query_row),
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
		app.timeline_resource = {}
		app.loaded_timeline_resource = {}
		scope_release_timeline(app)
		app.view.timeline_start_us = app.state.trace_start_us
		app.view.timeline_end_us = app.state.trace_end_us
		if app.view.timeline_end_us <= app.view.timeline_start_us {
			app.view.timeline_end_us = app.view.timeline_start_us + 1
		}
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
		app.timeline_resource = {}
		app.loaded_timeline_resource = {}
		scope_release_timeline(app)
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
	app.timeline_resource = app.state.timeline_resource
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
	app.view.timeline_revision += 1
	if app.view.timeline_revision == 0 { app.view.timeline_revision = 1 }
	if !app.view.ui.has_selected_track {
		for track in app.tracks {
			if track.enabled {
				app.view.ui.has_selected_track = true
				app.view.ui.selected_track_id = track.id
				frontend.scope_publish_interaction(&app.view, .Track_Selected, track.id, 0)
				break
			}
		}
	}
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

scope_release_timeline :: proc(app: ^Scope_App) {
	clear(&app.timeline_rows)
	app.view.timeline_rows = app.timeline_rows[:]
	app.view.timeline_mode = .None
	app.view.timeline_total_events = 0
	app.view.timeline_ready = false
	app.view.timeline_cache_track_id = 0
	app.view.timeline_cache_trace_generation = 0
	app.view.timeline_cache_query_generation = 0
	app.view.timeline_cache_start_us = 0
	app.view.timeline_cache_end_us = 0
	app.view.timeline_request_pending = false
	app.view.timeline_revision += 1
	if app.view.timeline_revision == 0 { app.view.timeline_revision = 1 }
}

scope_decode_timeline :: proc(app: ^Scope_App) -> bool {
	if app.timeline_resource.id == 0 { return false }
	data, ok := scope_copy_resource(app, app.timeline_resource)
	if !ok || len(data) < 64 || string(data[:4]) != "SCTW" || scope_wire_u16(data, 4) != 1 || scope_wire_u16(data, 6) != 64 { return false }
	trace_generation := scope_wire_u64(data, 8)
	query_generation := scope_wire_u64(data, 16)
	mode := scope_wire_u32(data, 24)
	row_count := scope_wire_u32(data, 28)
	total_count := scope_wire_u64(data, 32)
	start_us := transmute(f64)scope_wire_u64(data, 40)
	end_us := transmute(f64)scope_wire_u64(data, 48)
	resource_track_id := scope_wire_u64(data, 56)
	rows_offset := u32(64)
	row_bytes := u32(40)
	if trace_generation != app.state.trace_generation || query_generation != app.state.query_generation ||
	   (mode != 1 && mode != 2) || row_count > 512 || (mode == 1 && row_count > 128) ||
	   (mode == 1 && total_count != u64(row_count)) || rows_offset != 64 || row_bytes != 40 ||
	   u64(rows_offset)+u64(row_count)*u64(row_bytes) != u64(len(data)) ||
		resource_track_id != app.view.timeline_request_track_id ||
	   start_us != start_us || end_us != end_us || end_us <= start_us {
		return false
	}
	decoded := make([dynamic]frontend.Scope_Timeline_Row, 0, int(row_count))
	for i in 0..<int(row_count) {
		base := int(rows_offset)+i*40
		row: frontend.Scope_Timeline_Row
		if mode == 1 {
			row.event_id = scope_wire_u64(data, base)
			row.track_id = scope_wire_u64(data, base+8)
			row.timestamp_us = transmute(f64)scope_wire_u64(data, base+16)
			row.duration_us = transmute(f64)scope_wire_u64(data, base+24)
			row.kind = scope_wire_u32(data, base+32)
			if row.track_id == 0 || row.timestamp_us != row.timestamp_us || row.duration_us != row.duration_us || row.duration_us < 0 ||
			   (row.kind != 1 && row.kind != 2) || scope_wire_u32(data, base+36) != 0 {
				delete(decoded)
				return false
			}
		} else {
			row.track_id = scope_wire_u64(data, base)
			row.bucket_start_us = transmute(f64)scope_wire_u64(data, base+8)
			row.bucket_end_us = transmute(f64)scope_wire_u64(data, base+16)
			row.event_count = scope_wire_u64(data, base+24)
			row.duration_sum_us = transmute(f64)scope_wire_u64(data, base+32)
			if row.track_id == 0 || row.bucket_start_us != row.bucket_start_us || row.bucket_end_us != row.bucket_end_us ||
			   row.duration_sum_us != row.duration_sum_us || row.bucket_end_us <= row.bucket_start_us || row.duration_sum_us < 0 {
				delete(decoded)
				return false
			}
		}
		if row.track_id == 0 || (app.view.timeline_request_track_id != 0 && row.track_id != app.view.timeline_request_track_id) {
			delete(decoded)
			return false
		}
		append(&decoded, row)
	}
	clear(&app.timeline_rows)
	for row in decoded { append(&app.timeline_rows, row) }
	delete(decoded)
	app.view.timeline_rows = app.timeline_rows[:]
	app.view.timeline_mode = .Raw if mode == 1 else .Aggregate
	app.view.timeline_total_events = total_count
	app.view.timeline_cache_start_us = start_us
	app.view.timeline_cache_end_us = end_us
	app.view.timeline_cache_track_id = app.view.timeline_request_track_id
	app.view.timeline_cache_trace_generation = trace_generation
	app.view.timeline_cache_query_generation = query_generation
	app.view.timeline_ready = true
	app.view.timeline_request_pending = false
	app.view.timeline_revision += 1
	if app.view.timeline_revision == 0 { app.view.timeline_revision = 1 }
	app.timeline_resource_decodes += 1
	return true
}

scope_request_timeline :: proc(app: ^Scope_App) -> bool {
	view := &app.view
	if app.state.status != "ready" || view.timeline_request_pending || view.timeline_end_us <= view.timeline_start_us {
		return false
	}
	requested_track_id: u64 = 0
	if view.ui.has_selected_track {
		requested_track_id = view.ui.selected_track_id
	}
	if view.timeline_ready && view.timeline_cache_track_id == requested_track_id &&
	   view.timeline_cache_trace_generation == app.state.trace_generation && view.timeline_cache_query_generation == app.state.query_generation &&
	   view.timeline_cache_start_us <= view.timeline_start_us && view.timeline_cache_end_us >= view.timeline_end_us {
		app.timeline_cache_hits += 1
		return false
	}
	span := view.timeline_end_us-view.timeline_start_us
	start_us := view.timeline_start_us-span*0.5
	end_us := view.timeline_end_us+span*0.5
	trace_span := view.trace_end_us-view.trace_start_us
	if trace_span <= 0 { trace_span = 1 }
	if start_us < view.trace_start_us { start_us = view.trace_start_us }
	if end_us > view.trace_end_us { end_us = view.trace_end_us }
	if end_us <= start_us {
		start_us = view.trace_start_us
		end_us = view.trace_end_us
		if end_us <= start_us { end_us = start_us+1 }
	}
	if end_us-start_us > trace_span*2 {
		start_us = view.trace_start_us
		end_us = view.trace_end_us
	}
	status := app.backend.request_timeline(app.state.trace_generation, app.state.query_generation, requested_track_id, start_us, end_us, 256)
	if status != Caliber_Status_OK {
		app.view.load_message = "Could not request timeline window"
		return false
	}
	view.timeline_request_pending = true
	view.timeline_request_track_id = requested_track_id
	view.timeline_request_start_us = start_us
	view.timeline_request_end_us = end_us
	app.timeline_requests += 1
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
	if app.timeline_resource.id != 0 && (app.timeline_resource.id != app.loaded_timeline_resource.id || app.timeline_resource.generation != app.loaded_timeline_resource.generation) {
		if scope_decode_timeline(app) {
			app.loaded_timeline_resource = app.timeline_resource
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
	// SDL file-dialog filters take extension tokens, not shell globs.
	filters := []host.Dialog_Filter{{name="Chrome Trace Event JSON", pattern="json"}}
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
		scope_report_dialog_error(app, rt, "Trace dialog is busy or unavailable")
	}
}

scope_update_native_menu_state :: proc(app: ^Scope_App) {
	app.view_menu_items[1].checked = app.view.ui.show_runtime_inspector
	app.view_menu_items[2].enabled = app.view.ui.has_selected_track
	app.navigate_menu_items[1].enabled = app.view.load_status == .Ready
	app.navigate_menu_items[2].enabled = app.view.ui.has_selected_event
	app.navigate_menu_items[3].enabled = app.view.event_total_count > 0
	app.navigate_menu_items[4].enabled = app.view.ui.has_selected_event
}

scope_configure_native_menus :: proc(app: ^Scope_App) {
	app.file_menu_items = {
		{kind=.Command, command=host.Application_Command_ID(u32(frontend.Scope_Command_ID.Open_Trace)), label="Open Trace...", enabled=true, shortcut=host.Application_Menu_Shortcut{'O', {.Primary}}},
	}
	app.view_menu_items = {
		{kind=.Command, command=host.Application_Command_ID(u32(frontend.Scope_Command_ID.Toggle_Command_Palette)), label="Command Palette...", enabled=true, shortcut=host.Application_Menu_Shortcut{'P', {.Primary, .Shift}}},
		{kind=.Command, command=host.Application_Command_ID(u32(frontend.Scope_Command_ID.Toggle_Runtime_Inspector)), label="Runtime Inspector", enabled=true},
		{kind=.Command, command=host.Application_Command_ID(u32(frontend.Scope_Command_ID.Show_Overview)), label="Show Overview", enabled=false},
	}
	app.navigate_menu_items = {
		{kind=.Command, command=host.Application_Command_ID(u32(frontend.Scope_Command_ID.Fit_Trace)), label="Fit Whole Trace", enabled=false},
		{kind=.Command, command=host.Application_Command_ID(u32(frontend.Scope_Command_ID.Fit_Selection)), label="Fit Selection", enabled=false},
		{kind=.Command, command=host.Application_Command_ID(u32(frontend.Scope_Command_ID.Previous_Event)), label="Previous Event", enabled=false},
		{kind=.Command, command=host.Application_Command_ID(u32(frontend.Scope_Command_ID.Next_Event)), label="Next Event", enabled=false},
		{kind=.Command, command=host.Application_Command_ID(u32(frontend.Scope_Command_ID.Clear_Selection)), label="Clear Event Selection", enabled=false},
	}
	app.menus = {
		{label="File", items=app.file_menu_items[:]},
		{label="View", items=app.view_menu_items[:]},
		{label="Navigate", items=app.navigate_menu_items[:]},
	}
	scope_update_native_menu_state(app)
}

scope_runtime_record :: proc(app: ^Scope_App, message: string) {
	copy, err := strings.clone(message, allocator=context.allocator)
	if err != nil { return }
	if len(app.runtime_activity) < 64 {
		append(&app.runtime_activity, frontend.Scope_Runtime_Activity{text=copy})
		return
	}
	if len(app.runtime_activity[0].text) > 0 { delete(app.runtime_activity[0].text) }
	for index := 1; index < len(app.runtime_activity); index += 1 {
		app.runtime_activity[index-1] = app.runtime_activity[index]
	}
	app.runtime_activity[len(app.runtime_activity)-1] = frontend.Scope_Runtime_Activity{text=copy}
}

scope_utf8_prefix_bytes :: proc(value: string, maximum: int) -> int {
	limit := min(len(value), maximum)
	index := 0
	for index < limit {
		_, width := utf8.decode_rune_in_string(value[index:])
		if width <= 0 || index+width > limit { break }
		index += width
	}
	return index
}

scope_capture_runtime_inspection :: proc(app: ^Scope_App, rt: ^alicorn.Runtime) {
	if !app.view.ui.show_runtime_inspector { return }
	events := alicorn.trace_snapshot(rt)
	defer delete(events)
	for event in events {
		if event.sequence <= app.last_trace_sequence { continue }
		if event.cause_id == 0 {
			scope_runtime_record(app, fmt.tprintf("%06d  %v  no cause  node=%d  %s", event.sequence, event.kind, event.node, event.reason))
		} else {
			scope_runtime_record(app, fmt.tprintf("%06d  %v  cause #%d · %v · command %d  node=%d  %s", event.sequence, event.kind, event.cause_id, event.cause_kind, event.command_id, event.node, event.reason))
		}
		app.last_trace_sequence = event.sequence
	}
	inspection := alicorn.inspect(rt)
	if len(inspection) > 24000 {
		bounded_length := scope_utf8_prefix_bytes(inspection, 24000)
		bounded, err := strings.clone(inspection[:bounded_length], allocator=context.allocator)
		delete(inspection)
		if err == nil {
			if len(app.runtime_inspection) > 0 { delete(app.runtime_inspection) }
			app.runtime_inspection = bounded
		}
	} else {
		if len(app.runtime_inspection) > 0 { delete(app.runtime_inspection) }
		app.runtime_inspection = inspection
	}
}

scope_dispatch_command :: proc(app: ^Scope_App, rt: ^alicorn.Runtime, command: frontend.Scope_Command_ID) -> bool {
	if command == .None || !frontend.scope_command_enabled(app.view, command) { return false }
	command_cause := alicorn.cause_begin(rt, .Application, "Scope semantic command", u32(command))
	scope_runtime_record(app, fmt.tprintf("Command · %s", frontend.scope_command_label(command)))
	alicorn.trace_command(rt, u32(command), frontend.scope_command_label(command))
	if app.view.ui.command_palette_open && command != .Toggle_Command_Palette {
		app.view.ui.command_palette_open = false
		app.view.ui.focus_restore_pending = true
	}
	changed := false
	#partial switch command {
	case .Open_Trace:
		scope_open_trace_dialog(app, rt)
		changed = true
	case .Show_Overview:
		changed = frontend.scope_show_overview(&app.view)
		if changed {
			_ = app.backend.select_event(app.state.trace_generation, 0)
			_ = scope_request_timeline(app)
		}
	case .Fit_Trace:
		changed = scope_timeline_set_range(app, app.view.trace_start_us, scope_timeline_effective_end(app.view))
		if changed {
			scope_refresh_timeline_geometry(app, rt)
			_ = scope_request_timeline(app)
		}
		changed = true
	case .Fit_Selection:
		if !app.view.ui.has_selected_event {
			alicorn.cause_end(rt, command_cause)
			return false
		}
		selected_start := app.view.selected_event.timestamp_us
		selected_duration := app.view.selected_event.duration_us
		if !app.view.selected_event.available || app.view.selected_event.id != app.view.ui.selected_event_id {
			for row in app.view.timeline_rows {
				if row.event_id == app.view.ui.selected_event_id && app.view.timeline_mode == .Raw {
					selected_start, selected_duration = row.timestamp_us, row.duration_us
					break
				}
			}
		}
		trace_span := scope_timeline_effective_end(app.view)-app.view.trace_start_us
		selection_span := max(selected_duration, trace_span/100_000)
		if selection_span <= 0 { selection_span = max(trace_span/1000, 0.000001) }
		if scope_timeline_set_range(app, selected_start-selection_span*2, selected_start+max(selected_duration, selection_span)*2) {
			scope_refresh_timeline_geometry(app, rt)
			_ = scope_request_timeline(app)
		}
		changed = true
	case .Previous_Event:
		changed = frontend.scope_on_navigation_key(&app.view, rt, .Up)
	case .Next_Event:
		changed = frontend.scope_on_navigation_key(&app.view, rt, .Down)
	case .Toggle_Runtime_Inspector:
		app.view.ui.show_runtime_inspector = !app.view.ui.show_runtime_inspector
		changed = true
	case .Toggle_Command_Palette:
		if app.view.ui.command_palette_open {
			app.view.ui.command_palette_open = false
			app.view.ui.focus_restore_pending = true
		} else {
			app.view.ui.focus_before_palette = rt.focused
			if app.view.ui.command_palette_query_owned && len(app.view.ui.command_palette_query) > 0 { delete(app.view.ui.command_palette_query) }
			app.view.ui.command_palette_query = ""
			app.view.ui.command_palette_query_owned = false
			app.view.ui.palette_selected_index = 0
			app.view.ui.command_palette_open = true
			app.view.ui.command_palette_focus_pending = true
		}
		changed = true
	case .Clear_Selection:
		app.view.ui.has_selected_event = false
		app.view.ui.selected_event_id = 0
		app.view.ui.has_selected_event_row = false
		app.view.ui.has_pending_navigation_row = false
		_ = app.backend.select_event(app.state.trace_generation, 0)
		changed = true
	}
	scope_update_native_menu_state(app)
	if changed {
		alicorn.trace_mutation(rt, "Scope state changed by semantic command")
		alicorn.invalidate_root(rt, "Scope semantic command dispatched")
	}
	alicorn.cause_end(rt, command_cause)
	return true
}

scope_on_menu_command :: proc(state: rawptr, rt: ^alicorn.Runtime, command: host.Application_Command_ID) {
	app := cast(^Scope_App)state
	_ = scope_dispatch_command(app, rt, frontend.Scope_Command_ID(u32(command)))
}

scope_report_dialog_error :: proc(app: ^Scope_App, rt: ^alicorn.Runtime, message: string) {
	if app.dialog_error_owned && len(app.dialog_error) > 0 {
		delete(app.dialog_error)
	}
	app.dialog_error = ""
	app.dialog_error_owned = false
	if len(message) > 0 {
		copy, err := strings.clone(message, allocator=context.allocator)
		if err == nil {
			app.dialog_error = copy
			app.dialog_error_owned = true
		}
	}
	if len(app.dialog_error) == 0 {
		app.dialog_error = "Native file dialog failed"
	}
	app.view.load_status = .Failed
	app.view.load_message = app.dialog_error
	alicorn.invalidate_root(rt, "scope native file dialog failed")
}

scope_consume_interaction :: proc(app: ^Scope_App, rt: ^alicorn.Runtime) {
	interaction := app.view.interaction
	if interaction.sequence == 0 || interaction.sequence == app.last_interaction_sequence { return }
	app.last_interaction_sequence = interaction.sequence
	#partial switch interaction.kind {
	case .Command_Invoked:
		_ = scope_dispatch_command(app, rt, interaction.command_id)
	case .Filter_Changed:
		alicorn.trace_mutation(rt, "Scope event filter changed")
		filter_ptr := strings.unsafe_string_to_cstring(app.view.filter)
		_ = app.backend.set_filter(filter_ptr, uintptr(len(app.view.filter)))
	case .Track_Toggled:
		alicorn.trace_mutation(rt, "Scope track enabled state changed")
		enabled := i32(0)
		if interaction.enabled { enabled = 1 }
		_ = app.backend.set_track_enabled(app.state.trace_generation, interaction.track_id, enabled)
	case .Track_Selected:
		alicorn.trace_mutation(rt, "Scope track selection changed")
		// Track focus clears the prior event selection in the frontend; keep
		// the backend's committed inspector state in sync as well.
		_ = app.backend.select_event(app.state.trace_generation, interaction.event_id)
		_ = scope_request_timeline(app)
	case .Track_Window_Requested:
		first := u64(max(0, interaction.first_row))
		aligned := (first/u64(SCOPE_EVENT_WINDOW_ROWS))*u64(SCOPE_EVENT_WINDOW_ROWS)
		_ = app.backend.request_tracks(app.state.trace_generation, app.state.query_generation, aligned, SCOPE_EVENT_WINDOW_ROWS)
	case .Event_Selected:
		alicorn.trace_mutation(rt, "Scope event selection committed")
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
	app.view.runtime_activity = app.runtime_activity[:]
	scope_capture_runtime_inspection(app, rt)
	app.view.runtime_activity = app.runtime_activity[:]
	scope_update_native_menu_state(app)
	root := frontend.scope_render(&app.view, rt)
	scope_consume_interaction(app, rt)
	scope_update_native_menu_state(app)
	if app.geometry_selected_event_id != app.view.ui.selected_event_id {
		app.geometry_selected_event_id = app.view.ui.selected_event_id
		scope_timeline_bump_revision(&app.view)
	}
	scope_refresh_timeline_geometry(app, rt)
	return root
}

scope_timeline_bump_revision :: proc(view: ^frontend.Scope_View) {
	view.timeline_revision += 1
	if view.timeline_revision == 0 { view.timeline_revision = 1 }
}

scope_timeline_effective_end :: proc(view: frontend.Scope_View) -> f64 {
	return view.trace_end_us if view.trace_end_us > view.trace_start_us else view.trace_start_us+1
}

scope_timeline_clamp_range :: proc(view: frontend.Scope_View, start_us, end_us: f64) -> (f64, f64) {
	start := start_us
	end := end_us
	trace_start := view.trace_start_us
	trace_end := scope_timeline_effective_end(view)
	trace_span := trace_end-trace_start
	span := end-start
	if span <= 0 { span = max(trace_span/1000, 0.000001) }
	if span >= trace_span { return trace_start, trace_end }
	if start < trace_start {
		end += trace_start-start
		start = trace_start
	}
	if end > trace_end {
		start -= end-trace_end
		end = trace_end
	}
	if start < trace_start { start = trace_start }
	if end > trace_end { end = trace_end }
	if end <= start { return trace_start, trace_end }
	return start, end
}

scope_timeline_set_range :: proc(app: ^Scope_App, start_us, end_us: f64) -> bool {
	next_start, next_end := scope_timeline_clamp_range(app.view, start_us, end_us)
	if next_start == app.view.timeline_start_us && next_end == app.view.timeline_end_us { return false }
	app.view.timeline_start_us = next_start
	app.view.timeline_end_us = next_end
	scope_timeline_bump_revision(&app.view)
	return true
}

scope_refresh_timeline_geometry :: proc(app: ^Scope_App, rt: ^alicorn.Runtime) {
	id := app.view.ui.timeline_surface_node
	ctx, ok := alicorn.gpu_surface_context(rt, id)
	if !ok || ctx.logical_bounds.w <= 0 || ctx.logical_bounds.h <= 0 { return }
	if ctx.logical_bounds.w != app.view.timeline_geometry_width || ctx.logical_bounds.h != app.view.timeline_geometry_height {
		app.view.timeline_geometry_width = ctx.logical_bounds.w
		app.view.timeline_geometry_height = ctx.logical_bounds.h
		scope_timeline_bump_revision(&app.view)
	}
	if app.view.timeline_geometry_revision == app.view.timeline_revision { return }
	segments := make([dynamic]alicorn.GPU_Surface_Line_Segment, 0, 512, allocator=context.temp_allocator)
	circles := make([dynamic]alicorn.GPU_Surface_Filled_Circle, 0, 32, allocator=context.temp_allocator)
	defer delete(segments)
	defer delete(circles)
	width, height := ctx.logical_bounds.w, ctx.logical_bounds.h
	span := app.view.timeline_end_us-app.view.timeline_start_us
	if span <= 0 { span = 1 }
	selected_color := alicorn.Color{0.96, 0.98, 1.0, 1}
	complete_color := alicorn.Color{0.18, 0.76, 0.96, 0.94}
	instant_color := alicorn.Color{0.98, 0.67, 0.24, 1}
	grid_color := alicorn.Color{0.16, 0.20, 0.28, 0.72}
	center_y := height*0.5
	// A restrained ruler grid gives both the overview and focused lane a clear
	// time axis without turning the plot into a charting framework.
	for tick := 0; tick <= 4; tick += 1 {
		x := width*f32(tick)/4
		append(&segments, alicorn.GPU_Surface_Line_Segment{start={x, 4}, end={x, height-4}, thickness=1, color=grid_color})
	}
	for lane := 1; lane <= 3; lane += 1 {
		y := height*f32(lane)/4
		append(&segments, alicorn.GPU_Surface_Line_Segment{start={4, y}, end={width-4, y}, thickness=1, color=grid_color})
	}
	if app.view.timeline_ready && app.view.timeline_mode == .Raw && app.view.ui.has_selected_track {
		for row in app.view.timeline_rows {
			if row.track_id != app.view.ui.selected_track_id { continue }
			if row.timestamp_us >= app.view.timeline_end_us || row.timestamp_us+row.duration_us < app.view.timeline_start_us { continue }
			y, found := frontend.scope_timeline_track_y(app.view, row.track_id, height)
			if !found { continue }
			x := f32((row.timestamp_us-app.view.timeline_start_us)/span)*width
			x = clamp(x, 0, width)
			color := complete_color
			if row.event_id == app.view.ui.selected_event_id { color = selected_color }
			if row.kind == 2 {
				append(&circles, alicorn.GPU_Surface_Filled_Circle{center={x, y}, radius=4, color=instant_color})
			} else {
				x_end := f32((row.timestamp_us+row.duration_us-app.view.timeline_start_us)/span)*width
				x_end = clamp(x_end, 0, width)
				if x_end-x < 1 { x_end = min(width, x+1) }
				if x_end > x {
					thickness := f32(5)
					if row.event_id == app.view.ui.selected_event_id { thickness = 7 }
					append(&segments, alicorn.GPU_Surface_Line_Segment{start={x, y}, end={x_end, y}, thickness=thickness, color=color})
				}
			}
		}
	} else if app.view.timeline_ready {
		// The unselected view is a single all-track density overview. Focused
		// aggregate mode passes through the same bins, but contains one track.
		// This keeps drawing bounded and avoids squeezing dozens of unrelated
		// lanes into a few pixels.
		bucket_counts: [SCOPE_TIMELINE_DENSITY_BUCKETS]f64
		bucket_duration_us: [SCOPE_TIMELINE_DENSITY_BUCKETS]f64
		bucket_width_us := span/f64(SCOPE_TIMELINE_DENSITY_BUCKETS)
		if app.view.timeline_mode == .Aggregate {
			for row in app.view.timeline_rows {
				visible_start := max(row.bucket_start_us, app.view.timeline_start_us)
				visible_end := min(row.bucket_end_us, app.view.timeline_end_us)
				if visible_end <= visible_start { continue }
				center_us := (visible_start+visible_end)*0.5
				index := int((center_us-app.view.timeline_start_us)/span*f64(SCOPE_TIMELINE_DENSITY_BUCKETS))
				index = clamp(index, 0, SCOPE_TIMELINE_DENSITY_BUCKETS-1)
				bucket_fraction := (visible_end-visible_start)/max(row.bucket_end_us-row.bucket_start_us, 0.000001)
				bucket_counts[index] += f64(row.event_count)*bucket_fraction
				bucket_duration_us[index] += row.duration_sum_us*bucket_fraction
			}
		} else {
			for row in app.view.timeline_rows {
				if row.timestamp_us >= app.view.timeline_end_us || row.timestamp_us+row.duration_us < app.view.timeline_start_us { continue }
				visible_timestamp := max(row.timestamp_us, app.view.timeline_start_us)
				index := int((visible_timestamp-app.view.timeline_start_us)/span*f64(SCOPE_TIMELINE_DENSITY_BUCKETS))
				index = clamp(index, 0, SCOPE_TIMELINE_DENSITY_BUCKETS-1)
				bucket_counts[index] += 1
				if row.kind != 1 || row.duration_us <= 0 { continue }
				overlap_start := max(row.timestamp_us, app.view.timeline_start_us)
				overlap_end := min(row.timestamp_us+row.duration_us, app.view.timeline_end_us)
				if overlap_end <= overlap_start { continue }
				first_bucket := int((overlap_start-app.view.timeline_start_us)/span*f64(SCOPE_TIMELINE_DENSITY_BUCKETS))
				last_bucket := int((overlap_end-app.view.timeline_start_us)/span*f64(SCOPE_TIMELINE_DENSITY_BUCKETS))
				first_bucket = clamp(first_bucket, 0, SCOPE_TIMELINE_DENSITY_BUCKETS-1)
				last_bucket = clamp(last_bucket, 0, SCOPE_TIMELINE_DENSITY_BUCKETS-1)
				for bucket := first_bucket; bucket <= last_bucket; bucket += 1 {
					bucket_start := app.view.timeline_start_us+f64(bucket)*bucket_width_us
					bucket_end := bucket_start+bucket_width_us
					bucket_duration_us[bucket] += max(0, min(overlap_end, bucket_end)-max(overlap_start, bucket_start))
				}
			}
		}
		peak_count: f64 = 1
		peak_duration_sum: f64 = 0
		for bucket in 0..<SCOPE_TIMELINE_DENSITY_BUCKETS {
			peak_count = max(peak_count, bucket_counts[bucket])
			peak_duration_sum = max(peak_duration_sum, bucket_duration_us[bucket])
		}
		bucket_width_px := width/f32(SCOPE_TIMELINE_DENSITY_BUCKETS)
		bar_thickness := clamp(bucket_width_px*0.78, 2.5, 6)
		for bucket in 0..<SCOPE_TIMELINE_DENSITY_BUCKETS {
			count := bucket_counts[bucket]
			duration_sum := bucket_duration_us[bucket]
			if count <= 0 && duration_sum <= 0 { continue }
			// Density, not accumulated nested duration, controls bar height.
			// A square-root scale keeps busy buckets prominent without making
			// every bin look saturated when many tracks are enabled.
			count_level := math.sqrt(count/peak_count)
			bar_height := max(3, f32(0.12+0.88*count_level)*height*0.78)
			x := (f32(bucket)+0.5)*bucket_width_px
			// Duration is only a relative tint cue: nested slices can overlap, so
			// their sum is not physical track occupancy.
			duration_level: f64 = 0
			if peak_duration_sum > 0 { duration_level = math.sqrt(duration_sum/peak_duration_sum) }
			alpha := f32(0.60+0.30*duration_level)
			color := alicorn.Color{complete_color.r, complete_color.g, complete_color.b, alpha}
			baseline_y := height-5
			append(&segments, alicorn.GPU_Surface_Line_Segment{
				start={x, baseline_y}, end={x, max(4, baseline_y-bar_height)},
				thickness=bar_thickness,
				color=color,
			})
		}
	}
	// Give a selected raw event both a lane marker and a vertical cursor. Only
	// draw this when its stable ID is present in the focused raw window.
	if app.view.ui.has_selected_track && app.view.timeline_ready && app.view.timeline_mode == .Raw {
		for row in app.view.timeline_rows {
			if row.event_id != app.view.ui.selected_event_id { continue }
			x := f32((row.timestamp_us-app.view.timeline_start_us)/span)*width
			if x >= 0 && x <= width {
				append(&segments, alicorn.GPU_Surface_Line_Segment{start={x, 7}, end={x, height-7}, thickness=1.5, color=alicorn.Color{0.96, 0.98, 1.0, 0.48}})
				append(&circles, alicorn.GPU_Surface_Filled_Circle{center={x, center_y}, radius=5.2, color=selected_color})
			}
			break
		}
	}
	if alicorn.gpu_surface_update_geometry(rt, id, app.view.timeline_revision, segments[:], circles[:]) {
		app.view.timeline_geometry_revision = app.view.timeline_revision
		app.timeline_geometry_updates += 1
	}
}

scope_timeline_hit_test :: proc(view: frontend.Scope_View, x, y, width, height: f32) -> (event_id: u64, found: bool) {
	if !view.ui.has_selected_track || !view.timeline_ready || view.timeline_mode != .Raw || width <= 0 || height <= 0 { return 0, false }
	span := view.timeline_end_us-view.timeline_start_us
	if span <= 0 { return 0, false }
	best_score := f32(10*10)
	for row in view.timeline_rows {
		if row.track_id != view.ui.selected_track_id || row.timestamp_us >= view.timeline_end_us || row.timestamp_us+row.duration_us < view.timeline_start_us { continue }
		center_y, found := frontend.scope_timeline_track_y(view, row.track_id, height)
		if !found { continue }
		start_x := clamp(f32((row.timestamp_us-view.timeline_start_us)/span)*width, 0, width)
		end_x := start_x
		if row.kind == 1 {
			end_x = clamp(f32((row.timestamp_us+row.duration_us-view.timeline_start_us)/span)*width, 0, width)
			if end_x-start_x < 1 { end_x = min(width, start_x+1) }
		}
		nearest_x := clamp(x, start_x, end_x)
		dx, dy := x-nearest_x, y-center_y
		distance_squared := dx*dx+dy*dy
		if distance_squared <= best_score {
			best_score, event_id, found = distance_squared, row.event_id, true
		}
	}
	return
}

scope_on_pointer :: proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) {
	app := cast(^Scope_App)state
	view := &app.view
	if view.ui.command_palette_open {
		if event.kind == .Down && event.button == 1 && target == view.ui.command_palette_overlay_node {
			panel, panel_ok := rt.nodes[view.ui.command_palette_panel_node]
			inside_panel := panel_ok && event.x >= panel.bounds.x && event.x < panel.bounds.x+panel.bounds.w &&
				event.y >= panel.bounds.y && event.y < panel.bounds.y+panel.bounds.h
			if !inside_panel { _ = scope_dispatch_command(app, rt, .Toggle_Command_Palette) }
		}
		view.timeline_drag_active = false
		return
	}
	id := view.ui.timeline_surface_node
	if target == id || view.timeline_drag_active { app.timeline_pointer_events += 1 }
	if event.kind == .Cancel || (event.kind == .Down && target != id) {
		view.timeline_drag_active = false
		return
	}
	ctx, ok := alicorn.gpu_surface_context(rt, id)
	if !ok { view.timeline_drag_active = false; return }
	if event.kind == .Down && event.button == 1 && target == id {
		view.timeline_drag_active = true
		view.timeline_drag_moved = false
		view.timeline_drag_start_x = event.x
		view.timeline_drag_start_time = view.timeline_start_us
		view.timeline_drag_start_end = view.timeline_end_us
		return
	}
	if event.kind == .Move && view.timeline_drag_active {
		delta_x := event.x-view.timeline_drag_start_x
		abs_x := delta_x
		if abs_x < 0 { abs_x = -abs_x }
		if abs_x > 3 { view.timeline_drag_moved = true }
		if view.timeline_drag_moved && ctx.logical_bounds.w > 0 {
			span := view.timeline_drag_start_end-view.timeline_drag_start_time
			shift := -f64(delta_x/ctx.logical_bounds.w)*span
			if scope_timeline_set_range(app, view.timeline_drag_start_time+shift, view.timeline_drag_start_end+shift) {
				alicorn.trace_mutation(rt, "Scope timeline viewport panned")
				scope_refresh_timeline_geometry(app, rt)
			}
		}
		return
	}
	if event.kind == .Up && view.timeline_drag_active {
		was_drag := view.timeline_drag_moved
		view.timeline_drag_active = false
		if was_drag {
			_ = scope_request_timeline(app)
		} else if target == id {
			local_x := event.x-ctx.logical_bounds.x
			event_in_clip := event.x >= ctx.clip.x && event.x <= ctx.clip.x+ctx.clip.w && event.y >= ctx.clip.y && event.y <= ctx.clip.y+ctx.clip.h
			if event_in_clip {
				local_y := event.y-ctx.logical_bounds.y
				if event_id, found := scope_timeline_hit_test(view^, local_x, local_y, ctx.logical_bounds.w, ctx.logical_bounds.h); found {
					view.ui.has_selected_event = true
					view.ui.selected_event_id = event_id
					view.ui.has_selected_event_row = false
					view.ui.has_pending_navigation_row = false
					frontend.scope_publish_interaction(view, .Event_Selected, 0, event_id)
					alicorn.trace_mutation(rt, "Scope timeline event selected")
					alicorn.invalidate_root(rt, "scope timeline selected event")
				}
			}
		}
	}
}

scope_on_scroll :: proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event) {
	app := cast(^Scope_App)state
	ctx, ok := alicorn.gpu_surface_context(rt, app.view.ui.timeline_surface_node)
	if !ok || ctx.logical_bounds.w <= 0 || event.x < ctx.clip.x || event.x > ctx.clip.x+ctx.clip.w || event.y < ctx.clip.y || event.y > ctx.clip.y+ctx.clip.h { return }
	zoom_modifier := event.modifiers.control
	when ODIN_OS == .Darwin { zoom_modifier = event.modifiers.super }
	if !zoom_modifier { return }
	if event.delta_y == 0 { return }
	factor := clamp(1-f64(event.delta_y)*0.12, 0.25, 4.0)
	old_start, old_end := app.view.timeline_start_us, app.view.timeline_end_us
	old_span := old_end-old_start
	if old_span <= 0 { return }
	anchor := old_start+f64(clamp((event.x-ctx.logical_bounds.x)/ctx.logical_bounds.w, 0, 1))*old_span
	trace_span := scope_timeline_effective_end(app.view)-app.view.trace_start_us
	new_span := clamp(old_span*factor, max(trace_span/1_000_000, 0.000001), trace_span)
	anchor_ratio := (anchor-old_start)/old_span
	new_start := anchor-anchor_ratio*new_span
	if scope_timeline_set_range(app, new_start, new_start+new_span) {
		alicorn.trace_mutation(rt, "Scope timeline viewport zoomed")
		scope_refresh_timeline_geometry(app, rt)
		_ = scope_request_timeline(app)
	}
}

scope_on_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^Scope_App)state
	if change.changed { alicorn.trace_mutation(rt, "Scope command palette query changed") }
	frontend.scope_on_text_change(&app.view, rt, change)
}

scope_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	app := cast(^Scope_App)state
	if app.view.ui.command_palette_open {
		#partial switch key {
		case .Escape:
			return scope_dispatch_command(app, rt, .Toggle_Command_Palette)
		case .Return:
			frontend.scope_prepare_command_palette(&app.view)
			if app.view.ui.palette_visible_count == 0 { return true }
			command := app.view.ui.palette_visible_commands[app.view.ui.palette_selected_index]
			return scope_dispatch_command(app, rt, command)
		case .Up:
			frontend.scope_prepare_command_palette(&app.view)
			if app.view.ui.palette_visible_count > 0 { app.view.ui.palette_selected_index = max(0, app.view.ui.palette_selected_index-1) }
			_ = alicorn.virtual_list_ensure_visible(rt, app.view.ui.command_palette_results_scroll_node, app.view.ui.palette_selected_index, "Scope command palette selection visibility")
			alicorn.invalidate_root(rt, "Scope command palette selection moved")
			return true
		case .Down:
			frontend.scope_prepare_command_palette(&app.view)
			if app.view.ui.palette_visible_count > 0 { app.view.ui.palette_selected_index = min(app.view.ui.palette_visible_count-1, app.view.ui.palette_selected_index+1) }
			_ = alicorn.virtual_list_ensure_visible(rt, app.view.ui.command_palette_results_scroll_node, app.view.ui.palette_selected_index, "Scope command palette selection visibility")
			alicorn.invalidate_root(rt, "Scope command palette selection moved")
			return true
		}
	}
	if app.view.ui.filter_node != 0 && rt.focused == app.view.ui.filter_node {
		if key == .Open_Repository { return scope_dispatch_command(app, rt, .Open_Trace) }
		if key == .Open_Command_Palette { return scope_dispatch_command(app, rt, .Toggle_Command_Palette) }
		if key == .Escape && app.view.ui.show_runtime_inspector {
			return scope_dispatch_command(app, rt, .Toggle_Runtime_Inspector)
		}
		return false
	}
	#partial switch key {
	case .Up:        return scope_dispatch_command(app, rt, .Previous_Event)
	case .Down:      return scope_dispatch_command(app, rt, .Next_Event)
	case .Page_Up:   return frontend.scope_on_navigation_key(&app.view, rt, .Page_Up)
	case .Page_Down: return frontend.scope_on_navigation_key(&app.view, rt, .Page_Down)
	case .Home:      return scope_dispatch_command(app, rt, .Fit_Trace)
	case .Fit_Selection: return scope_dispatch_command(app, rt, .Fit_Selection)
	case .Open_Repository: return scope_dispatch_command(app, rt, .Open_Trace)
	case .Open_Command_Palette: return scope_dispatch_command(app, rt, .Toggle_Command_Palette)
	case .Escape:
		if app.view.ui.show_runtime_inspector { return scope_dispatch_command(app, rt, .Toggle_Runtime_Inspector) }
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
	if result == nil { return }
	switch result.status {
	case .Cancelled:
		return
	case .Error:
		scope_report_dialog_error(app, rt, result.error)
		return
	case .Accepted:
		if len(result.paths) == 0 { return }
	}
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
	if app.view.ui.has_selected_event && app.view.selected_event.available && app.view.selected_event.id == app.view.ui.selected_event_id && app.view.selected_event.has_query_row && (!app.view.ui.has_selected_event_row || app.view.ui.selected_event_row != app.view.selected_event.query_row) {
		app.view.ui.has_selected_event_row = true
		app.view.ui.selected_event_row = app.view.selected_event.query_row
		if app.view.ui.events_scroll_node != 0 {
			_ = alicorn.virtual_list_ensure_visible(rt, app.view.ui.events_scroll_node, app.view.selected_event.query_row, "scope synchronized timeline selection")
		}
	}
	_ = scope_request_timeline(app)
	if state_changed || telemetry_changed {
		alicorn.trace_mutation(rt, "Scope async result applied")
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
	fmt.println(
		"scope_timeline_metrics",
		"pointer_events", app.timeline_pointer_events,
		"window_requests", app.timeline_requests,
		"cache_hits", app.timeline_cache_hits,
		"resource_decodes", app.timeline_resource_decodes,
		"geometry_updates", app.timeline_geometry_updates,
	)
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
	if !initialized || count < 16 {
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
	scope_configure_native_menus(app)
	application := host.Application{
		state=rawptr(app),
		title="Alicorn Scope",
		width=1440,
		height=900,
		build=scope_build,
		on_text_change=scope_on_text_change,
		on_key=scope_on_key,
		on_pointer=scope_on_pointer,
		on_scroll=scope_on_scroll,
		on_tick=nil,
		on_services=scope_on_services,
		on_start=scope_on_start,
		on_dialog=scope_on_dialog,
		on_wake=scope_on_wake,
		on_stop=scope_on_stop,
	}
	when ODIN_OS == .Windows {
		application.window_decorations = .System
	}
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		application.menus = app.menus[:]
		application.on_menu_command = scope_on_menu_command
	}
	host.Run(application, smoke)
}
