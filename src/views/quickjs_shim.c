#include "quickjs.h"
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

JSRuntime *zx_new_rt(void) { return JS_NewRuntime(); }
void zx_free_rt(JSRuntime *rt) { JS_FreeRuntime(rt); }
JSContext *zx_new_ctx(JSRuntime *rt) { return JS_NewContext(rt); }
void zx_free_ctx(JSContext *ctx) { JS_FreeContext(ctx); }
void zx_mem_limit(JSRuntime *rt, size_t n) { JS_SetMemoryLimit(rt, n); }

static uint64_t zx_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000ULL);
}

static int zx_interrupt_cb(JSContext *ctx, void *opaque) {
    (void)ctx;
    const uint64_t *deadline_ms = (const uint64_t *)opaque;
    if (deadline_ms == NULL || *deadline_ms == 0) return 0;
    return zx_now_ms() >= *deadline_ms ? 1 : 0;
}

/* Evaluate a global script with an optional wall-clock timeout (0 = no limit)
 * and return its string result, or NULL on exception / timeout. */
const char *zx_eval_timeout(JSRuntime *rt, JSContext *ctx, const char *code, uint64_t timeout_ms) {
    uint64_t deadline_ms = 0;
    if (timeout_ms > 0) {
        deadline_ms = zx_now_ms() + timeout_ms;
        JS_SetInterruptHandler(rt, zx_interrupt_cb, &deadline_ms);
    }

    JSValue v = JS_Eval(ctx, code, strlen(code), "<zouch-view>", JS_EVAL_TYPE_GLOBAL);

    if (timeout_ms > 0) {
        JS_SetInterruptHandler(rt, NULL, NULL);
    }

    if (JS_IsException(v)) {
        JSValue exc = JS_GetException(ctx);
        JS_FreeValue(ctx, exc);
        JS_FreeValue(ctx, v);
        return NULL;
    }
    const char *s = JS_ToCString(ctx, v);
    JS_FreeValue(ctx, v);
    return s;
}

/* Evaluate a global script and return its string result, or NULL on exception. */
const char *zx_eval(JSContext *ctx, const char *code) {
    return zx_eval_timeout(JS_GetRuntime(ctx), ctx, code, 0);
}

void zx_free_str(JSContext *ctx, const char *s) {
    if (s != NULL) JS_FreeCString(ctx, s);
}
