# Радиочат — Flutter-клиент

Клиент для ESP32 AFSK-трансивера (`../tx_rx_mes_200b_filter_verbose_wifi`).
Подключается к точке доступа платы по Wi-Fi, общается с ней по WebSocket и
показывает чат: свои сообщения уходят в эфир через плату, принятые с эфира
приходят от имени `Remote`.

Платформы: **Android** (основная) и **Linux desktop**.

---

## Требования

- Flutter SDK 3.22+ (Dart ≥ 3.0).
- Android: SDK / эмулятор, `minSdk` из `android/app/build.gradle`.
- Linux: `libgtk-3-dev` и стандартный toolchain для `flutter build linux`.

```bash
cd flutter
flutter pub get
flutter analyze
flutter test
```

---

## Сборка и запуск

```bash
# Linux desktop
flutter run -d linux
flutter build linux --release        # build/linux/x64/release/bundle/

# Android
flutter run -d <device>
flutter build apk --debug            # для эмулятора и логов
flutter build apk --release          # production APK
```

Перед запуском телефон/ноутбук должен быть подключён к Wi-Fi платы
(`AFSK-TRX-xxxx`, пароль по умолчанию `afsk12345`). Плата всегда на `192.168.4.1`.

---

## Как это работает

```
ChatScreen (UI)
   └─ ChatController         бизнес-логика, опрос сети, уведомления, foreground service
        ├─ ChatConnection    WebSocket-транспорт, статусы, таймауты
        ├─ chat_protocol     сборка/разбор кадров
        └─ MessageStore      история, подтверждение доставки по эху, дедупликация
```

| Файл | Назначение |
|---|---|
| `lib/main.dart` | Точка входа, тема, `window_manager` для Linux |
| `lib/screen_pro.dart` | Экран чата, диалоги имени/выхода, lifecycle |
| `lib/chat_controller.dart` | Опрос платы, bind к Wi-Fi, отправка, звук/уведомления, выход |
| `lib/chat_connection.dart` | `ChatSocket`/`WebSocketChatSocket`, `ChatConnection`, `PollBackoff` |
| `lib/chat_protocol.dart` | `buildMessageFrame`, `parseIncomingFrame`, лимит кадра |
| `lib/message_store.dart` | `Message`, статусы, `ingest`, `expirePending` |
| `android/.../MainActivity.kt` | MethodChannel `esp32/network`: bind к сети, сервис, выход |
| `android/.../ChatForegroundService.kt` | Foreground service + WifiLock, уведомления, «Выйти» |
| `test/` | Unit-тесты протокола и `MessageStore` |

### Цикл подключения

1. `ChatController` раз в 2 с (с экспоненциальным backoff до ~30 с при неудачах)
   читает локальный Wi-Fi IP.
2. Если IP из `192.168.4.x` — на Android процесс привязывается к этой сети
   (`bindToWifi`), чтобы трафик не ушёл в мобильный интернет. Привязка делается
   один раз на IP и повторяется только при смене сети.
3. `GET http://192.168.4.1/ping` → при `pong` открывается
   `ws://192.168.4.1:81/`, отправляется `setName:<имя>`, плата досылает историю.
4. На Android при живом соединении поднимается `ChatForegroundService`, чтобы
   ОС не замораживала процесс при погашенном экране.

### Протокол WebSocket

| Направление | Кадр | Комментарий |
|---|---|---|
| → плата | `setName:<имя>` | Имя без `:`, не `System` |
| → плата | `msg:<имя>:<id>:<текст>` | `id` генерирует клиент (`generateMessageId`) |
| → плата | `msg:<имя>:<текст>` | legacy без id |
| ← плата | `<имя>:<id>:<текст>` | Рассылка всем клиентам, в т.ч. эхо отправителю |
| ← плата | `Remote:r<n>:<текст>` | Сообщение, принятое с эфира |
| ← плата | `hist:<имя>:<id>:<текст>` | Досылка истории после подключения (без звука) |
| ← плата | `System:<текст>` | Служебное уведомление → SnackBar |
| ← плата | `ping` | Проверка живости, клиент игнорирует |

Лимит кадра — **1024 байта UTF-8** (`kMaxFrameBytes`), считается вместе с
префиксом, именем и id; UI не даёт отправить больше.

### Доставка и дедупликация

- Отправленное сообщение получает статус `pending` и ждёт эха от платы с тем же
  `id` (`echoKey`). Эхо → `delivered`; нет эха за таймаут → `failed`.
- История (`hist:`) дедуплицируется по паре **(отправитель, id)**, а без id —
  по (отправитель, текст). Сравнение только по id недопустимо: у HTTP-,
  AFSK- и клиентских сообщений независимые счётчики.

### Выход из приложения (Android)

AppBar «Выйти» → `ChatController.exit()` → `closeApp` в `MainActivity` →
`ChatForegroundService.requestExit()`: снимает привязку к сети, гасит сервис
и уведомления, закрывает задачу и с небольшой задержкой убивает процесс.
Кнопка «Выйти» в уведомлении идёт той же цепочкой (`ACTION_EXIT`).
Если платформа закрыла приложение сама, `SystemNavigator.pop()` не вызывается.

---

## Настройки и данные

- Имя пользователя хранится в `SharedPreferences` (`user_name`).
- Звук входящего сообщения — `assets/73g_assets/sounds/`.
- Адрес платы задаётся параметром `ChatController(esp32Address: ...)`,
  по умолчанию `192.168.4.1`.

---

## Тесты

```bash
flutter test                       # все
flutter test test/message_store_test.dart
```

Тесты покрывают разбор/сборку кадров, подсчёт байт для кириллицы,
подтверждение эха по id и дедупликацию истории. Транспорт (`ChatSocket`)
абстрагирован, поэтому `ChatConnection` можно тестировать без сети.

Сквозные проверки на реальной плате — скрипты в корне репозитория
(`ws_test_stub.py`, `ws_real_hw_test.sh`, `ws_real_hw_all.sh`), см. `../RUN.md`.

---

## Известные ограничения

- Package name и label пока `com.example.radio_bridge_dual` / `radio_bridge_dual`.
- Иконка foreground-уведомления — системная (Bluetooth), своей пока нет.
- Каждая плата — отдельная точка доступа, поэтому один клиент видит только
  «свою» плату; сквозной тест TX → эфир → RX требует двух устройств.
