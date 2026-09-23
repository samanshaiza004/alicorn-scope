package frontend

import "core:fmt"
import "core:strings"
import alicorn "../../alicorn/runtime"

SCOPE_BACKGROUND       :: alicorn.Color{0.035, 0.045, 0.065, 1}
SCOPE_PANEL_BACKGROUND :: alicorn.Color{0.055, 0.075, 0.115, 1}
SCOPE_HEADER_BACKGROUND :: alicorn.Color{0.08, 0.13, 0.22, 1}

SCOPE_TRACK_ROW_HEIGHT :: f32(34)
SCOPE_EVENT_ROW_HEIGHT :: f32(46)
SCOPE_ARGUMENT_ROW_HEIGHT :: f32(40)
SCOPE_EVENT_WINDOW_SIZE :: int(512)

Scope_Trace_Load_Status :: enum {
	Empty,
	Loading,
	Ready,
	Failed,
}

Scope_Track :: struct {
	id: u64,
	name: string,
	event_count: int,
	enabled: bool,
}

Scope_Event_Row :: struct {
	id: u64,
	timestamp_us: f64,
	duration_us: f64,
	category: string,
	name: string,
}

Scope_Argument :: struct {
	// Stable within its event so argument rows retain identity if reordered.
	id: u64,
	name: string,
	value: string,
}

Scope_Event_Detail :: struct {
	available: bool,
	id: u64,
	has_query_row: bool,
	query_row: int,
	timestamp_us: f64,
	duration_us: f64,
	category: string,
	name: string,
	arguments: []Scope_Argument,
	arguments_truncated: bool,
	arguments_original_bytes: u64,
}

Scope_Interaction_Kind :: enum {
	None,
	Track_Selected,
	Track_Toggled,
	Event_Selected,
	Filter_Changed,
	Track_Window_Requested,
	Window_Requested,
	Open_Trace,
}

// The Go/FFI adapter can consume interactions by observing sequence. Clear the
// result after handling it, or retain it and compare sequence on each frame.
Scope_Interaction_Result :: struct {
	kind: Scope_Interaction_Kind,
	sequence: u64,
	track_id: u64,
	event_id: u64,
	first_row: int,
	enabled: bool,
}

Scope_Timeline_Mode :: enum { None, Raw, Aggregate }

Scope_Timeline_Row :: struct {
	event_id: u64,
	track_id: u64,
	timestamp_us: f64,
	duration_us: f64,
	kind: u32,
	bucket_start_us: f64,
	bucket_end_us: f64,
	event_count: u64,
	duration_sum_us: f64,
}

Scope_UI_State :: struct {
	has_selected_track: bool,
	selected_track_id: u64,
	has_selected_event: bool,
	selected_event_id: u64,
	has_selected_event_row: bool,
	selected_event_row: int,
	has_pending_navigation_row: bool,
	pending_navigation_row: int,
	has_pending_window_request: bool,
	pending_window_first_row: int,
	has_pending_track_window_request: bool,
	pending_track_window_first_row: int,

	filter_node: alicorn.Node_ID,
	tracks_scroll_node: alicorn.Node_ID,
	events_scroll_node: alicorn.Node_ID,
	arguments_scroll_node: alicorn.Node_ID,
	timeline_surface_node: alicorn.Node_ID,
	filter_owned: bool,
}

// Scope_View is the bounded view model passed between FFI glue and the Odin
// presentation layer. The trace itself remains owned by the Go backend.
Scope_View :: struct {
	trace_path: string,
	trace_summary: string,
	load_status: Scope_Trace_Load_Status,
	load_message: string,
	trace_track_count: int,

	tracks: []Scope_Track,
	track_first_row: int,
	track_total_count: int,
	// The backend supplies at most one contiguous, bounded event window.
	events: []Scope_Event_Row,
	event_first_row: int,
	event_total_count: int,
	selected_event: Scope_Event_Detail,
	trace_start_us, trace_end_us: f64,
	timeline_start_us, timeline_end_us: f64,
	timeline_cache_start_us, timeline_cache_end_us: f64,
	timeline_cache_track_id: u64,
	timeline_cache_trace_generation: u64,
	timeline_cache_query_generation: u64,
	timeline_rows: []Scope_Timeline_Row,
	timeline_mode: Scope_Timeline_Mode,
	timeline_total_events: u64,
	timeline_ready: bool,
	timeline_revision: u64,
	timeline_geometry_revision: u64,
	timeline_geometry_width, timeline_geometry_height: f32,
	timeline_drag_active: bool,
	timeline_drag_moved: bool,
	timeline_drag_start_x: f32,
	timeline_drag_start_time: f64,
	timeline_drag_start_end: f64,
	timeline_request_pending: bool,
	timeline_request_track_id: u64,
	timeline_request_start_us, timeline_request_end_us: f64,

	filter: string,
	interaction: Scope_Interaction_Result,
	ui: Scope_UI_State,
}

scope_timeline_track_y :: proc(view: Scope_View, track_id: u64, height: f32) -> (y: f32, found: bool) {
	track_count := max(len(view.tracks), 1)
	row_height := height/f32(track_count)
	for track, local_index in view.tracks {
		if track.id == track_id {
			return min((f32(local_index)+0.5)*row_height, max(height-1, 0)), true
		}
	}
	if track_id != 0 && view.timeline_cache_track_id == track_id {
		return height*0.5, true
	}
	return 0, false
}

Scope_Navigation_Key :: enum {
	Up,
	Down,
	Page_Up,
	Page_Down,
}

scope_load_status_text :: proc(view: Scope_View) -> string {
	if len(view.load_message) > 0 {
		if view.load_status == .Loading || view.load_status == .Failed {
			return view.load_message
		}
	}
	#partial switch view.load_status {
	case .Empty:   return "No trace loaded"
	case .Loading: return "Loading trace..."
	case .Ready:   return fmt.tprintf("Ready  ·  %d tracks  ·  %d events", view.trace_track_count, view.event_total_count)
	case .Failed:  return "Trace load failed"
	}
	return ""
}

scope_time_text :: proc(microseconds: f64) -> string {
	return fmt.tprintf("%.3f ms", microseconds/1000.0)
}

scope_publish_interaction :: proc(
	view: ^Scope_View,
	kind: Scope_Interaction_Kind,
	track_id, event_id: u64,
	first_row: int = 0,
	enabled := false,
) {
	sequence := view.interaction.sequence + 1
	if sequence == 0 { sequence = 1 }
	view.interaction = Scope_Interaction_Result{
		kind = kind,
		sequence = sequence,
		track_id = track_id,
		event_id = event_id,
		first_row = first_row,
		enabled = enabled,
	}
}

scope_cached_event_count :: proc(view: Scope_View) -> int {
	return min(len(view.events), SCOPE_EVENT_WINDOW_SIZE)
}

scope_cached_track_count :: proc(view: Scope_View) -> int {
	return min(len(view.tracks), SCOPE_EVENT_WINDOW_SIZE)
}

scope_track_cache_index :: proc(view: Scope_View, global_row: int) -> int {
	local_row := global_row - view.track_first_row
	if local_row < 0 || local_row >= scope_cached_track_count(view) { return -1 }
	return local_row
}

scope_request_track_window :: proc(view: ^Scope_View, global_row: int) -> bool {
	if global_row < 0 || global_row >= view.track_total_count { return false }
	first_row := (global_row/SCOPE_EVENT_WINDOW_SIZE)*SCOPE_EVENT_WINDOW_SIZE
	if view.ui.has_pending_track_window_request && view.ui.pending_track_window_first_row == first_row {
		return false
	}
	view.ui.has_pending_track_window_request = true
	view.ui.pending_track_window_first_row = first_row
	scope_publish_interaction(view, .Track_Window_Requested, 0, 0, first_row=first_row)
	return true
}

scope_ack_cached_tracks :: proc(view: ^Scope_View) -> bool {
	if !view.ui.has_pending_track_window_request { return false }
	if scope_cached_track_count(view^) > 0 && view.track_first_row == view.ui.pending_track_window_first_row {
		view.ui.has_pending_track_window_request = false
		return true
	}
	return false
}

scope_event_cache_index :: proc(view: Scope_View, global_row: int) -> int {
	local_row := global_row - view.event_first_row
	if local_row < 0 || local_row >= scope_cached_event_count(view) { return -1 }
	return local_row
}

scope_request_event_window :: proc(view: ^Scope_View, global_row: int) -> bool {
	if global_row < 0 || global_row >= view.event_total_count { return false }
	first_row := (global_row/SCOPE_EVENT_WINDOW_SIZE)*SCOPE_EVENT_WINDOW_SIZE
	if view.ui.has_pending_window_request && view.ui.pending_window_first_row == first_row {
		return false
	}
	view.ui.has_pending_window_request = true
	view.ui.pending_window_first_row = first_row
	scope_publish_interaction(view, .Window_Requested, 0, 0, first_row=first_row)
	return true
}

// Call after replacing the cached event window. It clears a fulfilled window
// request and selects a pending keyboard target once that row is available.
// The return value is true when either pending state was acknowledged.
scope_ack_cached_window :: proc(view: ^Scope_View) -> bool {
	acknowledged := false
	if view.ui.has_pending_window_request {
		cached_count := scope_cached_event_count(view^)
		if cached_count > 0 && view.event_first_row == view.ui.pending_window_first_row {
			view.ui.has_pending_window_request = false
			acknowledged = true
		}
	}
	if scope_resolve_pending_navigation(view) {
		view.ui.has_pending_window_request = false
		acknowledged = true
	}
	return acknowledged
}

scope_clear_interaction :: proc(view: ^Scope_View) {
	sequence := view.interaction.sequence
	view.interaction = Scope_Interaction_Result{sequence=sequence}
}

// Call from the host's Alicorn text-change callback. The runtime owns
// change.text; this view keeps its own copy for the next build and the FFI
// adapter can read it after observing .Filter_Changed.
scope_on_text_change :: proc(view: ^Scope_View, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	if change.node != view.ui.filter_node || !change.changed { return }
	copy, err := strings.clone(change.text)
	if err != nil { return }
	if view.ui.filter_owned && len(view.filter) > 0 {
		delete(view.filter)
	}
	view.filter = copy
	view.ui.filter_owned = true
	view.ui.has_selected_event_row = false
	view.ui.has_pending_navigation_row = false
	view.ui.has_pending_window_request = false
	view.ui.has_pending_track_window_request = false
	scope_publish_interaction(view, .Filter_Changed, 0, 0)
	alicorn.invalidate_root(rt, "scope filter changed")
}

scope_event_position :: proc(view: Scope_View, id: u64) -> int {
	cached_count := scope_cached_event_count(view)
	for event, local_row in view.events[:cached_count] {
		if event.id == id { return view.event_first_row + local_row }
	}
	return -1
}

scope_resolve_pending_navigation :: proc(view: ^Scope_View) -> bool {
	if !view.ui.has_pending_navigation_row { return false }
	if view.ui.pending_navigation_row < 0 || view.ui.pending_navigation_row >= view.event_total_count {
		view.ui.has_pending_navigation_row = false
		return false
	}
	local_row := scope_event_cache_index(view^, view.ui.pending_navigation_row)
	if local_row < 0 { return false }
	event := view.events[local_row]
	view.ui.has_selected_event = true
	view.ui.selected_event_id = event.id
	view.ui.has_selected_event_row = true
	view.ui.selected_event_row = view.ui.pending_navigation_row
	view.ui.has_pending_navigation_row = false
	scope_publish_interaction(view, .Event_Selected, 0, event.id)
	return true
}

// Call from the host's application-key callback when it receives one of the
// four navigation keys. The host should suppress application navigation while
// Alicorn's filter text field owns keyboard focus, as Alicorn History does.
scope_on_navigation_key :: proc(view: ^Scope_View, rt: ^alicorn.Runtime, key: Scope_Navigation_Key) -> bool {
	total_count := max(0, view.event_total_count)
	if total_count == 0 { return false }

	scroll := alicorn.scroll_region_state(rt, view.ui.events_scroll_node)
	page := max(1, int(scroll.viewport_height/SCOPE_EVENT_ROW_HEIGHT)-1)
	delta := 0
	#partial switch key {
	case .Up:       delta = -1
	case .Down:     delta = 1
	case .Page_Up:  delta = -page
	case .Page_Down: delta = page
	}

	position := -1
	if view.ui.has_pending_navigation_row {
		position = view.ui.pending_navigation_row
	} else if view.ui.has_selected_event_row {
		position = view.ui.selected_event_row
	} else if view.ui.has_selected_event {
		position = scope_event_position(view^, view.ui.selected_event_id)
	}
	if position < 0 {
		if delta < 0 { position = total_count-1 }
		else { position = 0 }
	} else {
		position += delta
		position = clamp(position, 0, total_count-1)
	}

	if position == view.ui.selected_event_row && !view.ui.has_pending_navigation_row && view.ui.has_selected_event_row {
		return false
	}
	local_row := scope_event_cache_index(view^, position)
	if local_row >= 0 {
		event := view.events[local_row]
		if view.ui.has_selected_event && view.ui.selected_event_id == event.id && !view.ui.has_pending_navigation_row {
			return false
		}
		view.ui.has_selected_event = true
		view.ui.selected_event_id = event.id
		view.ui.has_selected_event_row = true
		view.ui.selected_event_row = position
		view.ui.has_pending_navigation_row = false
		scope_publish_interaction(view, .Event_Selected, 0, event.id)
	} else {
		view.ui.has_pending_navigation_row = true
		view.ui.pending_navigation_row = position
		_ = scope_request_event_window(view, position)
	}
	_ = alicorn.virtual_list_ensure_visible(rt, view.ui.events_scroll_node, position, "scope event selection visibility")
	alicorn.invalidate_root(rt, "scope event selection changed by keyboard")
	return true
}

// scope_render owns the normal Alicorn frame boundary and can be used as the
// application's build callback. It emits no timeline; only the three explorer
// panes and the trace/filter header are described here.
scope_render :: proc(view: ^Scope_View, rt: ^alicorn.Runtime) -> alicorn.Node_ID {
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }

	first_build := view.ui.filter_node == 0
	selection_changed := false
	event_window_acknowledged := scope_ack_cached_window(view)
	track_window_acknowledged := scope_ack_cached_tracks(view)
	if event_window_acknowledged || track_window_acknowledged {
		selection_changed = true
	}
	root := alicorn.container_begin(
		&ui,
		.Root,
		label="scope-root",
		style=alicorn.layout_style(padding=12, gap=8, clip=true),
		color=SCOPE_BACKGROUND,
	)

	alicorn.container_begin(
		&ui,
		.Container,
		label="scope-title-row",
		style=alicorn.layout_style(.Row, height=32, gap=10, align=.Center),
	)
	alicorn.text(
		&ui,
		"Alicorn Scope",
		style=alicorn.layout_style(.Row, height=30, grow=1),
		text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD},
	)
	alicorn.text(
		&ui,
		scope_load_status_text(view^),
		style=alicorn.layout_style(.Row, height=28),
	)
	open_trace_clicked := alicorn.button(
		&ui,
		"Open Trace...",
		key=alicorn.key_string("scope-open-trace"),
		style=alicorn.layout_style(.Row, width=128, height=30),
		text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM},
	)
	if open_trace_clicked {
		scope_publish_interaction(view, .Open_Trace, 0, 0)
	}
	alicorn.container_end(&ui)

	trace_label := view.trace_path
	if len(trace_label) == 0 { trace_label = "Open a Chrome Trace Event JSON file to begin" }
	summary := view.trace_summary
	if len(summary) == 0 { summary = scope_load_status_text(view^) }
	alicorn.container_begin(
		&ui,
		.Container,
		label="scope-trace-summary",
		style=alicorn.layout_style(height=48, padding=7, gap=2, clip=true),
		color=SCOPE_HEADER_BACKGROUND,
	)
	alicorn.text(&ui, trace_label, style=alicorn.layout_style(.Row, height=18), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.text(&ui, summary, style=alicorn.layout_style(.Row, height=18), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.container_end(&ui)

	alicorn.container_begin(
		&ui,
		.Container,
		label="scope-filter-row",
		style=alicorn.layout_style(.Row, height=34, gap=10, align=.Center),
	)
	filter_id := alicorn.text_field(
		&ui,
		view.filter,
		key=alicorn.key_string("scope-filter"),
		style=alicorn.layout_style(.Row, height=32, grow=1),
		text_style=alicorn.Text_Style{overflow=.Ellipsis},
	)
	alicorn.text(
		&ui,
		fmt.tprintf("%d total events", view.event_total_count),
		style=alicorn.layout_style(.Row, height=28),
	)
	alicorn.container_end(&ui)

	outer_split := alicorn.split_begin(
		&ui,
		key=alicorn.key_string("scope-workspace-inspector-split"),
		axis=.Horizontal,
		initial=800,
		min_first=452,
		min_second=280,
		style=alicorn.layout_style(grow=1, clip=true),
		label="scope-workspace-inspector",
	)
	alicorn.split_first_begin(&ui, outer_split)
	inner_split := alicorn.split_begin(
		&ui,
		key=alicorn.key_string("scope-tracks-events-split"),
		axis=.Horizontal,
		initial=238,
		min_first=150,
		min_second=300,
		style=alicorn.layout_style(grow=1, clip=true),
		label="scope-tracks-events",
	)
	alicorn.split_first_begin(&ui, inner_split)

	// Tracks pane.
	alicorn.container_begin(
		&ui,
		.Container,
		label="scope-tracks-panel",
		style=alicorn.layout_style(grow=1, padding=8, gap=6, clip=true),
		color=SCOPE_PANEL_BACKGROUND,
	)
	alicorn.text(
		&ui,
		fmt.tprintf("Tracks  (%d)", view.trace_track_count),
		style=alicorn.layout_style(.Row, height=28),
		text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD},
	)
	track_list := alicorn.virtual_list_begin(
		&ui,
		max(0, view.track_total_count),
		SCOPE_TRACK_ROW_HEIGHT,
		key=alicorn.key_string("scope-tracks-scroll"),
		style=alicorn.layout_style(grow=1, clip=true),
		label="scope-tracks-list",
		axes=.Vertical,
	)
	view.ui.tracks_scroll_node = track_list.scroll.id
	track_request_position := -1
	for position := track_list.first; position < track_list.last; position += 1 {
		local_track := scope_track_cache_index(view^, position)
		if local_track < 0 {
			if track_request_position < 0 { track_request_position = position }
			if !alicorn.component_begin(&ui, alicorn.key_pair(u64(position), 2)) { continue }
			alicorn.text(&ui, fmt.tprintf("Loading track %d...", position+1), style=alicorn.layout_style(.Row, height=SCOPE_TRACK_ROW_HEIGHT, padding=5))
			alicorn.component_end(&ui)
			continue
		}
		track := view.tracks[local_track]
		if !alicorn.component_begin(&ui, alicorn.key_u64(track.id)) { continue }
		selected := view.ui.has_selected_track && view.ui.selected_track_id == track.id
		alicorn.container_begin(
			&ui,
			.Container,
			label="scope-track-row",
			style=alicorn.layout_style(.Row, height=SCOPE_TRACK_ROW_HEIGHT, gap=4),
		)
		clicked := alicorn.button(
			&ui,
			track.name,
			state=alicorn.Button_State{selected=selected},
			style=alicorn.layout_style(.Row, height=SCOPE_TRACK_ROW_HEIGHT, grow=1, padding=5),
			text_style=alicorn.Text_Style{overflow=.Ellipsis},
		)
		if clicked {
			track_changed := !view.ui.has_selected_track || view.ui.selected_track_id != track.id
			view.ui.has_selected_track = true
			view.ui.selected_track_id = track.id
			if track_changed {
				view.ui.has_selected_event = false
				view.ui.selected_event_id = 0
				view.ui.has_selected_event_row = false
				view.ui.has_pending_navigation_row = false
				view.timeline_revision += 1
				if view.timeline_revision == 0 { view.timeline_revision = 1 }
			}
			scope_publish_interaction(view, .Track_Selected, track.id, 0)
			selection_changed = true
		}
		toggle_label := "On"
		if !track.enabled { toggle_label = "Off" }
		toggle_clicked := alicorn.button(
			&ui,
			toggle_label,
			state=alicorn.Button_State{selected=track.enabled},
			style=alicorn.layout_style(.Row, width=48, height=30),
		)
		if toggle_clicked {
			enabled := !track.enabled
			view.tracks[local_track].enabled = enabled
			view.ui.has_selected_event_row = false
			view.ui.has_pending_navigation_row = false
			view.ui.has_pending_window_request = false
			view.ui.has_pending_track_window_request = false
			scope_publish_interaction(view, .Track_Toggled, track.id, 0, enabled=enabled)
			selection_changed = true
		}
		alicorn.container_end(&ui)
		alicorn.component_end(&ui)
	}
	if track_request_position >= 0 {
		_ = scope_request_track_window(view, track_request_position)
	}
	alicorn.virtual_list_end(&ui, track_list)
	if view.track_total_count == 0 {
		alicorn.text(&ui, "No tracks", style=alicorn.layout_style(.Row, height=28))
	}
	alicorn.container_end(&ui)
	alicorn.split_first_end(&ui, inner_split)
	alicorn.split_divider(&ui, inner_split)
	alicorn.split_second_begin(&ui, inner_split)

	// Events pane.
	alicorn.container_begin(
		&ui,
		.Container,
		label="scope-events-panel",
		style=alicorn.layout_style(grow=1, padding=8, gap=6, clip=true),
		color=SCOPE_PANEL_BACKGROUND,
	)
	timeline_split := alicorn.split_begin(
		&ui,
		key=alicorn.key_string("scope-timeline-events-split"),
		axis=.Vertical,
		initial=290,
		min_first=140,
		min_second=150,
		style=alicorn.layout_style(grow=1, clip=true),
		label="scope-timeline-events",
	)
	alicorn.split_first_begin(&ui, timeline_split)
	alicorn.container_begin(
		&ui,
		.Container,
		label="scope-timeline-panel",
		style=alicorn.layout_style(grow=1, gap=4, clip=true),
	)
	track_label := "all enabled tracks"
	if view.track_first_row >= 512 { track_label = "selected track · large catalog" }
	mode_label := "Loading time window..."
	if view.timeline_ready {
		mode_label = fmt.tprintf("%d events in range", view.timeline_total_events)
		if view.timeline_mode == .Aggregate { mode_label = fmt.tprintf("Aggregated · %d events", view.timeline_total_events) }
	}
	alicorn.container_begin(&ui, .Container, label="scope-timeline-heading", style=alicorn.layout_style(.Row, height=28, gap=8, align=.Center))
	alicorn.text(&ui, fmt.tprintf("Timeline  ·  %s", track_label), style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD, overflow=.Ellipsis})
	alicorn.text(&ui, mode_label, style=alicorn.layout_style(.Row, height=24), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.container_end(&ui)
	if !view.ui.has_selected_track {
		alicorn.text(&ui, "Select a track to view its events over time", style=alicorn.layout_style(.Row, height=24))
	}
	view.ui.timeline_surface_node = alicorn.gpu_geometry_surface(
		&ui,
		"scope-timeline-geometry",
		0,
		alicorn.layout_style(grow=1, clip=true),
	)
	alicorn.container_end(&ui)
	alicorn.split_first_end(&ui, timeline_split)
	alicorn.split_divider(&ui, timeline_split)
	alicorn.split_second_begin(&ui, timeline_split)
	alicorn.text(
		&ui,
		fmt.tprintf("Events  (%d)", view.event_total_count),
		style=alicorn.layout_style(.Row, height=28),
		text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD},
	)
	event_list := alicorn.virtual_list_begin(
		&ui,
		max(0, view.event_total_count),
		SCOPE_EVENT_ROW_HEIGHT,
		key=alicorn.key_string("scope-events-scroll"),
		style=alicorn.layout_style(grow=1, clip=true),
		label="scope-events-list",
		axes=.Vertical,
	)
	view.ui.events_scroll_node = event_list.scroll.id
	request_position := -1
	for position := event_list.first; position < event_list.last; position += 1 {
		local_row := scope_event_cache_index(view^, position)
		if local_row < 0 {
			if request_position < 0 { request_position = position }
			if !alicorn.component_begin(&ui, alicorn.key_pair(u64(position), 1)) { continue }
			alicorn.text(
				&ui,
				fmt.tprintf("Loading event row %d...", position+1),
				style=alicorn.layout_style(.Row, height=SCOPE_EVENT_ROW_HEIGHT, padding=5),
			)
			alicorn.component_end(&ui)
			continue
		}
		event := view.events[local_row]
		if !alicorn.component_begin(&ui, alicorn.key_u64(event.id)) { continue }
		selected := view.ui.has_selected_event && view.ui.selected_event_id == event.id
		label := fmt.tprintf(
			"%d   %s   %s   %s   %s",
			event.id,
			scope_time_text(event.timestamp_us),
			scope_time_text(event.duration_us),
			event.category,
			event.name,
		)
		clicked := alicorn.button(
			&ui,
			label,
			state=alicorn.Button_State{selected=selected},
			style=alicorn.layout_style(.Row, height=SCOPE_EVENT_ROW_HEIGHT, padding=5),
			text_style=alicorn.Text_Style{overflow=.Ellipsis},
		)
		if clicked {
			view.ui.has_selected_event = true
			view.ui.selected_event_id = event.id
			view.ui.has_selected_event_row = true
			view.ui.selected_event_row = position
			view.ui.has_pending_navigation_row = false
			scope_publish_interaction(view, .Event_Selected, 0, event.id)
			selection_changed = true
		}
		alicorn.component_end(&ui)
	}
	if request_position >= 0 {
		_ = scope_request_event_window(view, request_position)
	}
	alicorn.virtual_list_end(&ui, event_list)
	if view.event_total_count <= 0 {
		if view.load_status == .Ready {
			alicorn.text(&ui, "No matching events", style=alicorn.layout_style(.Row, height=28))
		} else {
			alicorn.text(&ui, "Events appear here after a trace loads", style=alicorn.layout_style(.Row, height=40))
		}
	}
	alicorn.container_end(&ui)
	alicorn.split_second_end(&ui, timeline_split)
	alicorn.split_end(&ui, timeline_split)
	alicorn.split_second_end(&ui, inner_split)
	alicorn.split_end(&ui, inner_split)
	alicorn.split_first_end(&ui, outer_split)
	alicorn.split_divider(&ui, outer_split)
	alicorn.split_second_begin(&ui, outer_split)

	// Inspector pane.
	alicorn.container_begin(
		&ui,
		.Container,
		label="scope-inspector-panel",
		style=alicorn.layout_style(grow=1, padding=8, gap=6, clip=true),
		color=SCOPE_PANEL_BACKGROUND,
	)
	alicorn.text(
		&ui,
		"Inspector",
		style=alicorn.layout_style(.Row, height=28),
		text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD},
	)
	if !view.ui.has_selected_event {
		alicorn.text(&ui, "Select an event to inspect its details", style=alicorn.layout_style(.Row, height=34))
	} else if !view.selected_event.available || view.selected_event.id != view.ui.selected_event_id {
		alicorn.text(&ui, "Loading selected event details...", style=alicorn.layout_style(.Row, height=34))
	} else {
		detail := view.selected_event
		alicorn.text(
			&ui,
			fmt.tprintf("%s  (#%d)", detail.name, detail.id),
			style=alicorn.layout_style(.Row, height=36),
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis},
		)
		alicorn.text(&ui, fmt.tprintf("Category  %s", detail.category), style=alicorn.layout_style(.Row, height=26), text_style=alicorn.Text_Style{overflow=.Ellipsis})
		alicorn.text(&ui, fmt.tprintf("Timestamp  %s", scope_time_text(detail.timestamp_us)), style=alicorn.layout_style(.Row, height=26))
		alicorn.text(&ui, fmt.tprintf("Duration  %s", scope_time_text(detail.duration_us)), style=alicorn.layout_style(.Row, height=26))
		if detail.arguments_truncated {
			alicorn.text(
				&ui,
				fmt.tprintf("Arguments truncated · original payload: %d bytes", detail.arguments_original_bytes),
				style=alicorn.layout_style(.Row, height=30),
				text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis},
			)
		}
		alicorn.text(
			&ui,
			fmt.tprintf("Arguments  (%d)", len(detail.arguments)),
			style=alicorn.layout_style(.Row, height=26),
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM},
		)
		if len(detail.arguments) == 0 {
			alicorn.text(&ui, "No arguments", style=alicorn.layout_style(.Row, height=26))
		} else {
			argument_list := alicorn.virtual_list_begin(
				&ui,
				len(detail.arguments),
				SCOPE_ARGUMENT_ROW_HEIGHT,
				key=alicorn.key_pair(detail.id, 1),
				style=alicorn.layout_style(grow=1, clip=true),
				label="scope-arguments-list",
				axes=.Vertical,
			)
			view.ui.arguments_scroll_node = argument_list.scroll.id
			for position := argument_list.first; position < argument_list.last; position += 1 {
				argument := detail.arguments[position]
				if !alicorn.component_begin(&ui, alicorn.key_pair(detail.id, argument.id)) { continue }
				alicorn.text(
					&ui,
					fmt.tprintf("%s: %s", argument.name, argument.value),
					style=alicorn.layout_style(.Row, height=SCOPE_ARGUMENT_ROW_HEIGHT, padding=5),
					text_style=alicorn.Text_Style{overflow=.Ellipsis},
				)
				alicorn.component_end(&ui)
			}
			alicorn.virtual_list_end(&ui, argument_list)
		}
	}
	alicorn.container_end(&ui)

	alicorn.split_second_end(&ui, outer_split)
	alicorn.split_end(&ui, outer_split)
	alicorn.container_end(&ui) // scope-root
	alicorn.end_frame(&ui)

	view.ui.filter_node = filter_id
	if first_build && filter_id != 0 {
		_ = alicorn.focus(rt, filter_id)
	}
	if selection_changed {
		alicorn.invalidate_root(rt, "scope selection changed")
	}
	return root
}
