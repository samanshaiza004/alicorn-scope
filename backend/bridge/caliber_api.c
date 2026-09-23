#include "caliber_api.h"

#include <string.h>

#if defined(_WIN32)
#include <windows.h>
static HMODULE caliber_module;
#define SCOPE_LOAD_LIBRARY(path) LoadLibraryA(path)
#define SCOPE_FIND_SYMBOL(module, name) GetProcAddress(module, name)
#define SCOPE_CLOSE_LIBRARY(module) FreeLibrary(module)
#else
#include <dlfcn.h>
static void *caliber_module;
#define SCOPE_LOAD_LIBRARY(path) dlopen(path, RTLD_NOW | RTLD_LOCAL)
#define SCOPE_FIND_SYMBOL(module, name) dlsym(module, name)
#define SCOPE_CLOSE_LIBRARY(module) dlclose(module)
#endif

typedef const CaliberApiV1 *(*GetApiProc)(uint32_t);
static const CaliberApiV1 *api;
static CaliberContext *context;

const char *scope_caliber_default_library(void) {
#if defined(_WIN32)
    return "caliber_ffi.dll";
#elif defined(__APPLE__)
    return "libcaliber_ffi.dylib";
#else
    return "libcaliber_ffi.so";
#endif
}

int32_t scope_caliber_open(const char *path) {
    if (path == NULL || path[0] == '\0') return 1;
    if (caliber_module != NULL) return 0;
    caliber_module = SCOPE_LOAD_LIBRARY(path);
    if (caliber_module == NULL) return 7;
    GetApiProc get_api = (GetApiProc)SCOPE_FIND_SYMBOL(caliber_module, "caliber_get_api");
    if (get_api == NULL) {
        SCOPE_CLOSE_LIBRARY(caliber_module);
        caliber_module = NULL;
        return 7;
    }
    api = get_api(1);
    if (api == NULL || api->abi_version != 1 ||
        api->struct_size < offsetof(CaliberApiV1, context_stop_wake_waiters) + sizeof(api->context_stop_wake_waiters)) {
        api = NULL;
        SCOPE_CLOSE_LIBRARY(caliber_module);
        caliber_module = NULL;
        return 9;
    }
    return 0;
}

void scope_caliber_close_library(void) {
    if (context != NULL || caliber_module == NULL) return;
    api = NULL;
    SCOPE_CLOSE_LIBRARY(caliber_module);
    caliber_module = NULL;
}

int32_t scope_caliber_create_context(void) {
    if (api == NULL || context != NULL || api->context_create == NULL) return 1;
    CaliberContextConfig config = {0};
    config.struct_size = (uint32_t)sizeof(config);
    config.max_command_bytes = 1u << 20;
    config.max_publication_bytes = 1u << 20;
    config.max_resource_bytes = 1u << 20;
    config.max_resources = 16;
    // Caliber requires every telemetry publication to match this width. The
    // Scope protocol publishes phase/read bytes/total bytes/trace gen/query gen.
    config.telemetry_width = 5;
    config.max_pending_commands = 128;
    CaliberStatus status = api->context_create(&config, &context);
    if (status != CALIBER_OK) context = NULL;
    return status;
}

void scope_caliber_destroy_context(void) {
    if (context == NULL || api == NULL) return;
    api->context_destroy(context);
    context = NULL;
}

int32_t scope_caliber_dispatch(const uint8_t *data, size_t len) {
    if (api == NULL || context == NULL || api->context_dispatch == NULL) return 2;
    return api->context_dispatch(context, data, len);
}

int32_t scope_caliber_take_command(uint8_t *dst, size_t cap, size_t *out_len) {
    if (api == NULL || context == NULL || out_len == NULL || api->context_peek_command == NULL || api->context_take_command == NULL) return 1;
    size_t len = 0;
    CaliberStatus status = api->context_peek_command(context, &len);
    if (status != CALIBER_OK) return status;
    if (len > cap || (len != 0 && dst == NULL)) return CALIBER_BUFFER_TOO_SMALL;
    size_t copied = 0;
    status = api->context_take_command(context, dst, cap, &copied);
    if (status == CALIBER_OK) *out_len = copied;
    return status;
}

int32_t scope_caliber_publish_state(uint32_t schema, const uint8_t *data, size_t len, uint64_t *revision) {
    if (api == NULL || context == NULL || api->context_publish_state == NULL) return 2;
    return api->context_publish_state(context, schema, data, len, revision);
}

int32_t scope_caliber_read_state(uint8_t *dst, size_t cap, size_t *out_len, uint64_t *revision, uint32_t *schema) {
    if (api == NULL || context == NULL || out_len == NULL || revision == NULL || schema == NULL || api->context_read_latest_state == NULL || api->state_publication_release == NULL) return 1;
    CaliberStatePublication publication = {0};
    CaliberStatus status = api->context_read_latest_state(context, &publication);
    if (status != CALIBER_OK) return status;
    if (publication.len > cap || (publication.len != 0 && dst == NULL)) {
        api->state_publication_release(&publication);
        return CALIBER_BUFFER_TOO_SMALL;
    }
    if (publication.len != 0) memcpy(dst, publication.data, publication.len);
    *out_len = publication.len;
    *revision = publication.revision;
    *schema = publication.schema;
    api->state_publication_release(&publication);
    return CALIBER_OK;
}

int32_t scope_caliber_publish_resource(const uint8_t *data, size_t len, uint64_t *id, uint64_t *generation) {
    if (api == NULL || context == NULL || api->context_publish_resource == NULL) return 2;
    return api->context_publish_resource(context, data, len, id, generation);
}

int32_t scope_caliber_read_resource(uint64_t id, uint64_t generation, uint8_t *dst, size_t cap, size_t *out_len) {
    if (api == NULL || context == NULL || out_len == NULL || api->context_map_resource == NULL || api->resource_release == NULL) return 1;
    CaliberResourceView view = {0};
    CaliberStatus status = api->context_map_resource(context, id, generation, &view);
    if (status != CALIBER_OK) return status;
    if (view.len > cap || (view.len != 0 && dst == NULL)) {
        api->resource_release(&view);
        return CALIBER_BUFFER_TOO_SMALL;
    }
    if (view.len != 0) memcpy(dst, view.data, view.len);
    *out_len = view.len;
    api->resource_release(&view);
    return CALIBER_OK;
}

int32_t scope_caliber_release_resource(uint64_t id, uint64_t generation) {
    if (api == NULL || context == NULL || api->context_release_resource == NULL) return 2;
    return api->context_release_resource(context, id, generation);
}

int32_t scope_caliber_publish_telemetry(const size_t *values, size_t count) {
    if (api == NULL || context == NULL || api->context_publish_telemetry == NULL) return 2;
    return api->context_publish_telemetry(context, values, count);
}

int32_t scope_caliber_read_telemetry(size_t *values, size_t cap, CaliberTelemetryInfo *info) {
    if (api == NULL || context == NULL || info == NULL || api->context_read_latest_telemetry == NULL) return 1;
    return api->context_read_latest_telemetry(context, values, cap, info);
}

int32_t scope_caliber_wake_sequence(uint64_t *out_sequence) {
    if (api == NULL || context == NULL || out_sequence == NULL || api->context_wake_sequence == NULL) return 1;
    return api->context_wake_sequence(context, out_sequence);
}

int32_t scope_caliber_wait_wake(uint64_t observed, uint64_t *out_sequence) {
    if (api == NULL || context == NULL || out_sequence == NULL || api->context_wait_wake == NULL) return 1;
    return api->context_wait_wake(context, observed, out_sequence);
}

int32_t scope_caliber_stop_wake_waiters(void) {
    if (api == NULL || context == NULL || api->context_stop_wake_waiters == NULL) return 1;
    return api->context_stop_wake_waiters(context);
}
