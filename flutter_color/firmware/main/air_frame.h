#pragma once
#include <stdbool.h>
#include <stddef.h>

/* Кадр, уходящий в эфир: "n:<имя>:<текст>". Приёмная плата показывает
   абонента под его именем, а не "Remote". Чистый C без ESP-зависимостей,
   проверяется host-тестом test_host/air_frame_test.c. */

#define AIR_NAME_PREFIX     "n:"
#define AIR_NAME_PREFIX_LEN 2
#define AIR_NAME_MAX        32   /* как WS_NAME_MAX, с завершающим '\0' */
#define AIR_FALLBACK_NAME   "Remote"

/* Собирает кадр в out (cap байт вместе с '\0'). Возвращает длину без '\0'
   или 0, если имя недопустимо или не хватает места. */
size_t air_frame_build(char *out, size_t cap, const char *from, const char *text);

/* Разбирает принятый из эфира payload (ровно len байт, может содержать '\0').
   Если есть префикс и допустимое имя — name = имя, text/text_len = остаток;
   иначе (старая прошивка, искажённый кадр) name = "Remote", текст целиком.
   Возвращает true, если имя взято из кадра. */
bool air_frame_parse(const char *buf, size_t len, char *name, size_t name_cap,
                     const char **text, size_t *text_len);
