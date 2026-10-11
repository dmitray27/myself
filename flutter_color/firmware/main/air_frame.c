#include "air_frame.h"

#include <string.h>

static bool name_ok(const char *s, size_t len)
{
    if (len == 0 || len >= AIR_NAME_MAX) {
        return false;
    }
    if (len >= 6 && memcmp(s, "System", 6) == 0) {
        return false;
    }
    for (size_t i = 0; i < len; i++) {
        if (s[i] == ':' || s[i] == '\0' || s[i] == '\n' || s[i] == '\r') {
            return false;
        }
    }
    return true;
}

size_t air_frame_build(char *out, size_t cap, const char *from, const char *text)
{
    if (!out || !from || !text) {
        return 0;
    }
    size_t from_len = strlen(from);
    size_t text_len = strlen(text);
    if (!name_ok(from, from_len) || text_len == 0) {
        return 0;
    }
    size_t total = AIR_NAME_PREFIX_LEN + from_len + 1 + text_len;
    if (total + 1 > cap) {
        return 0;
    }
    memcpy(out, AIR_NAME_PREFIX, AIR_NAME_PREFIX_LEN);
    memcpy(out + AIR_NAME_PREFIX_LEN, from, from_len);
    out[AIR_NAME_PREFIX_LEN + from_len] = ':';
    memcpy(out + AIR_NAME_PREFIX_LEN + from_len + 1, text, text_len);
    out[total] = '\0';
    return total;
}

bool air_frame_parse(const char *buf, size_t len, char *name, size_t name_cap,
                     const char **text, size_t *text_len)
{
    *text = buf;
    *text_len = len;
    strncpy(name, AIR_FALLBACK_NAME, name_cap);
    name[name_cap - 1] = '\0';

    if (len <= AIR_NAME_PREFIX_LEN ||
        memcmp(buf, AIR_NAME_PREFIX, AIR_NAME_PREFIX_LEN) != 0) {
        return false;
    }
    const char *start = buf + AIR_NAME_PREFIX_LEN;
    size_t rest = len - AIR_NAME_PREFIX_LEN;
    const char *colon = memchr(start, ':', rest);
    if (!colon) {
        return false;
    }
    size_t from_len = (size_t)(colon - start);
    size_t body_len = rest - from_len - 1;
    if (body_len == 0 || from_len + 1 > name_cap || !name_ok(start, from_len)) {
        return false;
    }
    memcpy(name, start, from_len);
    name[from_len] = '\0';
    *text = colon + 1;
    *text_len = body_len;
    return true;
}
