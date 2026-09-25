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
