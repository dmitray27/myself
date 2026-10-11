/* Host-тест эфирного кадра n:<имя>:<текст>. Запуск: ./run_tests.sh */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../main/air_frame.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static void test_build_basic(void)
{
    char out[128];
    size_t n = air_frame_build(out, sizeof(out), "Дима", "Привет");
    CHECK(n == strlen("n:Дима:Привет"));
    CHECK(strcmp(out, "n:Дима:Привет") == 0);
}

static void test_build_rejects_bad_name_and_empty_text(void)
{
    char out[128];
    CHECK(air_frame_build(out, sizeof(out), "", "x") == 0);
    CHECK(air_frame_build(out, sizeof(out), "a:b", "x") == 0);
    CHECK(air_frame_build(out, sizeof(out), "System", "x") == 0);
    CHECK(air_frame_build(out, sizeof(out), "Дима", "") == 0);
    char longname[AIR_NAME_MAX + 2];
    memset(longname, 'a', sizeof(longname) - 1);
    longname[sizeof(longname) - 1] = '\0';
    CHECK(air_frame_build(out, sizeof(out), longname, "x") == 0);
    /* ровно по лимиту: 31 байт имени */
    longname[AIR_NAME_MAX - 1] = '\0';
    CHECK(air_frame_build(out, sizeof(out), longname, "x") > 0);
}

static void test_build_respects_capacity(void)
{
    char out[8];
    CHECK(air_frame_build(out, sizeof(out), "ab", "cd") == 7);  /* "n:ab:cd" + '\0' */
    CHECK(air_frame_build(out, 7, "ab", "cd") == 0);
}

static void test_parse_roundtrip(void)
{
    char out[128];
    size_t n = air_frame_build(out, sizeof(out), "Дима", "Привет: как дела");
    char name[AIR_NAME_MAX];
    const char *text; size_t text_len;
    CHECK(air_frame_parse(out, n, name, sizeof(name), &text, &text_len));
    CHECK(strcmp(name, "Дима") == 0);
    CHECK(text_len == strlen("Привет: как дела"));
    CHECK(memcmp(text, "Привет: как дела", text_len) == 0);
}

static void test_parse_legacy_falls_back_to_remote(void)
{
    char name[AIR_NAME_MAX];
    const char *text; size_t text_len;
    const char *legacy = "Просто текст: с двоеточием";
    CHECK(!air_frame_parse(legacy, strlen(legacy), name, sizeof(name), &text, &text_len));
    CHECK(strcmp(name, AIR_FALLBACK_NAME) == 0);
    CHECK(text == legacy && text_len == strlen(legacy));
}

static void test_parse_garbage_prefix(void)
{
    char name[AIR_NAME_MAX];
    const char *text; size_t text_len;
    const char *cases[] = { "n:", "n:Дима", "n::текст", "n:Дима:", "n:System:x", "n:a\nb:x" };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        CHECK(!air_frame_parse(cases[i], strlen(cases[i]), name, sizeof(name), &text, &text_len));
        CHECK(strcmp(name, AIR_FALLBACK_NAME) == 0);
        CHECK(text_len == strlen(cases[i]));
    }
}

static void test_parse_too_long_name(void)
{
    char buf[80] = "n:";
    memset(buf + 2, 'a', AIR_NAME_MAX);
    strcpy(buf + 2 + AIR_NAME_MAX, ":x");
    char name[AIR_NAME_MAX];
    const char *text; size_t text_len;
    CHECK(!air_frame_parse(buf, strlen(buf), name, sizeof(name), &text, &text_len));
    CHECK(strcmp(name, AIR_FALLBACK_NAME) == 0);
}

static void test_parse_embedded_nul_in_text(void)
{
    char buf[] = "n:Дима:a\0b";
    size_t len = sizeof(buf) - 1;
    char name[AIR_NAME_MAX];
    const char *text; size_t text_len;
    CHECK(air_frame_parse(buf, len, name, sizeof(name), &text, &text_len));
    CHECK(text_len == 3 && text[1] == '\0');
}

int main(void)
{
    test_build_basic();
    test_build_rejects_bad_name_and_empty_text();
    test_build_respects_capacity();
    test_parse_roundtrip();
    test_parse_legacy_falls_back_to_remote();
    test_parse_garbage_prefix();
    test_parse_too_long_name();
    test_parse_embedded_nul_in_text();
    if (failures) {
        printf("air_frame_test: %d FAILED\n", failures);
        return 1;
    }
    printf("air_frame_test: all 8 tests passed\n");
    return 0;
}
