#include "quickjs.h"
#include "libregexp.h"
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static pthread_mutex_t g_re_mutex = PTHREAD_MUTEX_INITIALIZER;
static JSRuntime *g_re_rt = NULL;
static JSContext *g_re_ctx = NULL;

#define RE_CACHE_SIZE 64
#define RE_CACHE_MAX_PAT 1024

typedef struct {
    char *pat;
    size_t plen;
    int flags;
    uint8_t *bc;
    uint64_t last_used;
} ReCacheEntry;

static ReCacheEntry g_re_cache[RE_CACHE_SIZE];
static uint64_t g_re_clock = 0;

static uint64_t re_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000ULL);
}

static int re_interrupt_cb(JSContext *ctx, void *opaque) {
    (void)ctx;
    const uint64_t *deadline_ms = (const uint64_t *)opaque;
    if (deadline_ms == NULL || *deadline_ms == 0) return 0;
    return re_now_ms() >= *deadline_ms ? 1 : 0;
}

static int ensure_re_ctx(void) {
    if (g_re_ctx != NULL) return 0;
    g_re_rt = JS_NewRuntime();
    if (g_re_rt == NULL) return -1;
    JS_SetMemoryLimit(g_re_rt, 16 * 1024 * 1024);
    g_re_ctx = JS_NewContext(g_re_rt);
    if (g_re_ctx == NULL) {
        JS_FreeRuntime(g_re_rt);
        g_re_rt = NULL;
        return -1;
    }
    return 0;
}

/* Decode UTF-8 bytes into UTF-16 code units. Returns number of uint16_t units,
 * or -1 on invalid UTF-8 or allocation failure. */
static int utf8_to_utf16(const unsigned char *s, size_t len, uint16_t **out) {
    uint16_t *buf = malloc((len + 1) * sizeof(uint16_t));
    if (buf == NULL) return -1;
    size_t i = 0;
    size_t n = 0;
    while (i < len) {
        uint32_t cp;
        unsigned char c = s[i];
        if (c < 0x80) {
            cp = c;
            i += 1;
        } else if ((c & 0xE0) == 0xC0 && i + 1 < len && (s[i + 1] & 0xC0) == 0x80) {
            cp = ((uint32_t)(c & 0x1F) << 6) | (s[i + 1] & 0x3F);
            if (cp < 0x80) { free(buf); return -1; }
            i += 2;
        } else if ((c & 0xF0) == 0xE0 && i + 2 < len &&
                   (s[i + 1] & 0xC0) == 0x80 && (s[i + 2] & 0xC0) == 0x80) {
            cp = ((uint32_t)(c & 0x0F) << 12) | ((uint32_t)(s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F);
            if (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF)) { free(buf); return -1; }
            i += 3;
        } else if ((c & 0xF8) == 0xF0 && i + 3 < len &&
                   (s[i + 1] & 0xC0) == 0x80 && (s[i + 2] & 0xC0) == 0x80 && (s[i + 3] & 0xC0) == 0x80) {
            cp = ((uint32_t)(c & 0x07) << 18) | ((uint32_t)(s[i + 1] & 0x3F) << 12) |
                 ((uint32_t)(s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F);
            if (cp < 0x10000 || cp > 0x10FFFF) { free(buf); return -1; }
            i += 4;
        } else {
            free(buf);
            return -1;
        }
        if (cp <= 0xFFFF) {
            buf[n++] = (uint16_t)cp;
        } else {
            cp -= 0x10000;
            buf[n++] = (uint16_t)(0xD800 + (cp >> 10));
            buf[n++] = (uint16_t)(0xDC00 + (cp & 0x3FF));
        }
    }
    *out = buf;
    return (int)n;
}

/* Length-aware PCRE-subset regex matcher backed by QuickJS libregexp.
 * Supports \d, \w, \s, \D, \W, \S, non-greedy quantifiers (*?, +?, ??),
 * lookaheads/lookbehinds, NUL bytes, and leading inline flags (?i), (?m), (?s), (?u).
 * Returns 1 for a match, 0 for no match, and -1 for an invalid pattern or error. */
int zouch_regex_match(const unsigned char *pattern, size_t plen,
                      const unsigned char *text, size_t tlen) {
    if (tlen > (size_t)INT_MAX) return -1;

    int re_flags = 0;
    const unsigned char *pat = pattern != NULL ? pattern : (const unsigned char *)"";
    while (plen >= 4 && pat[0] == '(' && pat[1] == '?') {
        size_t j = 2;
        int group_flags = 0;
        int valid = 1;
        while (j < plen && pat[j] != ')') {
            switch (pat[j]) {
                case 'i': group_flags |= LRE_FLAG_IGNORECASE; break;
                case 'm': group_flags |= LRE_FLAG_MULTILINE; break;
                case 's': group_flags |= LRE_FLAG_DOTALL; break;
                case 'u': group_flags |= LRE_FLAG_UNICODE; break;
                default: valid = 0; break;
            }
            if (!valid) break;
            j++;
        }
        if (!valid || j == 2 || j >= plen || pat[j] != ')') break;
        re_flags |= group_flags;
        pat += j + 1;
        plen -= j + 1;
    }

    int is_ascii = 1;
    for (size_t i = 0; i < tlen; i++) {
        if (text[i] >= 0x80) {
            is_ascii = 0;
            break;
        }
    }

    uint16_t *utf16_buf = NULL;
    const uint8_t *cbuf = text != NULL ? (const uint8_t *)text : (const uint8_t *)"";
    int clen = (int)tlen;
    int cbuf_type = 0;
    if (!is_ascii) {
        int u16_len = utf8_to_utf16(text, tlen, &utf16_buf);
        if (u16_len >= 0) {
            cbuf = (const uint8_t *)utf16_buf;
            clen = u16_len;
            cbuf_type = 1;
        }
    }

    pthread_mutex_lock(&g_re_mutex);
    if (ensure_re_ctx() != 0) {
        pthread_mutex_unlock(&g_re_mutex);
        free(utf16_buf);
        return -1;
    }
    JS_UpdateStackTop(g_re_rt);

    uint8_t *bc_buf = NULL;
    int cached = 0;
    for (int ci = 0; ci < RE_CACHE_SIZE; ci++) {
        ReCacheEntry *e = &g_re_cache[ci];
        if (e->bc != NULL && e->flags == re_flags && e->plen == plen &&
            (plen == 0 || memcmp(e->pat, pat, plen) == 0)) {
            e->last_used = ++g_re_clock;
            bc_buf = e->bc;
            cached = 1;
            break;
        }
    }

    if (bc_buf == NULL) {
        char stack_pat[512];
        char *pat_z = stack_pat;
        if (plen + 1 > sizeof(stack_pat)) {
            pat_z = malloc(plen + 1);
            if (pat_z == NULL) {
                pthread_mutex_unlock(&g_re_mutex);
                free(utf16_buf);
                return -1;
            }
        }
        if (plen > 0) memcpy(pat_z, pat, plen);
        pat_z[plen] = '\0';

        int bc_len = 0;
        char err_msg[128];
        bc_buf = lre_compile(&bc_len, err_msg, sizeof(err_msg),
                             pat_z, plen, re_flags, g_re_ctx);
        if (pat_z != stack_pat) free(pat_z);
        if (bc_buf == NULL) {
            pthread_mutex_unlock(&g_re_mutex);
            free(utf16_buf);
            return -1;
        }

        if (plen <= RE_CACHE_MAX_PAT) {
            int victim = 0;
            uint64_t best = UINT64_MAX;
            for (int ci = 0; ci < RE_CACHE_SIZE; ci++) {
                if (g_re_cache[ci].bc == NULL) {
                    victim = ci;
                    break;
                }
                if (g_re_cache[ci].last_used < best) {
                    best = g_re_cache[ci].last_used;
                    victim = ci;
                }
            }
            char *pat_copy = malloc(plen + 1);
            if (pat_copy != NULL) {
                if (plen > 0) memcpy(pat_copy, pat, plen);
                pat_copy[plen] = '\0';
                ReCacheEntry *slot = &g_re_cache[victim];
                if (slot->bc != NULL) {
                    free(slot->pat);
                    lre_realloc(g_re_ctx, slot->bc, 0);
                }
                slot->pat = pat_copy;
                slot->plen = plen;
                slot->flags = re_flags;
                slot->bc = bc_buf;
                slot->last_used = ++g_re_clock;
                cached = 1;
            }
        }
    }

    int cap_count = lre_get_capture_count(bc_buf);
    uint8_t *stack_caps[64];
    uint8_t **capture = stack_caps;
    if (cap_count > 32) {
        capture = calloc((size_t)cap_count * 2, sizeof(uint8_t *));
        if (capture == NULL) {
            if (!cached) lre_realloc(g_re_ctx, bc_buf, 0);
            pthread_mutex_unlock(&g_re_mutex);
            free(utf16_buf);
            return -1;
        }
    }

    uint64_t deadline_ms = re_now_ms() + 1000ULL;
    JS_SetInterruptHandler(g_re_rt, re_interrupt_cb, &deadline_ms);
    int rc = lre_exec(capture, bc_buf, cbuf, 0, clen, cbuf_type, g_re_ctx);
    JS_SetInterruptHandler(g_re_rt, NULL, NULL);

    if (capture != stack_caps) free(capture);
    if (!cached) lre_realloc(g_re_ctx, bc_buf, 0);
    pthread_mutex_unlock(&g_re_mutex);
    free(utf16_buf);

    if (rc == 1) return 1;
    if (rc == 0) return 0;
    return -1;
}
