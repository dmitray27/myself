import 'dart:collection';

import 'chat_protocol.dart';

enum MessageStatus { sending, delivered, failed }

class Message {
  final String id;
  final String from;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  MessageStatus status;

  Message(
    this.id,
    this.from,
    this.text,
    this.isMe, {
    DateTime? timestamp,
    this.status = MessageStatus.delivered,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Что сделал стор с входящим кадром — по этому решается, нужны ли
/// прокрутка, звук и уведомление.
enum IngestOutcome {
  /// Кадр — эхо нашего сообщения, оно помечено доставленным.
  echoConfirmed,

  /// Повтор из буфера прошивки, в список не добавлен.
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

  /// Своё сообщение показывается сразу, но неподтверждённым: доставкой
  /// считается возврат кадра прошивкой.
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

    _pendingEcho.add(_PendingEcho(echoKeyFor(from, text, id: id), message, at));
    while (_pendingEcho.length > maxPendingEcho) {
      _pendingEcho.removeAt(0).message.status = MessageStatus.failed;
    }

    return message;
  }

  /// Кадр не ушёл в сокет — эха по нему не будет.
  void markFailed(Message message) {
    message.status = MessageStatus.failed;
    _pendingEcho.removeWhere((pending) => pending.message == message);
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
      _pendingEcho.removeAt(echoIndex).message.status = MessageStatus.delivered;
      return IngestOutcome.echoConfirmed;
    }

    // В истории собственные сообщения не отличить по очереди эха (она очищена
    // при разрыве), поэтому опираемся на имя
    final isMine = frame.isHistory && frame.from == myName;

    // Прошивка отдаёт последние кадры при каждом рукопожатии: после
    // переподключения те же сообщения приходят повторно. Сверяем по id,
    // если он есть; иначе — по имени и тексту.
    if (frame.isHistory && _alreadyShown(frame.id, frame.from, frame.text, isMine)) {
      return IngestOutcome.duplicateIgnored;
    }

    final id = frame.id.isNotEmpty ? frame.id : echoKeyFor(frame.from, frame.text);
    _append(Message(id, frame.from, frame.text, isMine, timestamp: now));
    return frame.isHistory ? IngestOutcome.addedHistory : IngestOutcome.addedNew;
  }

  /// Подтверждения по оборванному соединению уже не придут.
  bool failAllPending() {
    if (_pendingEcho.isEmpty) return false;
    for (final pending in _pendingEcho) {
      pending.message.status = MessageStatus.failed;
    }
    _pendingEcho.clear();
    return true;
  }

  /// Помечает просроченные отправки неудачными. Вызывается по общему
  /// таймеру опроса: отдельный Timer на каждое сообщение оставлял висящие
  /// колбэки после dispose.
  bool expirePending({DateTime? now}) {
    final at = now ?? DateTime.now();
    final expired = _pendingEcho
        .where((pending) => at.difference(pending.sentAt) >= echoTimeout)
        .toList();
    if (expired.isEmpty) return false;

    for (final pending in expired) {
      pending.message.status = MessageStatus.failed;
      _pendingEcho.remove(pending);
    }
    return true;
  }

  bool _alreadyShown(String id, String from, String text, bool isMe) {
    if (id.isNotEmpty) {
      for (final message in _messages.reversed) {
        if (message.id == id) return true;
      }
    }
    for (final message in _messages.reversed) {
      if (message.from == from && message.text == text && message.isMe == isMe) {
        return true;
      }
    }
    return false;
  }

  void _append(Message message) {
    _messages.add(message);
    while (_messages.length > maxMessages) {
      _messages.removeAt(0);
    }
  }
}
