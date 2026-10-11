#!/usr/bin/env bash
# Host-тесты прошивки flutter_color (без ESP-IDF и железа): gcc + запуск.
set -euo pipefail
cd "$(dirname "$0")"
gcc -std=c11 -Wall -Wextra -Werror -o /tmp/air_frame_test ../main/air_frame.c air_frame_test.c
/tmp/air_frame_test
