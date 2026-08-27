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

  /// Обычное сообщение "<имя>:<текст>".
  chat,
}

class IncomingFrame {
  final IncomingKind kind;

  /// Имя отправителя для [IncomingKind.chat].
  final String from;

  /// Текст для [IncomingKind.chat] и [IncomingKind.system].
  final String text;

  /// Ключ для сверки с собственными отправленными кадрами: нормализованный
  /// вид "<имя>:<текст>", ровно то, что рассылает прошивка.
  final String echoKey;

  const IncomingFrame._(this.kind, {this.from = '', this.text = '', this.echoKey = ''});

  static const IncomingFrame ignored = IncomingFrame._(IncomingKind.ignore);
  static const IncomingFrame ping = IncomingFrame._(IncomingKind.ping);
}

/// Максимальная длина WS-кадра, которую принимает прошивка
/// (WS_MAX_FRAME_LEN в main/wifi_link.c). Считается в байтах UTF-8,
/// а не в символах: кириллица занимает по два байта.
const int kMaxFrameBytes = 1024;

/// Кадр отправки сообщения в эфир.
String buildMessageFrame(String name, String text) => 'msg:$name:$text';

/// Кадр регистрации имени.
String buildSetNameFrame(String name) => 'setName:$name';

/// Вид, в котором прошивка вернёт наше же сообщение всем клиентам.
String echoKeyFor(String name, String text) => '$name:$text';

/// Длина кадра в байтах — прошивка ограничивает именно её.
int frameByteLength(String frame) => utf8.encode(frame).length;

/// Помещается ли сообщение в кадр целиком.
bool messageFitsFrame(String name, String text) =>
    frameByteLength(buildMessageFrame(name, text)) <= kMaxFrameBytes;

/// Разбирает входящий кадр. Пробелы по краям обрезаются так же, как это
/// делал ChatScreen, поэтому echoKey совпадает с отправленным кадром.
IncomingFrame parseIncomingFrame(String raw) {
  final message = raw.trim();
  if (message.isEmpty) return IncomingFrame.ignored;

  if (message == 'ping') return IncomingFrame.ping;

  if (message.startsWith('System:')) {
    return IncomingFrame._(IncomingKind.system, text: message.substring(7));
  }

  final separator = message.indexOf(':');
  if (separator <= 0) return IncomingFrame.ignored;

  final from = message.substring(0, separator);
  final text = message.substring(separator + 1).trim();
  if (text.isEmpty) return IncomingFrame.ignored;

  return IncomingFrame._(
    IncomingKind.chat,
    from: from,
    text: text,
    echoKey: echoKeyFor(from, text),
  );
}
