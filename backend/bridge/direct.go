package main

import "github.com/samanshaiza004/alicorn-scope/backend/trace"

// backendDirectEventWindow is a test-only comparison path. It takes the same
// query/window and emits the same SCEV bytes as the Caliber path, but skips
// Caliber publication and mapping so foreign-boundary costs can be attributed.
func backendDirectEventWindow(traceGeneration, queryGeneration, first uint64, count uint32) ([]byte, uint64, int32) {
	if count == 0 || count > serviceMaxRows || first%serviceMaxRows != 0 {
		return nil, 0, statusInvalidArgument
	}
	serviceMu.Lock()
	s := service
	if s == nil || s.stopped || s.model == nil || s.query == nil ||
		s.traceGeneration != traceGeneration || s.queryGeneration != queryGeneration {
		serviceMu.Unlock()
		return nil, 0, statusUnavailable
	}
	query := s.query
	serviceMu.Unlock()

	page := query.Window(first, uint64(count))
	data, err := trace.EncodeEventWindow(query, page, traceGeneration, queryGeneration)
	if err != nil || len(data) > serviceMaxBytes {
		return nil, 0, statusInternal
	}
	return data, page.TotalCount, statusOK
}
