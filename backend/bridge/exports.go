package main

/*
#cgo linux LDFLAGS: -ldl
#include "caliber_api.h"
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"
)

// A c-shared Go package still requires a main package entry point even though
// Alicorn loads only the exported C ABI.
func main() {}

const (
	statusOK              = int32(0)
	statusInvalidArgument = int32(1)
	statusBufferTooSmall  = int32(3)
	statusUnavailable     = int32(7)
	statusInternal        = int32(10)
	maxForeignTextBytes   = 1 << 20
)

func exportStatus(run func() int32) (result C.int32_t) {
	defer func() {
		if recover() != nil {
			result = C.int32_t(statusInternal)
		}
	}()
	return C.int32_t(run())
}

func foreignText(value *C.char, length C.size_t) (string, bool) {
	n := uint64(length)
	if n > maxForeignTextBytes || (n != 0 && value == nil) {
		return "", false
	}
	if n == 0 {
		return "", true
	}
	return C.GoStringN(value, C.int(n)), true
}

// Scope_Create loads the adjacent Caliber shared library and creates the
// single application context. It is called before Alicorn starts its host.
//
//export Scope_Create
func Scope_Create(path *C.char, length C.size_t) C.int32_t {
	return exportStatus(func() int32 {
		libraryPath, ok := foreignText(path, length)
		if !ok || libraryPath == "" {
			return statusInvalidArgument
		}
		caliberPath := C.CString(libraryPath)
		defer C.free(unsafe.Pointer(caliberPath))
		if C.scope_caliber_open(caliberPath) != C.CALIBER_OK {
			return statusUnavailable
		}
		if C.scope_caliber_create_context() != C.CALIBER_OK {
			C.scope_caliber_close_library()
			return statusUnavailable
		}
		if err := backendStart(); err != nil {
			C.scope_caliber_destroy_context()
			C.scope_caliber_close_library()
			return statusInternal
		}
		return statusOK
	})
}

//export Scope_StopWork
func Scope_StopWork() C.int32_t {
	return exportStatus(func() int32 { backendStopWork(); return statusOK })
}

//export Scope_StopWakeWaiters
func Scope_StopWakeWaiters() C.int32_t {
	return exportStatus(func() int32 { return int32(C.scope_caliber_stop_wake_waiters()) })
}

//export Scope_Destroy
func Scope_Destroy() {
	defer func() { _ = recover() }()
	backendDestroy()
	C.scope_caliber_destroy_context()
	C.scope_caliber_close_library()
}

//export Scope_WakeSequence
func Scope_WakeSequence(out *C.uint64_t) C.int32_t {
	if out == nil {
		return C.int32_t(statusInvalidArgument)
	}
	return C.int32_t(C.scope_caliber_wake_sequence((*C.uint64_t)(unsafe.Pointer(out))))
}

//export Scope_WaitWake
func Scope_WaitWake(observed C.uint64_t, out *C.uint64_t) C.int32_t {
	if out == nil {
		return C.int32_t(statusInvalidArgument)
	}
	return C.int32_t(C.scope_caliber_wait_wake(observed, (*C.uint64_t)(unsafe.Pointer(out))))
}

//export Scope_OpenTrace
func Scope_OpenTrace(path *C.char, length C.size_t) C.int32_t {
	return exportStatus(func() int32 {
		value, ok := foreignText(path, length)
		if !ok || value == "" {
			return statusInvalidArgument
		}
		return backendDispatchOpen(value)
	})
}

//export Scope_SetFilter
func Scope_SetFilter(value *C.char, length C.size_t) C.int32_t {
	return exportStatus(func() int32 {
		text, ok := foreignText(value, length)
		if !ok {
			return statusInvalidArgument
		}
		return backendDispatchFilter(text)
	})
}

//export Scope_SetTrackEnabled
func Scope_SetTrackEnabled(traceGeneration C.uint64_t, trackID C.uint64_t, enabled C.int32_t) C.int32_t {
	return exportStatus(func() int32 {
		if enabled != 0 && enabled != 1 {
			return statusInvalidArgument
		}
		return backendDispatchTrack(uint64(traceGeneration), uint64(trackID), enabled == 1)
	})
}

//export Scope_RequestTrackWindow
func Scope_RequestTrackWindow(traceGeneration C.uint64_t, queryGeneration C.uint64_t, first C.uint64_t, count C.uint32_t) C.int32_t {
	return exportStatus(func() int32 {
		if !validWindowRange(uint64(first), uint32(count)) {
			return statusInvalidArgument
		}
		return backendDispatchTrackWindow(uint64(traceGeneration), uint64(queryGeneration), uint64(first), uint32(count))
	})
}

//export Scope_SelectEvent
func Scope_SelectEvent(traceGeneration C.uint64_t, eventID C.uint64_t) C.int32_t {
	return exportStatus(func() int32 {
		return backendDispatchSelection(uint64(traceGeneration), uint64(eventID))
	})
}

//export Scope_RequestEventWindow
func Scope_RequestEventWindow(traceGeneration C.uint64_t, queryGeneration C.uint64_t, first C.uint64_t, count C.uint32_t) C.int32_t {
	return exportStatus(func() int32 {
		if !validWindowRange(uint64(first), uint32(count)) {
			return statusInvalidArgument
		}
		return backendDispatchWindow(uint64(traceGeneration), uint64(queryGeneration), uint64(first), uint32(count))
	})
}

//export Scope_RequestTimelineWindow
func Scope_RequestTimelineWindow(traceGeneration C.uint64_t, queryGeneration C.uint64_t, trackID C.uint64_t, startUS C.double, endUS C.double, resolution C.uint32_t) C.int32_t {
	return exportStatus(func() int32 {
		return backendDispatchTimeline(uint64(traceGeneration), uint64(queryGeneration), uint64(trackID), float64(startUS), float64(endUS), uint32(resolution))
	})
}

//export Scope_ReadState
func Scope_ReadState(dst *C.uint8_t, capacity C.size_t, outLength *C.size_t, revision *C.uint64_t, schema *C.uint32_t) C.int32_t {
	if outLength == nil || revision == nil || schema == nil || (capacity != 0 && dst == nil) {
		return C.int32_t(statusInvalidArgument)
	}
	return C.int32_t(C.scope_caliber_read_state(dst, capacity, outLength, revision, schema))
}

//export Scope_ReadResource
func Scope_ReadResource(id C.uint64_t, generation C.uint64_t, dst *C.uint8_t, capacity C.size_t, outLength *C.size_t) C.int32_t {
	if outLength == nil || (capacity != 0 && dst == nil) {
		return C.int32_t(statusInvalidArgument)
	}
	return C.int32_t(C.scope_caliber_read_resource(id, generation, dst, capacity, outLength))
}

//export Scope_ReadTelemetry
func Scope_ReadTelemetry(dst *C.size_t, capacity C.size_t, outCount *C.size_t, sequence *C.uint64_t) C.int32_t {
	if outCount == nil || sequence == nil || (capacity != 0 && dst == nil) {
		return C.int32_t(statusInvalidArgument)
	}
	var info C.CaliberTelemetryInfo
	status := C.scope_caliber_read_telemetry(dst, capacity, &info)
	if status == C.CALIBER_OK {
		*outCount = info.value_count
		*sequence = info.sequence
	}
	return C.int32_t(status)
}

// Scope_DirectEventWindow is a test-only baseline: it uses the active Go
// query, encodes the exact SCEV payload, then copies directly across c-shared
// ABI memory without Caliber publication/map. It is intentionally omitted
// from the normal Odin application function table.
//
//export Scope_DirectEventWindow
func Scope_DirectEventWindow(traceGeneration C.uint64_t, queryGeneration C.uint64_t, first C.uint64_t, count C.uint32_t, dst *C.uint8_t, capacity C.size_t, outLength *C.size_t, outTotal *C.uint64_t) C.int32_t {
	if outLength == nil || outTotal == nil || (capacity != 0 && dst == nil) || uint64(capacity) > maxForeignTextBytes {
		return C.int32_t(statusInvalidArgument)
	}
	data, total, status := backendDirectEventWindow(uint64(traceGeneration), uint64(queryGeneration), uint64(first), uint32(count))
	if status != statusOK {
		return C.int32_t(status)
	}
	*outLength = C.size_t(len(data))
	*outTotal = C.uint64_t(total)
	if uint64(capacity) < uint64(len(data)) {
		return C.int32_t(statusBufferTooSmall)
	}
	if len(data) > 0 {
		destination := unsafe.Slice((*byte)(unsafe.Pointer(dst)), len(data))
		copy(destination, data)
	}
	return C.int32_t(statusOK)
}
