#ifndef ALICORN_SCOPE_BACKEND_H
#define ALICORN_SCOPE_BACKEND_H

#include <caliber.h>

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
