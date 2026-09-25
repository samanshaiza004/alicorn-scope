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
test_scope_command_availability_tracks_application_state :: proc(t: ^testing.T) {
	view := Scope_View{load_status=.Ready}
	testing.expect(t, scope_command_enabled(view, .Fit_Trace), "fit trace requires a loaded trace")
	testing.expect(t, !scope_command_enabled(view, .Fit_Selection), "fit selection remains disabled without selection")
	testing.expect(t, scope_command_enabled(view, .Toggle_Command_Palette), "palette is always available")
	view.ui.has_selected_event = true
	testing.expect(t, scope_command_enabled(view, .Clear_Selection), "clear selection is enabled when an event is selected")
	testing.expect(t, u32(Scope_Command_ID.Open_Trace) == 1 && u32(Scope_Command_ID.Clear_Selection) == 9, "public command IDs stay stable for native menu transport")
}
