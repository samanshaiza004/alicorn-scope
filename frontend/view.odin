package frontend

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"

SCOPE_BACKGROUND       :: alicorn.Color{0.035, 0.045, 0.065, 1}
SCOPE_PANEL_BACKGROUND :: alicorn.Color{0.055, 0.075, 0.115, 1}
SCOPE_HEADER_BACKGROUND :: alicorn.Color{0.08, 0.13, 0.22, 1}
SCOPE_TIMELINE_BACKGROUND :: alicorn.Color{0.025, 0.033, 0.050, 1}

SCOPE_TRACK_ROW_HEIGHT :: f32(34)
SCOPE_EVENT_ROW_HEIGHT :: f32(46)
SCOPE_ARGUMENT_ROW_HEIGHT :: f32(40)
SCOPE_EVENT_WINDOW_SIZE :: int(512)
SCOPE_COMMAND_PALETTE_ROW_HEIGHT :: f32(34)
SCOPE_COMMAND_PALETTE_MAX_ROWS :: int(8)
SCOPE_COMMAND_PALETTE_INPUT_HEIGHT :: f32(40)
SCOPE_COMMAND_PALETTE_PADDING :: f32(12)
SCOPE_COMMAND_PALETTE_GAP :: f32(6)

SCOPE_SEMANTIC_TRACK_NAMESPACE :: u64(1)
SCOPE_SEMANTIC_EVENT_NAMESPACE :: u64(2)

scope_track_semantic_id :: proc(track_id: u64) -> alicorn.Semantic_ID {
	return alicorn.Semantic_ID{namespace=SCOPE_SEMANTIC_TRACK_NAMESPACE, value=track_id}
}

scope_event_semantic_id :: proc(event_id: u64) -> alicorn.Semantic_ID {
	return alicorn.Semantic_ID{namespace=SCOPE_SEMANTIC_EVENT_NAMESPACE, value=event_id}
}

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
	Command_Invoked,
}

// Commands describe application operations, not individual data entities.
// The host's menu IDs carry the same numeric identity into Scope's dispatcher.
Scope_Command_ID :: enum u32 {
	None = 0,
	Open_Trace = 1,
	Show_Overview = 2,
	Fit_Trace = 3,
	Fit_Selection = 4,
	Previous_Event = 5,
	Next_Event = 6,
	Toggle_Runtime_Inspector = 7,
	Toggle_Command_Palette = 8,
	Clear_Selection = 9,
}

Scope_Command_Descriptor :: struct {
	id: Scope_Command_ID,
	name: string,
	label: string,
	shortcut: string,
	state: alicorn.Action_State,
}

Scope_Runtime_Activity :: struct {
	text: string,
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
	command_id: Scope_Command_ID,
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
	command_palette_node: alicorn.Node_ID,
	command_palette_overlay_node: alicorn.Node_ID,
	command_palette_panel_node: alicorn.Node_ID,
	command_palette_results_scroll_node: alicorn.Node_ID,
	tracks_scroll_node: alicorn.Node_ID,
	events_scroll_node: alicorn.Node_ID,
	arguments_scroll_node: alicorn.Node_ID,
	timeline_surface_node: alicorn.Node_ID,
	filter_owned: bool,
	command_palette_open: bool,
	command_palette_query_owned: bool,
	command_palette_focus_pending: bool,
	focus_restore_pending: bool,
	show_runtime_inspector: bool,
	command_palette_query: string,
	focus_before_palette: alicorn.Node_ID,
	palette_selected_index: int,
	palette_visible_count: int,
	palette_visible_commands: [9]Scope_Command_ID,
	palette_visible_scores: [9]int,
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
	runtime_inspection: string,
	runtime_activity: []Scope_Runtime_Activity,
	interaction: Scope_Interaction_Result,
	ui: Scope_UI_State,
}

scope_timeline_track_y :: proc(view: Scope_View, track_id: u64, height: f32) -> (y: f32, found: bool) {
	if view.ui.has_selected_track && track_id != view.ui.selected_track_id {
		return 0, false
	}
	// The timeline is either a focused single-track lane or a collapsed
	// all-track overview. It is deliberately not a compressed copy of the
	// independently virtualized track list.
	return height*0.5, true
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

scope_command_descriptors :: proc(view: Scope_View) -> [9]Scope_Command_Descriptor {
	ready := view.load_status == .Ready
	return {
		{id=.Open_Trace, name="scope.open_trace", label="Open Trace...", shortcut="Ctrl/Cmd+O", state=alicorn.Action_State{enabled=true}},
		{id=.Show_Overview, name="scope.show_overview", label="Show Overview", shortcut="", state=alicorn.Action_State{enabled=view.ui.has_selected_track}},
		{id=.Fit_Trace, name="scope.fit_whole_trace", label="Fit Whole Trace", shortcut="Home", state=alicorn.Action_State{enabled=ready}},
		{id=.Fit_Selection, name="scope.fit_selection", label="Fit Selection", shortcut="F", state=alicorn.Action_State{enabled=view.ui.has_selected_event}},
		{id=.Previous_Event, name="scope.previous_event", label="Previous Event", shortcut="", state=alicorn.Action_State{enabled=view.event_total_count > 0}},
		{id=.Next_Event, name="scope.next_event", label="Next Event", shortcut="", state=alicorn.Action_State{enabled=view.event_total_count > 0}},
		{id=.Toggle_Runtime_Inspector, name="scope.toggle_runtime_inspector", label="Runtime Inspector", shortcut="", state=alicorn.Action_State{enabled=true, checked=view.ui.show_runtime_inspector}},
		{id=.Toggle_Command_Palette, name="scope.command_palette", label="Command Palette...", shortcut="Ctrl/Cmd+Shift+P", state=alicorn.Action_State{enabled=true}},
		{id=.Clear_Selection, name="scope.clear_event_selection", label="Clear Event Selection", shortcut="", state=alicorn.Action_State{enabled=view.ui.has_selected_event}},
	}
}

scope_action_id :: proc(command: Scope_Command_ID) -> alicorn.Action_ID {
	return alicorn.Action_ID(u32(command))
}

scope_command_from_action_id :: proc(action: alicorn.Action_ID) -> Scope_Command_ID {
	return Scope_Command_ID(u32(action))
}

scope_command_label :: proc(id: Scope_Command_ID) -> string {
	for descriptor in scope_command_descriptors(Scope_View{}) {
		if descriptor.id == id { return descriptor.label }
	}
	return "Unknown command"
}

scope_command_name :: proc(id: Scope_Command_ID) -> string {
	for descriptor in scope_command_descriptors(Scope_View{}) {
		if descriptor.id == id { return descriptor.name }
	}
	return "scope.unknown"
}

scope_command_enabled :: proc(view: Scope_View, id: Scope_Command_ID) -> bool {
	for descriptor in scope_command_descriptors(view) {
		if descriptor.id == id { return descriptor.state.enabled }
	}
	return false
}

scope_command_checked :: proc(view: Scope_View, id: Scope_Command_ID) -> bool {
	for descriptor in scope_command_descriptors(view) {
		if descriptor.id == id { return descriptor.state.checked }
	}
	return false
}

scope_command_state :: proc(view: Scope_View, id: Scope_Command_ID) -> alicorn.Action_State {
	for descriptor in scope_command_descriptors(view) {
		if descriptor.id == id { return descriptor.state }
	}
	return {}
}

scope_fold_ascii :: proc(value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' { return value + ('a'-'A') }
	return value
}

// A compact case-insensitive subsequence score is sufficient for Scope's
// small command set; it rewards word starts and adjacent character matches.
scope_command_match_score :: proc(query, label: string) -> int {
	if len(query) == 0 { return 0 }
	query_index := 0
	last_match := -2
	score := 0
	for index := 0; index < len(label) && query_index < len(query); index += 1 {
		if scope_fold_ascii(label[index]) != scope_fold_ascii(query[query_index]) { continue }
		if index == 0 || label[index-1] == ' ' { score += 8 }
		if index == last_match+1 { score += 5 }
		score -= index
		last_match = index
		query_index += 1
	}
	if query_index != len(query) { return -1 }
	return score
}

scope_prepare_command_palette :: proc(view: ^Scope_View) {
	view.ui.palette_visible_count = 0
	descriptors := scope_command_descriptors(view^)
	for descriptor in descriptors {
		if !descriptor.state.enabled { continue }
		score := scope_command_match_score(view.ui.command_palette_query, descriptor.label)
		if score < 0 { continue }
		insert_at := view.ui.palette_visible_count
		if insert_at >= len(view.ui.palette_visible_commands) { continue }
		for insert_at > 0 && view.ui.palette_visible_scores[insert_at-1] < score {
			view.ui.palette_visible_commands[insert_at] = view.ui.palette_visible_commands[insert_at-1]
			view.ui.palette_visible_scores[insert_at] = view.ui.palette_visible_scores[insert_at-1]
			insert_at -= 1
		}
		view.ui.palette_visible_commands[insert_at] = descriptor.id
		view.ui.palette_visible_scores[insert_at] = score
		view.ui.palette_visible_count += 1
	}
	if view.ui.palette_visible_count == 0 {
		view.ui.palette_selected_index = 0
	} else {
		view.ui.palette_selected_index = clamp(view.ui.palette_selected_index, 0, view.ui.palette_visible_count-1)
	}
}

scope_show_overview :: proc(view: ^Scope_View) -> bool {
	if !view.ui.has_selected_track { return false }
	view.ui.has_selected_track = false
	view.ui.selected_track_id = 0
	view.ui.has_selected_event = false
	view.ui.selected_event_id = 0
	view.ui.has_selected_event_row = false
	view.ui.has_pending_navigation_row = false
	view.timeline_request_pending = false
	view.timeline_ready = false
	view.timeline_mode = .None
	view.timeline_revision += 1
	if view.timeline_revision == 0 { view.timeline_revision = 1 }
	return true
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
	command_id := Scope_Command_ID.None,
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
		command_id = command_id,
	}
}

scope_publish_command :: proc(view: ^Scope_View, command_id: Scope_Command_ID) {
	scope_publish_interaction(view, .Command_Invoked, 0, 0, command_id=command_id)
}

scope_cached_event_count :: proc(view: Scope_View) -> int {
	return min(len(view.events), SCOPE_EVENT_WINDOW_SIZE)
}

scope_cached_track_count :: proc(view: Scope_View) -> int {
	return min(len(view.tracks), SCOPE_EVENT_WINDOW_SIZE)
}

scope_window_first_row :: proc(total_rows, anchor_row: int) -> int {
	if total_rows <= 0 { return 0 }
	window_rows := min(total_rows, SCOPE_EVENT_WINDOW_SIZE)
	max_first_row := max(0, total_rows-window_rows)
	anchor := clamp(anchor_row, 0, total_rows-1)
	return clamp(anchor-window_rows/2, 0, max_first_row)
}

scope_window_contains :: proc(first_row, total_rows, row: int) -> bool {
	if first_row < 0 || row < first_row || row >= total_rows { return false }
	window_rows := min(SCOPE_EVENT_WINDOW_SIZE, total_rows-first_row)
	return row-first_row < window_rows
}

scope_track_cache_index :: proc(view: Scope_View, global_row: int) -> int {
	local_row := global_row - view.track_first_row
	if local_row < 0 || local_row >= scope_cached_track_count(view) { return -1 }
	return local_row
}

scope_request_track_window :: proc(view: ^Scope_View, global_row: int) -> bool {
	if global_row < 0 || global_row >= view.track_total_count { return false }
	if scope_track_cache_index(view^, global_row) >= 0 { return false }
	first_row := scope_window_first_row(view.track_total_count, global_row)
	if view.ui.has_pending_track_window_request && scope_window_contains(view.ui.pending_track_window_first_row, view.track_total_count, global_row) {
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
	if scope_event_cache_index(view^, global_row) >= 0 { return false }
	first_row := scope_window_first_row(view.event_total_count, global_row)
	if view.ui.has_pending_window_request && scope_window_contains(view.ui.pending_window_first_row, view.event_total_count, global_row) {
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
	if view.ui.command_palette_open && change.node == view.ui.command_palette_node && change.changed {
		copy, err := strings.clone(change.text)
		if err != nil { return }
		if view.ui.command_palette_query_owned && len(view.ui.command_palette_query) > 0 {
			delete(view.ui.command_palette_query)
		}
		view.ui.command_palette_query = copy
		view.ui.command_palette_query_owned = true
		view.ui.palette_selected_index = 0
		alicorn.invalidate_root(rt, "scope command palette query changed")
		return
	}
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

scope_command_palette_panel_height :: proc(result_count: int) -> f32 {
	visible_rows := min(max(result_count, 1), SCOPE_COMMAND_PALETTE_MAX_ROWS)
	return 2*SCOPE_COMMAND_PALETTE_PADDING + SCOPE_COMMAND_PALETTE_INPUT_HEIGHT + SCOPE_COMMAND_PALETTE_GAP + f32(visible_rows)*SCOPE_COMMAND_PALETTE_ROW_HEIGHT
}

scope_render_command_palette :: proc(view: ^Scope_View, ui: ^alicorn.UI) {
	scope_prepare_command_palette(view)
	descriptors := scope_command_descriptors(view^)
	visible_rows := min(max(view.ui.palette_visible_count, 1), SCOPE_COMMAND_PALETTE_MAX_ROWS)
	results_height := f32(visible_rows) * SCOPE_COMMAND_PALETTE_ROW_HEIGHT
	panel_height := scope_command_palette_panel_height(view.ui.palette_visible_count)
	view.ui.command_palette_overlay_node = alicorn.modal_overlay_begin(
		ui,
		alicorn.key_string("scope-command-palette-overlay"),
		style=alicorn.layout_style(.Column, padding=48, align=.Center, clip=true),
	)
	view.ui.command_palette_panel_node = alicorn.container_begin(
		ui,
		.Container,
		label="scope-command-palette",
		style=alicorn.layout_style(height=panel_height, max_width=680, padding=SCOPE_COMMAND_PALETTE_PADDING, gap=SCOPE_COMMAND_PALETTE_GAP, clip=true),
		color=SCOPE_PANEL_BACKGROUND,
	)
	alicorn.container_begin(
		ui,
		.Container,
		label="scope-command-palette-input-row",
		style=alicorn.layout_style(.Row, height=SCOPE_COMMAND_PALETTE_INPUT_HEIGHT, gap=8, align=.Center),
	)
	alicorn.text(ui, ">", style=alicorn.layout_style(.Row, width=16, height=36), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	palette_id := alicorn.text_field(
		ui,
		view.ui.command_palette_query,
		key=alicorn.key_string("scope-command-palette-query"),
		style=alicorn.layout_style(.Row, height=SCOPE_COMMAND_PALETTE_INPUT_HEIGHT, grow=1),
		text_style=alicorn.Text_Style{overflow=.Ellipsis},
	)
	view.ui.command_palette_node = palette_id
	alicorn.container_end(ui)
	if view.ui.palette_visible_count == 0 {
		alicorn.text(ui, "No matching commands", style=alicorn.layout_style(.Row, height=34, padding=8))
	} else {
		results := alicorn.virtual_list_begin(
			ui,
			view.ui.palette_visible_count,
			SCOPE_COMMAND_PALETTE_ROW_HEIGHT,
			key=alicorn.key_string("scope-command-palette-results"),
			style=alicorn.layout_style(height=results_height, clip=true),
			label="scope-command-palette-results",
		)
		view.ui.command_palette_results_scroll_node = results.scroll.id
		for index := results.first; index < results.last; index += 1 {
			command_id := view.ui.palette_visible_commands[index]
			descriptor := descriptors[0]
			for candidate in descriptors {
				if candidate.id == command_id { descriptor = candidate; break }
			}
			label := descriptor.label
			if len(descriptor.shortcut) > 0 { label = fmt.tprintf("%s  ·  %s", descriptor.label, descriptor.shortcut) }
			selected := index == view.ui.palette_selected_index
			if alicorn.button(
				ui,
				label,
				key=alicorn.key_pair(u64(command_id), 3),
				state=alicorn.Button_State{selected=selected, quiet=!selected},
				style=alicorn.layout_style(.Row, height=SCOPE_COMMAND_PALETTE_ROW_HEIGHT),
				text_style=alicorn.Text_Style{overflow=.Ellipsis},
				content_style=alicorn.button_content_style(horizontal=.Start, vertical=.Center, padding_x=10, padding_y=4),
			) {
				scope_publish_command(view, command_id)
			}
		}
		alicorn.virtual_list_end(ui, results)
	}
	alicorn.container_end(ui)
	alicorn.modal_overlay_end(ui)
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
		_ = alicorn.semantic_focus_set(rt, scope_event_semantic_id(event.id), view.ui.events_scroll_node)
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
	filter_id: alicorn.Node_ID
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
		scope_publish_command(view, .Open_Trace)
	}
	if alicorn.button(
		&ui,
		"Commands...",
		key=alicorn.key_string("scope-command-palette-open"),
		style=alicorn.layout_style(.Row, width=112, height=30),
		text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM},
	) {
		scope_publish_command(view, .Toggle_Command_Palette)
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
	filter_id = alicorn.text_field(
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
		focusable=true,
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
			content_style=alicorn.button_content_style(horizontal=.Start, vertical=.Center, padding_x=8, padding_y=4),
		)
		_ = alicorn.semantic_bind(&ui, scope_track_semantic_id(track.id))
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
				// A queued all-track/previous-track response must not keep the
				// focused lane waiting or paint stale geometry while it returns.
				view.timeline_request_pending = false
				view.timeline_ready = false
				view.timeline_mode = .None
			}
			_ = alicorn.semantic_focus_set(rt, scope_track_semantic_id(track.id), view.ui.tracks_scroll_node)
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
	track_label := "Overview"
	if view.ui.has_selected_track {
		track_label = "Selected track"
		for track in view.tracks {
			if track.id == view.ui.selected_track_id {
				track_label = track.name
				break
			}
		}
	}
	mode_label := "Loading time window..."
	if view.timeline_ready {
		if !view.ui.has_selected_track {
			mode_label = fmt.tprintf("Overview · %d events", view.timeline_total_events)
		} else {
			mode_label = fmt.tprintf("Events · %d in range", view.timeline_total_events)
			if view.timeline_mode == .Aggregate { mode_label = fmt.tprintf("Density · %d events", view.timeline_total_events) }
		}
	}
	alicorn.container_begin(&ui, .Container, label="scope-timeline-heading", style=alicorn.layout_style(.Row, height=28, gap=8, align=.Center))
		if view.ui.has_selected_track && alicorn.button(
		&ui,
		"← Overview",
		style=alicorn.layout_style(.Row, width=112, height=24),
		text_style=alicorn.Text_Style{overflow=.Ellipsis},
			content_style=alicorn.button_content_style(horizontal=.Start, vertical=.Center, padding_x=8, padding_y=0),
		) {
			scope_publish_command(view, .Show_Overview)
		}
	alicorn.text(&ui, fmt.tprintf("Timeline  ·  %s", track_label), style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD, overflow=.Ellipsis})
	alicorn.text(&ui, mode_label, style=alicorn.layout_style(.Row, height=24), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	alicorn.container_end(&ui)
	span_us := max(view.timeline_end_us-view.timeline_start_us, 1)
	alicorn.container_begin(&ui, .Container, label="scope-timeline-ruler", style=alicorn.layout_style(.Row, height=22), color=SCOPE_PANEL_BACKGROUND)
	for tick := 0; tick <= 4; tick += 1 {
		offset_ms := span_us*f64(tick)/4.0/1000.0
		if !alicorn.component_begin(&ui, alicorn.key_u64(u64(tick))) { continue }
		alicorn.text(
			&ui,
			fmt.tprintf("+%.2f ms", offset_ms),
			style=alicorn.layout_style(.Row, grow=1, height=22),
			text_style=alicorn.Text_Style{overflow=.Ellipsis},
		)
		alicorn.component_end(&ui)
	}
	alicorn.container_end(&ui)
	alicorn.container_begin(
		&ui,
		.Container,
		label="scope-timeline-plot-background",
		style=alicorn.layout_style(grow=1, clip=true),
		color=SCOPE_TIMELINE_BACKGROUND,
	)
	view.ui.timeline_surface_node = alicorn.gpu_geometry_surface(
		&ui,
		"scope-timeline-geometry",
		0,
		alicorn.layout_style(grow=1, clip=true),
	)
	alicorn.container_end(&ui)
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
		focusable=true,
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
			content_style=alicorn.button_content_style(horizontal=.Start, vertical=.Center, padding_x=8, padding_y=4),
		)
		_ = alicorn.semantic_bind(&ui, scope_event_semantic_id(event.id))
		if clicked {
			view.ui.has_selected_event = true
			view.ui.selected_event_id = event.id
			view.ui.has_selected_event_row = true
			view.ui.selected_event_row = position
			view.ui.has_pending_navigation_row = false
			_ = alicorn.semantic_focus_set(rt, scope_event_semantic_id(event.id), view.ui.events_scroll_node)
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
	alicorn.container_begin(&ui, .Container, label="scope-inspector-heading", style=alicorn.layout_style(.Row, height=30, gap=8, align=.Center))
	alicorn.text(
		&ui,
		"Inspector",
		style=alicorn.layout_style(.Row, grow=1),
		text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD},
	)
	inspector_toggle_label := "Runtime"
	if view.ui.show_runtime_inspector { inspector_toggle_label = "Event Details" }
	if alicorn.button(
		&ui,
		inspector_toggle_label,
		key=alicorn.key_string("scope-runtime-inspector-toggle"),
		style=alicorn.layout_style(.Row, height=26),
	) {
		scope_publish_command(view, .Toggle_Runtime_Inspector)
	}
	alicorn.container_end(&ui)
	if view.ui.show_runtime_inspector {
		alicorn.text(&ui, "Recent runtime activity", style=alicorn.layout_style(.Row, height=26), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM})
		activity_start := max(0, len(view.runtime_activity)-8)
		for activity in view.runtime_activity[activity_start:] {
			alicorn.text(&ui, activity.text, style=alicorn.layout_style(.Row, height=22), text_style=alicorn.Text_Style{overflow=.Ellipsis})
		}
		alicorn.text(&ui, "Retained runtime snapshot", style=alicorn.layout_style(.Row, height=26))
		inspection := view.runtime_inspection
		if len(inspection) > 24000 { inspection = fmt.tprintf("%s\n… inspection truncated for display", inspection[:24000]) }
		inspection_content_height := max(240, len(inspection)/40*20)
		alicorn.scroll_region_begin(
			&ui,
			key=alicorn.key_string("scope-runtime-inspection-scroll"),
			content_height=f32(inspection_content_height),
			line_height=20,
			style=alicorn.layout_style(grow=1, clip=true),
			label="scope-runtime-inspection-scroll",
			axes=.Vertical,
		)
		alicorn.text(&ui, inspection, style=alicorn.layout_style(.Row, grow=1), text_style=alicorn.Text_Style{overflow=.Wrap})
		alicorn.scroll_region_end(&ui)
	} else if !view.ui.has_selected_event {
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
	if view.ui.command_palette_open { scope_render_command_palette(view, &ui) }
	if view.ui.has_selected_event {
		_ = alicorn.semantic_focus_set(rt, scope_event_semantic_id(view.ui.selected_event_id), view.ui.events_scroll_node)
	} else if view.ui.has_selected_track {
		_ = alicorn.semantic_focus_set(rt, scope_track_semantic_id(view.ui.selected_track_id), view.ui.tracks_scroll_node)
	} else {
		_ = alicorn.semantic_focus_clear(rt)
	}
	alicorn.end_frame(&ui)

	view.ui.filter_node = filter_id
	if view.ui.command_palette_focus_pending && view.ui.command_palette_node != 0 {
		_ = alicorn.focus(rt, view.ui.command_palette_node)
		view.ui.command_palette_focus_pending = false
	}
	if view.ui.focus_restore_pending {
		if view.ui.focus_before_palette != 0 { _ = alicorn.focus(rt, view.ui.focus_before_palette) }
		view.ui.focus_restore_pending = false
	}
	if first_build && filter_id != 0 && !view.ui.command_palette_open {
		_ = alicorn.focus(rt, filter_id)
	}
	if selection_changed {
		alicorn.invalidate_root(rt, "scope selection changed")
	}
	return root
}
