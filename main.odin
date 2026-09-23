package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

main :: proc() {
	trace_path := ""
	smoke := false
	for argument in os.args[1:] {
		if argument == "--smoke" { smoke = true; continue }
		if argument == "--help" || argument == "-h" {
			fmt.println("Usage: alicorn-scope [--smoke] [trace.json]")
			return
		}
		if len(argument) > 0 && argument[0] != '-' {
			trace_path = argument
			break
		}
	}

	executable_path := ""
	if len(os.args) > 0 { executable_path = os.args[0] }
	backend_path := scope_adjacent_path(executable_path, scope_backend_library_name())
	backend, loaded := scope_open_backend(backend_path)
	if !loaded {
		fmt.eprintln("alicorn-scope: could not load Go backend:", backend_path, dynlib.last_error())
		os.exit(1)
	}

	caliber_path := scope_adjacent_path(executable_path, scope_caliber_library_name())
	caliber_path_c, path_error := strings.clone_to_cstring(caliber_path, allocator=context.temp_allocator)
	if path_error != nil {
		fmt.eprintln("alicorn-scope: could not allocate Caliber library path")
		_ = dynlib.unload_library(backend._library)
		os.exit(1)
	}
	if backend.create(caliber_path_c, uintptr(len(caliber_path))) != Caliber_Status_OK {
		fmt.eprintln("alicorn-scope: could not initialize Caliber/backend; expected:", caliber_path)
		_ = dynlib.unload_library(backend._library)
		os.exit(1)
	}

	app := scope_app_new(backend, trace_path)
	app.backend_created = true
	scope_app_startup_sync(app)
	scope_app_run(app, smoke)
	fmt.println(
		"alicorn-scope PASS",
		"builds", app.build_count,
		"wakes", app.wake_count,
		"resource_copies", app.resource_copy_count,
		"events_cached", len(app.events),
	)
	scope_app_destroy(app)
	_ = dynlib.unload_library(backend._library)
}
