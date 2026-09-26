package frontend

import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_scope_timeline_ruler_does_not_emit_duplicate_unkeyed_siblings :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 900, 700})
	view := Scope_View{
		load_status=.Ready,
		trace_start_us=0,
		trace_end_us=100_000,
		timeline_start_us=0,
		timeline_end_us=100_000,
	}
	_ = scope_render(&view, &rt)
	inspection := alicorn.inspect(&rt)
	testing.expect(t, !strings.contains(inspection, "HARD ERROR:"), "building the full Scope view should not encounter duplicate unkeyed siblings")
	delete(inspection)
	alicorn.destroy_runtime(&rt)
}
