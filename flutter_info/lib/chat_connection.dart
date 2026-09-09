import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

/// Транспорт кадров чата. Абстракция нужна ради тестов: настоящий
/// IOWebSocketChannel требует сети и самой платы.
abstract class ChatSocket {
  Stream get frames;

  /// Завершается после рукопожатия.
  Future<void> get ready;

  void send(String frame);

  Future<void> close();
}

class WebSocketChatSocket implements ChatSocket {
  WebSocketChatSocket(String url, {Duration pingInterval = const Duration(seconds: 5)})
      : _channel = IOWebSocketChannel.connect(url, pingInterval: pingInterval);

  final WebSocketChannel _channel;

  @override
  Stream get frames => _channel.stream;

  @override
  Future<void> get ready => _channel.ready;

  @override
  void send(String frame) => _channel.sink.add(frame);

  @override
  Future<void> close() => _channel.sink.close();
}

typedef ChatSocketFactory = ChatSocket Function();

/// WebSocket-соединение с ESP32: рукопожатие, разрыв и статус.
///
/// Wi-Fi-биндинг, foreground-сервис и UI остаются снаружи — здесь только то,
/// что можно проверить тестами на поддельном сокете.
class ChatConnection {
  ChatConnection({
    required this.socketFactory,
    this.handshakeTimeout = const Duration(seconds: 8),
    this.closeTimeout = const Duration(seconds: 8),
    this.cancelTimeout = const Duration(seconds: 2),
  });

  final ChatSocketFactory socketFactory;
  final Duration handshakeTimeout;
  final Duration closeTimeout;
  final Duration cancelTimeout;

  /// Пришёл кадр из эфира.
  void Function(String frame)? onFrame;

  /// Изменились [status] или [lastError] — самое время перерисовать UI.
  void Function()? onChanged;

  /// Соединение установлено: снаружи поднимается сервис и отправляется имя.
  Future<void> Function()? onConnected;

  /// Соединение закрыто или оборвано.
  Future<void> Function()? onDisconnected;

  ChatSocket? _socket;
  StreamSubscription? _subscription;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _lastError = '';
  bool _isConnecting = false;
  bool _isDisconnecting = false;

  ConnectionStatus get status => _status;
  String get lastError => _lastError;
  bool get isConnecting => _isConnecting;
  bool get isDisconnecting => _isDisconnecting;
  bool get isConnected => _status == ConnectionStatus.connected;
  bool get isBusy => _isConnecting || _isDisconnecting;

  Future<bool> connect() async {
    if (_isConnecting) return false;
    _isConnecting = true;

    try {
      // Прошлый канал закрываем только если он был: иначе каждая первая
      // попытка дёргала бы onDisconnected на пустом месте
      if (_socket != null || _subscription != null) {
        await disconnect();
      }
      _setStatus(ConnectionStatus.connecting, '');

      final socket = socketFactory();
      _socket = socket;
      _subscription = socket.frames.listen(
        (frame) => onFrame?.call(frame.toString()),
        onError: (error) => _handleError('WebSocket ошибка'),
        onDone: () => _handleError('Соединение закрыто сервером'),
        cancelOnError: true,
      );

      // Ждём рукопожатия, но не дольше handshakeTimeout: на мёртвой сети
      // ready может висеть до системного TCP-таймаута
      await socket.ready.timeout(handshakeTimeout);

      // Пока шло рукопожатие, соединение могли закрыть
      if (_socket != socket) {
        throw StateError('Соединение закрыто во время рукопожатия');
      }

      _setStatus(ConnectionStatus.connected, '');
      await onConnected?.call();
      return true;
    } catch (e) {
      debugPrint('Не удалось подключиться: $e');
      await _teardown();
      _setStatus(ConnectionStatus.error, 'Не удалось подключиться');
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> disconnect() async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;

    try {
      await onDisconnected?.call();
      await _teardown();
    } finally {
      _setStatus(ConnectionStatus.disconnected, '');
      _isDisconnecting = false;
    }
  }

  Future<void> _teardown() async {
    // Снимаем ссылки ДО ожиданий, чтобы новая попытка подключения
    // не зацепилась за мёртвый канал
    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;

    if (subscription != null) {
      try {
        await subscription.cancel().timeout(cancelTimeout);
      } catch (e) {
        debugPrint('Ошибка/таймаут отписки: $e');
      }
    }

    if (socket != null) {
      try {
        await socket.close().timeout(closeTimeout);
      } catch (e) {
        debugPrint('Ошибка/таймаут при закрытии канала: $e');
      }
    }
  }

  /// Возвращает false, если кадр не удалось отдать сокету.
  bool send(String frame) {
    final socket = _socket;
    if (socket == null || _status != ConnectionStatus.connected) return false;
    try {
      socket.send(frame);
      return true;
    } catch (e) {
      // sink.add обычно не бросает: ошибка мёртвого сокета приходит
      // асинхронно в onError, поэтому подтверждением служит только эхо
      debugPrint('Ошибка отправки WS: $e');
      return false;
    }
  }

  void _handleError(String error) {
    if (_status == ConnectionStatus.disconnected || _isDisconnecting) return;
    _setStatus(ConnectionStatus.error, error);
  }

  void _setStatus(ConnectionStatus status, String error) {
    if (_status == status && _lastError == error) return;
    _status = status;
    _lastError = error;
    onChanged?.call();
  }
}

/// Интервал опроса платы: при неудачах растёт, чтобы ping с таймаутом
/// не будил Wi-Fi каждые две секунды там, где сети ESP32 просто нет.
class PollBackoff {
  PollBackoff({
    this.base = const Duration(seconds: 2),
    this.max = const Duration(seconds: 10),
    this.failuresBeforeBackoff = 3,
  });

  final Duration base;
  final Duration max;
  final int failuresBeforeBackoff;

  int _failures = 0;

  Duration get interval {
    if (_failures < failuresBeforeBackoff) return base;
    final factor = 1 << (_failures - failuresBeforeBackoff + 1);
    final scaled = base * factor;
    return scaled > max ? max : scaled;
  }

  void onSuccess() => _failures = 0;

  void onFailure() {
    if (interval < max) _failures++;
  }
}
