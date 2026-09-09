import 'dart:convert';

/// Разбор и сборка кадров WebSocket-протокола ESP32.
///
/// Логика вынесена из ChatScreen, потому что это единственная часть клиента,
/// которую можно проверить тестами без Wi-Fi, плагинов и самой платы.
enum IncomingKind {
  /// Пустой или неразбираемый кадр — игнорируем.
  ignore,

  /// Проверка живости от прошивки, ждёт "pong".
  ping,

  /// Служебное уведомление "System:<текст>".
  system,

  /// Обычное сообщение "<имя>:<id>:<текст>".
  chat,
}

class IncomingFrame {
  final IncomingKind kind;

  /// Имя отправителя для [IncomingKind.chat].
  final String from;

  /// Уникальный идентификатор сообщения. Присутствует в новом протоколе;
  /// для кадров без id (legacy / System) — пустая строка.
  final String id;

  /// Текст для [IncomingKind.chat] и [IncomingKind.system].
  final String text;

  /// Ключ для сверки с собственными отправленными кадрами. В новом протоколе
  /// это ровно id; в legacy-формате — нормализованный вид "<имя>:<текст>".
  final String echoKey;

  /// Кадр из буфера прошивки ("hist:<имя>:<id>:<текст>"), досланный после
  /// переподключения. Показывается в чате, но без звука и уведомления.
  final bool isHistory;

  const IncomingFrame._(
    this.kind, {
    this.from = '',
    this.id = '',
    this.text = '',
    this.echoKey = '',
    this.isHistory = false,
  });

  static const IncomingFrame ignored = IncomingFrame._(IncomingKind.ignore);
  static const IncomingFrame ping = IncomingFrame._(IncomingKind.ping);
}

/// Максимальная длина WS-кадра, которую принимает прошивка
/// (WS_MAX_FRAME_LEN в main/wifi_link.c). Считается в байтах UTF-8,
/// а не в символах: кириллица занимает по два байта.
const int kMaxFrameBytes = 1024;

/// Префикс, которым прошивка помечает досланные из буфера сообщения
/// (history_send_to в main/wifi_link.c).
const String kHistoryPrefix = 'hist:';

int _idCounter = 0;

/// Генерирует короткий уникальный идентификатор кадра.
///
/// Включает временную метку и монотонный счётчик, не содержит ':'.
String generateMessageId() {
  final time = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  _idCounter = (_idCounter + 1) & 0xffffff;
  return '$time${_idCounter.toRadixString(36)}';
}

/// Кадр отправки сообщения в эфир.
///
/// Новый формат: `msg:<имя>:<id>:<текст>`. [id] нужен для однозначного
/// распознавания эха, особенно когда подряд идут два одинаковых текста.
String buildMessageFrame(String name, String text, {String? id}) {
  final effectiveId = id ?? '';
  return effectiveId.isEmpty ? 'msg:$name:$text' : 'msg:$name:$effectiveId:$text';
}

/// Кадр регистрации имени.
String buildSetNameFrame(String name) => 'setName:$name';

/// Ключ, по которому входящий кадр сверяется с очередью исходящих.
///
/// Если [id] задан — используется он, иначе возвращается fallback
/// "<имя>:<текст>" для совместимости со старыми кадрами без id.
String echoKeyFor(String name, String text, {String? id}) {
  if (id != null && id.isNotEmpty) return id;
  return '$name:$text';
}

/// Длина кадра в байтах — прошивка ограничивает именно её.
int frameByteLength(String frame) => utf8.encode(frame).length;

/// Помещается ли сообщение в кадр целиком.
bool messageFitsFrame(String name, String text, {String? id}) =>
    frameByteLength(buildMessageFrame(name, text, id: id)) <= kMaxFrameBytes;

/// Разбирает входящий кадр. Пробелы по краям обрезаются так же, как это
/// делал ChatScreen, поэтому echoKey совпадает с отправленным кадром.
IncomingFrame parseIncomingFrame(String raw) {
  var message = raw.trim();
  if (message.isEmpty) return IncomingFrame.ignored;

  var isHistory = false;
  if (message.startsWith(kHistoryPrefix)) {
    isHistory = true;
    message = message.substring(kHistoryPrefix.length).trim();
    if (message.isEmpty) return IncomingFrame.ignored;
  }

  if (message == 'ping') return IncomingFrame.ping;

  if (message.startsWith('System:')) {
    return IncomingFrame._(
      IncomingKind.system,
      text: message.substring(7).trim(),
    );
  }

  // Ожидаемый формат: <имя>:<id>:<текст> (новый) или <имя>:<текст> (legacy)
  final firstSeparator = message.indexOf(':');
  if (firstSeparator <= 0) return IncomingFrame.ignored;

  final from = message.substring(0, firstSeparator);
  final afterFrom = message.substring(firstSeparator + 1);

  final secondSeparator = afterFrom.indexOf(':');
  if (secondSeparator > 0) {
    final id = afterFrom.substring(0, secondSeparator);
    final text = afterFrom.substring(secondSeparator + 1).trim();
    if (text.isEmpty) return IncomingFrame.ignored;
    return IncomingFrame._(
      IncomingKind.chat,
      from: from,
      id: id,
      text: text,
      echoKey: echoKeyFor(from, text, id: id),
      isHistory: isHistory,
    );
  } else {
    final text = afterFrom.trim();
    if (text.isEmpty) return IncomingFrame.ignored;
    return IncomingFrame._(
      IncomingKind.chat,
      from: from,
      text: text,
      echoKey: echoKeyFor(from, text),
      isHistory: isHistory,
    );
  }
}
