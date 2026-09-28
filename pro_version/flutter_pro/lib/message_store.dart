import 'dart:collection';

import 'chat_protocol.dart';

/// Путь своего сообщения. Локальное эхо от ESP32 — только [accepted]
/// (принято в очередь платы); доставкой считается лишь ACK от удалённой
/// станции ([delivered]).
enum MessageStatus {
  /// Ждёт отправки в сокет (нет связи) или эха от платы.
  sending,

  /// Плата приняла в очередь передачи (эхо получено).
  accepted,

  /// Плата отключила передатчик: ушло в эфир, ждём ACK.
  aired,

  /// Удалённая станция подтвердила приём.
  delivered,

  /// ACK не пришёл; будет повтор, если попытки не исчерпаны.
  noack,

  /// Не отправлено окончательно.
  failed,
}

class Message {
  final String id;
  final String from;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  MessageStatus status;

  /// Сколько раз кадр уходил в сокет.
  int attempts;

  /// Станция, подтвердившая приём (из status:<id>:delivered:<станция>).
  String ackStation;

  /// Текст пришёл зашифрованным, но ключ не подошёл.
  final bool undecryptable;

  Message(
    this.id,
    this.from,
    this.text,
    this.isMe, {
    DateTime? timestamp,
    this.status = MessageStatus.delivered,
    this.attempts = 0,
    this.ackStation = '',
    this.undecryptable = false,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isFinal =>
      status == MessageStatus.delivered || status == MessageStatus.failed;

  Map<String, Object?> toJson() => {
        'id': id,
        'from': from,
        'text': text,
        'me': isMe,
        'ts': timestamp.millisecondsSinceEpoch,
        'st': status.name,
        'ack': ackStation,
        'undec': undecryptable,
      };

  /// null, если запись повреждена. Незавершённые статусы при загрузке
  /// становятся [MessageStatus.failed]: после перезапуска подтверждения
  /// уже не придут.
  static Message? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final from = json['from'];
    final text = json['text'];
    final ts = json['ts'];
    if (id is! String || from is! String || text is! String || ts is! int) {
      return null;
    }
    final stName = json['st'];
    var status = MessageStatus.values.firstWhere(
      (s) => s.name == stName,
      orElse: () => MessageStatus.failed,
    );
    if (!(status == MessageStatus.delivered ||
        status == MessageStatus.failed)) {
      status = MessageStatus.failed;
    }
    final ack = json['ack'];
    return Message(
      id,
      from,
      text,
      json['me'] == true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      status: status,
      ackStation: ack is String ? ack : '',
      undecryptable: json['undec'] == true,
    );
  }
}

/// Что сделал стор с входящим кадром — по этому решается, нужны ли
/// прокрутка, звук и уведомление.
enum IngestOutcome {
  /// Кадр — эхо нашего сообщения: плата приняла его в очередь.
  echoConfirmed,

  /// Повтор (из буфера прошивки или повторная передача), в список не добавлен.
  duplicateIgnored,

  /// Досланное из буфера сообщение: показывается молча.
  addedHistory,

  /// Новое сообщение собеседника.
  addedNew,
}

/// Отправленный кадр, ждущий эха от ESP32.
class _PendingEcho {
  final String echoKey;
  final Message message;
  final DateTime sentAt;

  _PendingEcho(this.echoKey, this.message, this.sentAt);
}

/// Список сообщений чата и учёт подтверждений.
///
/// Вынесено из ChatScreen: сверка эха, дедупликация истории и статусы
/// доставки — единственная часть клиента, которую можно проверить без
/// Wi-Fi, платы и виджетов.
class MessageStore {
  MessageStore({
    this.maxMessages = 500,
    this.maxPendingEcho = 16,
    this.echoTimeout = const Duration(seconds: 6),
  });

  final int maxMessages;
  final int maxPendingEcho;
  final Duration echoTimeout;

  final List<Message> _messages = [];
  final List<_PendingEcho> _pendingEcho = [];

  UnmodifiableListView<Message> get messages => UnmodifiableListView(_messages);

  bool get hasPendingEcho => _pendingEcho.isNotEmpty;

  bool isAwaitingEcho(Message message) =>
      _pendingEcho.any((p) => p.message == message);

  /// Свои сообщения, ещё не дошедшие до окончательного статуса.
  Iterable<Message> get unfinished =>
      _messages.where((m) => m.isMe && !m.isFinal);

  /// Загрузка сохранённой истории (до первого сообщения сессии).
  void restore(Iterable<Message> saved) {
    _messages.insertAll(0, saved);
    while (_messages.length > maxMessages) {
      _messages.removeAt(0);
    }
  }

  void clear() {
    _messages.clear();
    _pendingEcho.clear();
  }

  /// Своё сообщение показывается сразу как [MessageStatus.sending].
  Message addOutgoing(String id, String from, String text, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final message = Message(
      id,
      from,
      text,
      true,
      timestamp: at,
      status: MessageStatus.sending,
    );
    _append(message);
    return message;
  }

  /// Кадр ушёл в сокет: ждём эха от платы. [wireText] — текст в кадре
  /// (при шифровании отличается от [Message.text]).
  void markSent(Message message, {String? wireText, DateTime? now}) {
    message.attempts++;
    message.status = MessageStatus.sending;
    _pendingEcho.removeWhere((p) => p.message == message);
    _pendingEcho.add(_PendingEcho(
      echoKeyFor(message.from, wireText ?? message.text, id: message.id),
      message,
      now ?? DateTime.now(),
    ));
    while (_pendingEcho.length > maxPendingEcho) {
      _pendingEcho.removeAt(0).message.status = MessageStatus.failed;
    }
  }

  /// Кадр не ушёл в сокет — эха по нему не будет.
  void markFailed(Message message) {
    message.status = MessageStatus.failed;
    _pendingEcho.removeWhere((pending) => pending.message == message);
  }

  /// Статус доставки из прошивки. false, если сообщение не найдено или
  /// статус — шаг назад (повторный aired после delivered не откатывает).
  bool applyStatus(String id, RadioState state, {String detail = ''}) {
    final index = _messages.lastIndexWhere((m) => m.isMe && m.id == id);
    if (index < 0) return false;
    final message = _messages[index];
    if (message.status == MessageStatus.delivered) return false;
    switch (state) {
      case RadioState.aired:
        if (message.status == MessageStatus.noack) return false;
        message.status = MessageStatus.aired;
      case RadioState.delivered:
        message.status = MessageStatus.delivered;
        message.ackStation = detail;
      case RadioState.noack:
        message.status = MessageStatus.noack;
      case RadioState.failed:
        message.status = MessageStatus.failed;
      case RadioState.unknown:
        return false;
    }
    _pendingEcho.removeWhere((p) => p.message == message);
    return true;
  }

  IngestOutcome ingest(
    IncomingFrame frame, {
    required String myName,
    DateTime? now,
  }) {
    // Своё сообщение, вернувшееся широковещательно. Сверяем по id,
    // чтобы одинаковые тексты не сливались.
    final echoIndex =
        _pendingEcho.indexWhere((pending) => pending.echoKey == frame.echoKey);
    if (echoIndex >= 0) {
      final message = _pendingEcho.removeAt(echoIndex).message;
      if (message.status == MessageStatus.sending) {
        message.status = MessageStatus.accepted;
      }
      return IngestOutcome.echoConfirmed;
    }

    // В истории собственные сообщения не отличить по очереди эха (она очищена
    // при разрыве), поэтому опираемся на имя
    final isMine = frame.from == myName;

    // Прошивка отдаёт последние кадры при каждом рукопожатии, а повторная
    // передача (нет ACK) даёт второе эхо с тем же id — оба не показываем.
    if (_alreadyShown(frame.id, frame.from, frame.text, isMine)) {
      return IngestOutcome.duplicateIgnored;
    }

    final id =
        frame.id.isNotEmpty ? frame.id : echoKeyFor(frame.from, frame.text);
    _append(Message(
      id,
      frame.from,
      frame.text,
      isMine,
      timestamp: now,
      undecryptable: frame.undecryptable,
    ));
    return frame.isHistory
        ? IngestOutcome.addedHistory
        : IngestOutcome.addedNew;
  }

  /// Соединение оборвано: эха уже не придёт, сообщения возвращаются в
  /// [MessageStatus.sending] и уйдут повторно после переподключения.
  bool requeuePending() {
    if (_pendingEcho.isEmpty) return false;
    for (final pending in _pendingEcho) {
      pending.message.status = MessageStatus.sending;
    }
    _pendingEcho.clear();
    return true;
  }

  /// Просроченные эха: плата не подтвердила приём в очередь. Сообщение
  /// остаётся [MessageStatus.sending] для повтора; список возвращается
  /// вызывающему.
  List<Message> expirePending({DateTime? now}) {
    final at = now ?? DateTime.now();
    final expired = _pendingEcho
        .where((pending) => at.difference(pending.sentAt) >= echoTimeout)
        .toList();
    for (final pending in expired) {
      _pendingEcho.remove(pending);
    }
    return expired.map((p) => p.message).toList();
  }

  bool _alreadyShown(String id, String from, String text, bool isMe) {
    if (id.isNotEmpty) {
      return _messages.any((m) => m.id == id && m.from == from);
    }
    return _messages.any(
      (m) => m.from == from && m.text == text && m.isMe == isMe,
    );
  }

  void _append(Message message) {
    _messages.add(message);
    while (_messages.length > maxMessages) {
      _messages.removeAt(0);
    }
  }
}
