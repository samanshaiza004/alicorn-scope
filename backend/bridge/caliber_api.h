#ifndef ALICORN_SCOPE_CALIBER_API_H
#define ALICORN_SCOPE_CALIBER_API_H

#include <stddef.h>
#include <stdint.h>

typedef struct CaliberContext CaliberContext;
typedef int32_t CaliberStatus;

enum {
    CALIBER_OK = 0,
    CALIBER_BUFFER_TOO_SMALL = 3,
    CALIBER_STOPPED = 11
};

typedef struct {
    uint64_t revision;
    uint32_t schema;
    uint32_t reserved;
    const uint8_t *data;
    size_t len;
    void *lease;
} CaliberStatePublication;

typedef struct {
    uint64_t resource_id;
    uint64_t generation;
    const uint8_t *data;
    size_t len;
    void *lease;
} CaliberResourceView;

typedef struct {
    uint64_t sequence;
    uint32_t schema;
    uint32_t reserved;
    size_t value_count;
    size_t value_size;
} CaliberTelemetryInfo;

typedef struct {
    uint32_t struct_size;
    size_t max_command_bytes;
    size_t max_publication_bytes;
    size_t max_resource_bytes;
    size_t max_resources;
    size_t telemetry_width;
    size_t max_pending_commands;
} CaliberContextConfig;

typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    CaliberStatus (*context_create)(const CaliberContextConfig *, CaliberContext **);
    void (*context_destroy)(CaliberContext *);
    CaliberStatus (*context_dispatch)(const CaliberContext *, const uint8_t *, size_t);
    CaliberStatus (*context_peek_command)(const CaliberContext *, size_t *);
    CaliberStatus (*context_take_command)(const CaliberContext *, uint8_t *, size_t, size_t *);
    CaliberStatus (*context_publish_state)(const CaliberContext *, uint32_t, const uint8_t *, size_t, uint64_t *);
    CaliberStatus (*context_read_latest_state)(const CaliberContext *, CaliberStatePublication *);
    void (*state_publication_release)(CaliberStatePublication *);
    CaliberStatus (*context_map_resource)(const CaliberContext *, uint64_t, uint64_t, CaliberResourceView *);
    void (*resource_release)(CaliberResourceView *);
    CaliberStatus (*context_publish_resource)(const CaliberContext *, const uint8_t *, size_t, uint64_t *, uint64_t *);
    CaliberStatus (*context_release_resource)(const CaliberContext *, uint64_t, uint64_t);
    CaliberStatus (*context_publish_telemetry)(const CaliberContext *, const size_t *, size_t);
    CaliberStatus (*context_read_latest_telemetry)(const CaliberContext *, size_t *, size_t, CaliberTelemetryInfo *);
    CaliberStatus (*context_wake_sequence)(const CaliberContext *, uint64_t *);
    CaliberStatus (*context_wait_wake)(const CaliberContext *, uint64_t, uint64_t *);
    CaliberStatus (*context_stop_wake_waiters)(const CaliberContext *);
} CaliberApiV1;

const char *scope_caliber_default_library(void);
int32_t scope_caliber_open(const char *path);
void scope_caliber_close_library(void);
int32_t scope_caliber_create_context(void);
void scope_caliber_destroy_context(void);
int32_t scope_caliber_dispatch(const uint8_t *data, size_t len);
int32_t scope_caliber_take_command(uint8_t *dst, size_t cap, size_t *out_len);
int32_t scope_caliber_publish_state(uint32_t schema, const uint8_t *data, size_t len, uint64_t *revision);
int32_t scope_caliber_read_state(uint8_t *dst, size_t cap, size_t *out_len, uint64_t *revision, uint32_t *schema);
int32_t scope_caliber_publish_resource(const uint8_t *data, size_t len, uint64_t *id, uint64_t *generation);
int32_t scope_caliber_read_resource(uint64_t id, uint64_t generation, uint8_t *dst, size_t cap, size_t *out_len);
int32_t scope_caliber_release_resource(uint64_t id, uint64_t generation);
int32_t scope_caliber_publish_telemetry(const size_t *values, size_t count);
int32_t scope_caliber_read_telemetry(size_t *values, size_t cap, CaliberTelemetryInfo *info);
int32_t scope_caliber_wake_sequence(uint64_t *out_sequence);
int32_t scope_caliber_wait_wake(uint64_t observed, uint64_t *out_sequence);
int32_t scope_caliber_stop_wake_waiters(void);

#endif
