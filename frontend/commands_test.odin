package frontend

import "core:testing"

@(test)
test_scope_command_palette_fuzzy_filter_is_stable :: proc(t: ^testing.T) {
	view := Scope_View{
		load_status=.Ready,
		event_total_count=12,
		ui=Scope_UI_State{
			has_selected_track=true,
			has_selected_event=true,
			command_palette_query="fwt",
		},
	}
	scope_prepare_command_palette(&view)
	testing.expect(t, view.ui.palette_visible_count == 1, "subsequence query should return the matching command only")
	if view.ui.palette_visible_count > 0 {
		testing.expect(t, view.ui.palette_visible_commands[0] == .Fit_Trace, "fwt should resolve to Fit Whole Trace")
	}

	view.ui.command_palette_query = "fit"
	view.ui.palette_selected_index = 99
	scope_prepare_command_palette(&view)
	testing.expect(t, view.ui.palette_visible_count == 2, "fit should expose whole-trace and selection fitting")
	testing.expect(t, view.ui.palette_selected_index == view.ui.palette_visible_count-1, "selection index should clamp after results change")
	testing.expect(t, view.ui.palette_visible_commands[0] == .Fit_Trace && view.ui.palette_visible_commands[1] == .Fit_Selection, "equal fuzzy scores should preserve registry order")
}

@(test)
test_scope_command_palette_panel_grows_then_caps_at_eight_rows :: proc(t: ^testing.T) {
	base_height := scope_command_palette_panel_height(0)
	testing.expect(t, base_height == 104, "an empty result set should leave room for the input and one empty-state row")
	testing.expect(t, scope_command_palette_panel_height(2) == 138, "the palette panel should grow to fit each additional result")
	testing.expect(t, scope_command_palette_panel_height(8) == 342, "eight visible results should fit in the capped panel")
	testing.expect(t, scope_command_palette_panel_height(9) == 342, "additional results should scroll without growing the panel")
}

@(test)
test_scope_command_availability_tracks_application_state :: proc(t: ^testing.T) {
	view := Scope_View{load_status=.Ready}
	testing.expect(t, scope_command_enabled(view, .Fit_Trace), "fit trace requires a loaded trace")
	testing.expect(t, !scope_command_enabled(view, .Fit_Selection), "fit selection remains disabled without selection")
	testing.expect(t, scope_command_enabled(view, .Toggle_Command_Palette), "palette is always available")
	view.ui.has_selected_event = true
	testing.expect(t, scope_command_enabled(view, .Clear_Selection), "clear selection is enabled when an event is selected")
	testing.expect(t, u32(Scope_Command_ID.Open_Trace) == 1 && u32(Scope_Command_ID.Clear_Selection) == 9, "public command IDs stay stable for native menu transport")
	fit := scope_command_descriptors(view)[3]
	testing.expect(t, fit.id == .Fit_Selection && fit.name == "scope.fit_selection" && fit.label == "Fit Selection",
		"Scope should publish stable machine identity separately from its readable action label")
	fit_action := scope_action_id(fit.id)
	testing.expect(t, u32(fit_action) == u32(fit.id) && scope_command_from_action_id(fit_action) == fit.id,
		"UI, shortcut, palette, and native menu projections should round-trip through one Alicorn action identity")
	view.ui.show_runtime_inspector = true
	testing.expect(t, scope_command_checked(view, .Toggle_Runtime_Inspector),
		"checked action state should follow explicit Scope UI state")
}

@(test)
test_scope_event_window_slides_to_cover_a_virtual_viewport_at_page_boundary :: proc(t: ^testing.T) {
	total_rows := 45_494
	visible_first := 40_440
	visible_end := 40_456
	first_missing := 40_448
	old_page_first := 39_936
	requested_first := scope_window_first_row(total_rows, first_missing)

	// The old fixed page ended at row 40,448, splitting this visible range in
	// half. The sliding 512-row request must contain the complete viewport.
	testing.expect(t, requested_first <= visible_first, "sliding event window should include rows before the page edge")
	testing.expect(t, requested_first+SCOPE_EVENT_WINDOW_SIZE >= visible_end, "sliding event window should include rows after the page edge")
	testing.expect(t, requested_first%SCOPE_EVENT_WINDOW_SIZE != 0, "a boundary-straddling viewport should not snap back to the old page grid")

	old_page := Scope_View{
		event_total_count=total_rows,
		event_first_row=old_page_first,
		events=make([]Scope_Event_Row, SCOPE_EVENT_WINDOW_SIZE),
	}
	testing.expect(t, scope_event_cache_index(old_page, visible_first) >= 0, "the first visible rows should be in the old page")
	testing.expect(t, scope_event_cache_index(old_page, first_missing) < 0, "the visible range should cross the old page edge")
	testing.expect(t, scope_request_event_window(&old_page, first_missing), "the first missing visible row should request a replacement window")
	old_page.event_first_row = old_page.interaction.first_row
	testing.expect(t, old_page.event_first_row == requested_first, "the backend request should use the sliding-window start")
	for row in visible_first..<visible_end {
		testing.expect(t, scope_event_cache_index(old_page, row) >= 0, "one replacement window should cover every row in the visible range")
	}
	delete(old_page.events)
}

@(test)
test_scope_event_window_request_deduplicates_targets_inside_pending_window :: proc(t: ^testing.T) {
	view := Scope_View{event_total_count=45_494}
	testing.expect(t, scope_request_event_window(&view, 40_448), "first missing row should publish a sliding window request")
	requested_first := view.interaction.first_row
	testing.expect(t, requested_first == scope_window_first_row(view.event_total_count, 40_448), "interaction should carry the calculated sliding-window start")
	sequence := view.interaction.sequence
	testing.expect(t, !scope_request_event_window(&view, 40_449), "another row already covered by the pending window should not submit a second request")
	testing.expect(t, view.interaction.sequence == sequence, "deduplicated rows must not publish more backend work")
	testing.expect(t, scope_request_event_window(&view, 41_000), "a target outside the pending window should replace it with a covering request")
}

@(test)
test_scope_event_window_start_clamps_at_both_trace_edges :: proc(t: ^testing.T) {
	testing.expect(t, scope_window_first_row(40, 5) == 0, "short traces should fit entirely in one window")
	near_end := scope_window_first_row(45_494, 45_493)
	testing.expect(t, near_end == 44_982, "a request near the final row should slide back to the final full window")
	testing.expect(t, near_end+SCOPE_EVENT_WINDOW_SIZE >= 45_494, "the final event must remain inside the requested window")
}

@(test)
test_scope_track_window_uses_sliding_ranges_and_deduplicates :: proc(t: ^testing.T) {
	view := Scope_View{track_total_count=1_024}
	testing.expect(t, scope_request_track_window(&view, 512), "track cache boundary should publish a sliding request")
	first := view.interaction.first_row
	testing.expect(t, first == 256, "track request should center around the missing row")
	sequence := view.interaction.sequence
	testing.expect(t, !scope_request_track_window(&view, 513), "pending track window should cover nearby rows without another request")
	testing.expect(t, view.interaction.sequence == sequence, "covered track targets must not publish extra requests")
}
