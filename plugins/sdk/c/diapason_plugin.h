/*
 * Diapason plugin SDK for C (freestanding wasm32, no libc).
 *
 * Header-only. Build with:
 *   clang --target=wasm32 -O2 -nostdlib -ffreestanding -c plugin.c -o plugin.o
 *   wasm-ld --no-entry --export-dynamic --allow-undefined plugin.o -o plugin.wasm
 * (rust-lld -flavor wasm works as wasm-ld.)
 *
 * The ABI (see docs/PLUGINS.md):
 *   exports  memory
 *            diapason_alloc(size) -> ptr
 *            diapason_handle(ptr, len) -> ptr to [u32 little-endian length][UTF-8 JSON response]
 *   imports  diapason.host_call(ptr, len) -> length of the JSON answer
 *            diapason.host_result(dst)    copies that answer to dst
 *
 * The plugin implements:
 *   void plugin_handle(const char *method, const char *request_json, dp_buf *out);
 * and writes a JSON value into `out` (the "result"), or calls dp_error().
 */
#ifndef DIAPASON_PLUGIN_H
#define DIAPASON_PLUGIN_H

typedef unsigned int dp_u32;
typedef unsigned char dp_u8;

#define DP_IMPORT(name) __attribute__((import_module("diapason"), import_name(name)))
#define DP_EXPORT(name) __attribute__((export_name(name)))

DP_IMPORT("host_call") dp_u32 dp_host_call(const char *ptr, dp_u32 len);
DP_IMPORT("host_result") void dp_host_result(char *dst);

/* ---- memory: a bump allocator reset at every call ------------------------------------------------------------- */

extern unsigned char __heap_base;
static dp_u32 dp_heap_top = 0;

static dp_u32 dp_heap_start(void) { return ((dp_u32)&__heap_base + 15) & ~15u; }

static void *dp_alloc(dp_u32 size) {
  if (dp_heap_top == 0) dp_heap_top = dp_heap_start();
  dp_u32 ptr = (dp_heap_top + 15) & ~15u;
  dp_u32 end = ptr + size;
  dp_u32 have = __builtin_wasm_memory_size(0) * 65536u;
  if (end > have) {
    dp_u32 pages = (end - have + 65535u) / 65536u;
    if (__builtin_wasm_memory_grow(0, pages) == (dp_u32)-1) __builtin_trap();
  }
  dp_heap_top = end;
  return (void *)ptr;
}

DP_EXPORT("diapason_alloc") void *diapason_alloc(dp_u32 size) { return dp_alloc(size); }

static dp_u32 dp_strlen(const char *s) {
  dp_u32 n = 0;
  while (s[n]) n++;
  return n;
}

static int dp_streq(const char *a, const char *b) {
  while (*a && *a == *b) a++, b++;
  return *a == *b;
}

static void dp_memcpy(void *dst, const void *src, dp_u32 n) {
  char *d = dst;
  const char *s = src;
  while (n--) *d++ = *s++;
}

/* ---- a growable string -------------------------------------------------------------------------------------------- */

typedef struct {
  char *data;
  dp_u32 len, cap;
} dp_buf;

static void dp_buf_reserve(dp_buf *b, dp_u32 extra) {
  if (b->len + extra + 1 <= b->cap) return;
  dp_u32 cap = b->cap ? b->cap * 2 : 256;
  while (cap < b->len + extra + 1) cap *= 2;
  char *data = dp_alloc(cap);
  if (b->len) dp_memcpy(data, b->data, b->len);
  b->data = data;
  b->cap = cap;
}

static void dp_append_n(dp_buf *b, const char *s, dp_u32 n) {
  dp_buf_reserve(b, n);
  dp_memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
}

static void dp_append(dp_buf *b, const char *s) { dp_append_n(b, s, dp_strlen(s)); }

static void dp_append_uint(dp_buf *b, dp_u32 v) {
  char tmp[12];
  int i = 11;
  tmp[i] = 0;
  do {
    tmp[--i] = (char)('0' + v % 10);
    v /= 10;
  } while (v);
  dp_append(b, tmp + i);
}

/* Appends s as a quoted JSON string. */
static void dp_append_json_string(dp_buf *b, const char *s) {
  static const char hex[] = "0123456789abcdef";
  dp_append(b, "\"");
  for (; *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') {
      char esc[2] = {'\\', (char)c};
      dp_append_n(b, esc, 2);
    } else if (c == '\n') {
      dp_append(b, "\\n");
    } else if (c < 0x20) {
      char esc[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
      dp_append_n(b, esc, 6);
    } else {
      dp_append_n(b, (const char *)&c, 1);
    }
  }
  dp_append(b, "\"");
}

/* Appends s percent-encoded for a URL query value. */
static void dp_append_url_encoded(dp_buf *b, const char *s) {
  static const char hex[] = "0123456789ABCDEF";
  for (; *s; s++) {
    unsigned char c = (unsigned char)*s;
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' ||
        c == '.' || c == '~') {
      dp_append_n(b, (const char *)&c, 1);
    } else {
      char esc[3] = {'%', hex[c >> 4], hex[c & 15]};
      dp_append_n(b, esc, 3);
    }
  }
}

/* ---- a deliberately small JSON reader ----------------------------------------------------------------------------
 * dp_json_string finds the first `"key":"..."` anywhere in json and returns the unescaped value (\uXXXX is decoded
 * to UTF-8 for the basic plane). Enough for flat requests; real plugins can bring a proper parser. */

static const char *dp_find_key(const char *json, const char *key) {
  dp_u32 klen = dp_strlen(key);
  for (const char *p = json; *p; p++) {
    if (*p != '"') continue;
    const char *k = p + 1;
    dp_u32 i = 0;
    while (i < klen && k[i] == key[i]) i++;
    if (i != klen || k[i] != '"') continue;
    const char *q = k + i + 1;
    while (*q == ' ' || *q == '\n' || *q == '\t' || *q == '\r') q++;
    if (*q != ':') continue;
    q++;
    while (*q == ' ' || *q == '\n' || *q == '\t' || *q == '\r') q++;
    return q;
  }
  return 0;
}

static int dp_hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static char *dp_json_string(const char *json, const char *key) {
  const char *p = dp_find_key(json, key);
  if (!p || *p != '"') return 0;
  p++;
  dp_buf out = {0};
  dp_append(&out, "");
  while (*p && *p != '"') {
    if (*p != '\\') {
      dp_append_n(&out, p++, 1);
      continue;
    }
    p++;
    char c = *p++;
    switch (c) {
      case 'n': dp_append(&out, "\n"); break;
      case 't': dp_append(&out, "\t"); break;
      case 'r': dp_append(&out, "\r"); break;
      case 'b': dp_append(&out, "\b"); break;
      case 'f': dp_append(&out, "\f"); break;
      case 'u': {
        dp_u32 cp = 0;
        for (int i = 0; i < 4 && *p; i++) cp = cp * 16 + (dp_u32)dp_hexval(*p++);
        char u[3];
        if (cp < 0x80) {
          u[0] = (char)cp;
          dp_append_n(&out, u, 1);
        } else if (cp < 0x800) {
          u[0] = (char)(0xC0 | (cp >> 6));
          u[1] = (char)(0x80 | (cp & 0x3F));
          dp_append_n(&out, u, 2);
        } else {
          u[0] = (char)(0xE0 | (cp >> 12));
          u[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
          u[2] = (char)(0x80 | (cp & 0x3F));
          dp_append_n(&out, u, 3);
        }
        break;
      }
      default: dp_append_n(&out, &c, 1);
    }
  }
  return out.data;
}

/* The integer after "key": or fallback. */
static int dp_json_int(const char *json, const char *key, int fallback) {
  const char *p = dp_find_key(json, key);
  if (!p) return fallback;
  int sign = 1, v = 0, any = 0;
  if (*p == '-') sign = -1, p++;
  while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0'), any = 1;
  return any ? sign * v : fallback;
}

/* ---- host calls ------------------------------------------------------------------------------------------------- */

/* Sends a JSON request to the host and returns its JSON answer. Every answer is an object; failures carry "error". */
static char *dp_host(const char *request) {
  dp_u32 len = dp_host_call(request, dp_strlen(request));
  char *answer = dp_alloc(len + 1);
  dp_host_result(answer);
  answer[len] = 0;
  return answer;
}

static void dp_log(const char *level, const char *message) {
  dp_buf req = {0};
  dp_append(&req, "{\"op\":\"log\",\"level\":");
  dp_append_json_string(&req, level);
  dp_append(&req, ",\"message\":");
  dp_append_json_string(&req, message);
  dp_append(&req, "}");
  dp_host(req.data);
}

/* ---- the entry point ---------------------------------------------------------------------------------------------- */

static int dp_failed;
static dp_buf dp_error_message;

/* Fails the current call with message. */
static void dp_error(const char *message) {
  dp_failed = 1;
  dp_error_message = (dp_buf){0};
  dp_append(&dp_error_message, message);
}

void plugin_handle(const char *method, const char *request_json, dp_buf *out);

DP_EXPORT("diapason_handle") char *diapason_handle(const char *ptr, dp_u32 len) {
  /* The request was written into memory from diapason_alloc; copy it so it is NUL-terminated. */
  char *request = dp_alloc(len + 1);
  dp_memcpy(request, ptr, len);
  request[len] = 0;
  dp_failed = 0;

  dp_buf result = {0};
  char *method = dp_json_string(request, "method");
  plugin_handle(method ? method : "", request, &result);

  dp_buf response = {0};
  dp_append_n(&response, "\0\0\0\0", 4);
  if (dp_failed) {
    dp_append(&response, "{\"error\":");
    dp_append_json_string(&response, dp_error_message.data);
    dp_append(&response, "}");
  } else {
    dp_append(&response, "{\"result\":");
    dp_append(&response, result.len ? result.data : "null");
    dp_append(&response, "}");
  }
  dp_u32 body = response.len - 4;
  dp_u8 *head = (dp_u8 *)response.data;
  head[0] = (dp_u8)body;
  head[1] = (dp_u8)(body >> 8);
  head[2] = (dp_u8)(body >> 16);
  head[3] = (dp_u8)(body >> 24);

  char *answer = response.data;
  /* Everything allocated during this call is garbage once the host has copied the answer out; the next call starts
   * over just past it. */
  dp_heap_top = (dp_u32)(answer + response.len);
  return answer;
}

/* Start of each call: forget the previous call's allocations. Called by the host before diapason_alloc. */
DP_EXPORT("diapason_reset") void diapason_reset(void) { dp_heap_top = 0; }

#endif
