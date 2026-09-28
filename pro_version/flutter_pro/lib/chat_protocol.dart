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

  /// Статус доставки по эфиру "status:<id>:<state>[:<detail>]"
  /// (PRO-прошивка, wifi_link_status в main/wifi_link.c).
  status,

  /// Статистика канала "stat:{json}".
  stat,

  /// Абоненты в эфире "peers:<станция>=<сек назад>,...".
  peers,
}

/// Состояние из кадра status:. Отдельно от [MessageStatus]: прошивка
/// не знает про локальные состояния клиента (очередь, повтор).
enum RadioState { aired, delivered, noack, failed, unknown }

RadioState parseRadioState(String s) {
  switch (s) {
    case 'aired':
      return RadioState.aired;
    case 'delivered':
      return RadioState.delivered;
    case 'noack':
      return RadioState.noack;
    case 'failed':
      return RadioState.failed;
  }
  return RadioState.unknown;
}

/// Счётчики прошивки (link_stats_t в main/wifi_link.h). Отсутствующие поля — 0.
class LinkStats {
  final int rxFrames;
  final int crcErrors;
  final int framesAborted;
  final int rxMessages;
  final int rxIncomplete;
  final int txMessages;
  final int txAcked;
  final int txNoack;
  final bool rxBusy;
  final bool txBusy;
  final int signalDb;
  final int preamblePct;
  final String station;

  const LinkStats({
    this.rxFrames = 0,
    this.crcErrors = 0,
    this.framesAborted = 0,
    this.rxMessages = 0,
    this.rxIncomplete = 0,
    this.txMessages = 0,
    this.txAcked = 0,
    this.txNoack = 0,
    this.rxBusy = false,
    this.txBusy = false,
    this.signalDb = 0,
    this.preamblePct = 0,
    this.station = '',
  });

  static const LinkStats empty = LinkStats();

  /// null, если это не JSON-объект.
  static LinkStats? fromJson(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final Map map = decoded;
    int i(String k) {
      final v = map[k];
      return v is num ? v.toInt() : 0;
    }

    bool b(String k) => map[k] == true;
    final station = map['station'];
    return LinkStats(
      rxFrames: i('rx'),
      crcErrors: i('crc'),
      framesAborted: i('abort'),
      rxMessages: i('msgs'),
      rxIncomplete: i('incomplete'),
      txMessages: i('tx'),
      txAcked: i('acked'),
      txNoack: i('noack'),
      rxBusy: b('rx_busy'),
      txBusy: b('tx_busy'),
      signalDb: i('signal_db'),
      preamblePct: i('preamble'),
      station: station is String ? station : '',
    );
  }

  /// Доля битых кадров в процентах (0, если ничего не принято).
  int get crcErrorPct => rxFrames == 0 ? 0 : (crcErrors * 100 ~/ rxFrames);

  /// Доля подтверждённых передач в процентах.
  int get ackPct {
    final done = txAcked + txNoack;
    return done == 0 ? 0 : (txAcked * 100 ~/ done);
  }
}

/// Абонент из кадра peers:. [ageSeconds] — сколько секунд назад плата
/// слышала его ACK на момент отправки кадра.
class PeerInfo {
  final String station;
  final int ageSeconds;
  const PeerInfo(this.station, this.ageSeconds);

  @override
  bool operator ==(Object other) =>
      other is PeerInfo &&
      other.station == station &&
      other.ageSeconds == ageSeconds;

  @override
  int get hashCode => Object.hash(station, ageSeconds);
}

/// Разбор "A1B2=12,C3D4=340". Неразбираемые элементы пропускаются.
List<PeerInfo> parsePeerList(String body) {
  final result = <PeerInfo>[];
  for (final part in body.split(',')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    final station = part.substring(0, eq).trim();
    final age = int.tryParse(part.substring(eq + 1).trim());
    if (station.isEmpty || age == null || age < 0) continue;
    result.add(PeerInfo(station, age));
  }
  return result;
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

  /// Для [IncomingKind.status]: состояние и деталь (станция, подтвердившая
  /// приём, или причина отказа).
  final RadioState radioState;
  final String detail;

  /// Для [IncomingKind.stat].
  final LinkStats? stats;

  /// Для [IncomingKind.peers].
  final List<PeerInfo> peers;

  /// Текст был зашифрован, но ключ не подошёл (см. [withDecryptedText]).
  final bool undecryptable;

  const IncomingFrame._(
    this.kind, {
    this.from = '',
    this.id = '',
    this.text = '',
    this.echoKey = '',
    this.isHistory = false,
    this.radioState = RadioState.unknown,
    this.detail = '',
    this.stats,
    this.peers = const [],
    this.undecryptable = false,
  });

  /// Копия chat-кадра с расшифрованным текстом. echoKey не меняется: эхо
  /// сверяется с тем, что реально ушло в сокет.
  IncomingFrame withDecryptedText(String? decrypted) => IncomingFrame._(
        kind,
        from: from,
        id: id,
        text: decrypted ?? '[зашифровано: ключ не совпадает]',
        echoKey: echoKey,
        isHistory: isHistory,
        undecryptable: decrypted == null,
      );

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

/// Все id — прошивки (`p<hex>`, `r<n>`) и клиента ([generateMessageId]) —
/// состоят только из латинских букв и цифр. Всё остальное между первым и
/// вторым ':' считается началом legacy-текста.
final RegExp _idPattern = RegExp(r'^[A-Za-z0-9]{1,32}$');

bool looksLikeMessageId(String s) => _idPattern.hasMatch(s);

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
  return effectiveId.isEmpty
      ? 'msg:$name:$text'
      : 'msg:$name:$effectiveId:$text';
}

/// Кадр регистрации имени.
String buildSetNameFrame(String name) => 'setName:$name';

/// Предел имени в прошивке (WS_NAME_MAX в main/wifi_link.c, включая '\0'),
/// в байтах UTF-8: более длинное имя плата молча обрежет.
const int kMaxNameBytes = 31;

/// Имена, совпадающие с префиксами служебных кадров PRO-прошивки
/// (name_is_valid в main/wifi_link.c).
const Set<String> kReservedNames = {
  'status',
  'stat',
  'peers',
  'hist',
  'ping',
  'pong'
};

/// Текст уведомлений прошивки на setName: имя занято другим клиентом /
/// имя принято.
const String kSystemNameBusy = 'name busy';
const String kSystemNameOk = 'name ok';

/// Ограничения POST /config прошивки (config_post_handler в main/wifi_link.c):
/// SSID 1..32 байт без кавычки, пароль WPA2 8..63 символа.
String? validateApConfig(String ssid, String password) {
  final ssidBytes = utf8.encode(ssid).length;
  if (ssidBytes == 0) return 'SSID не может быть пустым';
  if (ssidBytes > 32) return 'SSID не длиннее 32 байт';
  if (ssid.contains('"')) return 'SSID не может содержать кавычку';
  if (password.length < 8) return 'Пароль не короче 8 символов';
  if (password.length > 63) return 'Пароль не длиннее 63 символов';
  if (password.runes.any((r) => r > 0x7e || r < 0x20)) {
    return 'Пароль — только латиница, цифры и знаки';
  }
  return null;
}

/// Те же правила, что name_is_valid() в прошивке: не пустое, без ':'
/// и не начинается с "System" (иначе можно подделать служебные кадры).
/// Возвращает текст ошибки или null.
String? validateName(String name) {
  if (name.isEmpty) return 'Имя не может быть пустым';
  if (name.contains(':')) return 'Имя не может содержать двоеточие';
  if (name.startsWith('System')) return 'Имя не может начинаться с "System"';
  if (kReservedNames.contains(name)) return 'Имя "$name" зарезервировано';
  if (utf8.encode(name).length > kMaxNameBytes) {
    return 'Имя слишком длинное (до $kMaxNameBytes байт)';
  }
  return null;
}

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

  // Служебные кадры PRO-прошивки. Имена с такими префиксами плата не
  // принимает (kReservedNames), поэтому с чатом они не путаются.
  if (message.startsWith('status:')) {
    final parts = message.substring(7).split(':');
    if (parts.length < 2 || !looksLikeMessageId(parts[0])) {
      return IncomingFrame.ignored;
    }
    return IncomingFrame._(
      IncomingKind.status,
      id: parts[0],
      radioState: parseRadioState(parts[1]),
      detail: parts.length > 2 ? parts.sublist(2).join(':') : '',
    );
  }

  if (message.startsWith('stat:')) {
    final stats = LinkStats.fromJson(message.substring(5));
    if (stats == null) return IncomingFrame.ignored;
    return IncomingFrame._(IncomingKind.stat, stats: stats);
  }

  if (message.startsWith('peers:')) {
    return IncomingFrame._(
      IncomingKind.peers,
      peers: parsePeerList(message.substring(6)),
    );
  }

  // Ожидаемый формат: <имя>:<id>:<текст> (новый) или <имя>:<текст> (legacy)
  final firstSeparator = message.indexOf(':');
  if (firstSeparator <= 0) return IncomingFrame.ignored;

  final from = message.substring(0, firstSeparator);
  final afterFrom = message.substring(firstSeparator + 1);

  final secondSeparator = afterFrom.indexOf(':');
  final id = secondSeparator > 0 ? afterFrom.substring(0, secondSeparator) : '';
  if (id.isNotEmpty && looksLikeMessageId(id)) {
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
