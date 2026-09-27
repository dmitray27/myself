#!/usr/bin/env bash
# Прогоняет flutter analyze + flutter test в трёх копиях приложения
# и пишет полный лог и сводку в flutter_test_report.txt (в корне репозитория).
set -u
cd "$(dirname "$0")"
REPORT=flutter_test_report.txt
: > "$REPORT"
overall=0
for d in flutter flutter_info flutter_firmware; do
  echo "=== $d ===" | tee -a "$REPORT"
  (cd "$d" && flutter pub get >/dev/null 2>&1)
  (cd "$d" && flutter analyze 2>&1) | tee -a "$REPORT"; a=${PIPESTATUS[0]}
  (cd "$d" && flutter test -r expanded 2>&1 | sed "s|$PWD/||g") | tee -a "$REPORT"; t=${PIPESTATUS[0]}
  echo "RESULT $d: analyze=$a test=$t" | tee -a "$REPORT"
  [ "$a" = 0 ] && [ "$t" = 0 ] || overall=1
  echo | tee -a "$REPORT"
done
echo "OVERALL: $([ $overall = 0 ] && echo OK || echo FAIL) ($(date -u +%Y-%m-%dT%H:%MZ), flutter $(flutter --version 2>/dev/null | head -1 | awk '{print $2}'))" | tee -a "$REPORT"
exit $overall
