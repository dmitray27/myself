# UI-тест в эмуляторе Android (flutter_color, flutter_ack)

Дата: 2026-10-01. Коммит: f57a838. Эмулятор Android 14 (AVD), debug-APK.
Плата заменена mock-сервером `ws_test_stub.py mock` (адрес 192.168.4.1 проброшен
в эмулятор через `adb reverse`); кадры `status:` и эхо подавались вручную.
**Это проверка UI и разбора протокола, не доставки по эфиру на реальных ESP32.**

## flutter_ack

| Сценарий | Результат | Скриншот |
|---|---|---|
| Палитра: 9 кружков (7 радуги + белый + чёрный) | OK | — |
| Белый: шапка ровно #FFFFFF, чёрные текст/иконки, светлая тема | OK | `ui_test/screenshots/ack_white_appbar.png` |
| Чёрный: шапка ровно #000000, белые текст/иконки, тёмная тема | OK | `ui_test/screenshots/ack_black_appbar.png` |
| Отправка → часы | OK | `ui_test/screenshots/ack-sending-clock.png` |
| Эхо `<имя>:<id>:<текст>` → песочные часы | OK | `ui_test/screenshots/ack-echo-hourglass.png` |
| `status:<id>:aired` → одна галочка | OK | `ui_test/screenshots/ack-aired-one-check.png` |
| `status:<id>:delivered:8045` → две зелёные галочки, долгое нажатие «Принято абонентом 8045» | OK | `ui_test/screenshots/ack-delivered-tooltip.png` |
| `status:<id>:noack` второго сообщения → оранжевое перечёркнутое ухо; первое остаётся доставленным | OK | `ui_test/screenshots/ack-noack-orange.png` |

Падений нет.

## flutter_color

Проверено до прерывания сессии (APK до f57a838): палитра 9 цветов, переключение
белый/чёрный и контраст иконок — OK; найден оттенок шапки (#EEF5F6 / #090E0F
вместо чистых) из-за Material3 surface tint — исправлено в f57a838
(`surfaceTintColor: Colors.transparent`), подтверждено на flutter_ack (тот же код).
Не проверено: сохранение цвета после перезапуска приложения (есть unit-тест
`app_color_test.dart`).

## Не проверено

- Реальные платы и эфир (ACK-тайминги, PRO-прошивка).
- Остальные копии (flutter, flutter_info, flutter_firmware, PRO) в эмуляторе.

Видеозапись прогона flutter_ack приложена к сессии (в репозиторий не включена).
