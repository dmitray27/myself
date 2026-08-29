import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_bridge_dual/chat_connection.dart';

class FakeChatSocket implements ChatSocket {
  FakeChatSocket({this.readyCompleter});

  final Completer<void>? readyCompleter;
  final StreamController<dynamic> _frames = StreamController<dynamic>();
  final List<String> sent = [];
  final List<Object> sendErrors = [];
  bool closed = false;

  @override
  Stream get frames => _frames.stream;

  @override
  Future<void> get ready => readyCompleter?.future ?? Future<void>.value();

  @override
  void send(String frame) {
    if (sendErrors.isNotEmpty) {
      throw sendErrors.removeAt(0);
    }
    sent.add(frame);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_frames.isClosed) await _frames.close();
  }

  void emit(String frame) => _frames.add(frame);

  void fail(Object error) => _frames.addError(error);

  Future<void> finish() => _frames.close();
}

void main() {
  group('ChatConnection', () {
    test('подключается и отдаёт кадры наружу', () async {
      final socket = FakeChatSocket();
      final frames = <String>[];
      var connectedCalls = 0;

      final connection = ChatConnection(socketFactory: () => socket)
        ..onFrame = frames.add
        ..onConnected = () async => connectedCalls++;

      expect(await connection.connect(), isTrue);
      expect(connection.status, ConnectionStatus.connected);
      expect(connection.isConnected, isTrue);
      expect(connectedCalls, 1);

      socket.emit('msg:Bob:привет');
      await Future<void>.delayed(Duration.zero);
      expect(frames, ['msg:Bob:привет']);

      await connection.disconnect();
    });

    test('таймаут рукопожатия оставляет статус ошибки и закрывает сокет',
        () async {
      final socket = FakeChatSocket(readyCompleter: Completer<void>());
      final connection = ChatConnection(
        socketFactory: () => socket,
        handshakeTimeout: const Duration(milliseconds: 10),
      );

      expect(await connection.connect(), isFalse);
      expect(connection.status, ConnectionStatus.error);
      expect(connection.lastError, 'Не удалось подключиться');
      expect(socket.closed, isTrue);
      expect(connection.isConnecting, isFalse);
    });

    test('первое подключение не дёргает onDisconnected', () async {
      final socket = FakeChatSocket();
      var disconnectedCalls = 0;
      final connection = ChatConnection(socketFactory: () => socket)
        ..onDisconnected = () async => disconnectedCalls++;

      await connection.connect();
      expect(disconnectedCalls, 0);

      await connection.disconnect();
      expect(disconnectedCalls, 1);
    });

    test('повторное подключение закрывает прошлый сокет', () async {
      final sockets = <FakeChatSocket>[];
      final connection = ChatConnection(socketFactory: () {
        final socket = FakeChatSocket();
        sockets.add(socket);
        return socket;
      });

      await connection.connect();
      await connection.connect();

      expect(sockets, hasLength(2));
      expect(sockets.first.closed, isTrue);
      expect(sockets.last.closed, isFalse);
      expect(connection.status, ConnectionStatus.connected);

      await connection.disconnect();
    });

    test('ошибка потока переводит в состояние ошибки', () async {
      final socket = FakeChatSocket();
      final connection = ChatConnection(socketFactory: () => socket);

      await connection.connect();
      socket.fail(StateError('обрыв'));
      await Future<void>.delayed(Duration.zero);

      expect(connection.status, ConnectionStatus.error);
      expect(connection.lastError, 'WebSocket ошибка');
      expect(connection.send('msg:Bob:тест'), isFalse);
    });

    test('закрытие потока сервером фиксируется как ошибка', () async {
      final socket = FakeChatSocket();
      final connection = ChatConnection(socketFactory: () => socket);

      await connection.connect();
      await socket.finish();
      await Future<void>.delayed(Duration.zero);

      expect(connection.status, ConnectionStatus.error);
      expect(connection.lastError, 'Соединение закрыто сервером');
    });

    test('send отдаёт кадр сокету, а после разрыва возвращает false', () async {
      final socket = FakeChatSocket();
      final connection = ChatConnection(socketFactory: () => socket);

      await connection.connect();
      expect(connection.send('setName:Bob'), isTrue);
      expect(socket.sent, ['setName:Bob']);

      await connection.disconnect();
      expect(connection.send('setName:Bob'), isFalse);
      expect(socket.sent, ['setName:Bob']);
    });

    test('send сообщает о неудаче, если сокет бросил исключение', () async {
      final socket = FakeChatSocket()..sendErrors.add(StateError('мёртв'));
      final connection = ChatConnection(socketFactory: () => socket);

      await connection.connect();
      expect(connection.send('msg:Bob:тест'), isFalse);
    });

    test('onChanged срабатывает на каждой смене статуса', () async {
      final socket = FakeChatSocket();
      final statuses = <ConnectionStatus>[];
      final connection = ChatConnection(socketFactory: () => socket);
      connection.onChanged = () => statuses.add(connection.status);

      await connection.connect();
      await connection.disconnect();

      expect(statuses, [
        ConnectionStatus.connecting,
        ConnectionStatus.connected,
        ConnectionStatus.disconnected,
      ]);
    });

    test('disconnect закрывает сокет и сбрасывает статус', () async {
      final socket = FakeChatSocket();
      final connection = ChatConnection(socketFactory: () => socket);

      await connection.connect();
      await connection.disconnect();

      expect(socket.closed, isTrue);
      expect(connection.status, ConnectionStatus.disconnected);
      expect(connection.lastError, isEmpty);
      expect(connection.isBusy, isFalse);
    });
  });

  group('PollBackoff', () {
    test('первые неудачи не растягивают интервал', () {
      final backoff = PollBackoff();

      expect(backoff.interval, const Duration(seconds: 2));
      backoff.onFailure();
      backoff.onFailure();
      expect(backoff.interval, const Duration(seconds: 2));
    });

    test('интервал растёт до максимума и там остаётся', () {
      final backoff = PollBackoff();

      for (var i = 0; i < 3; i++) {
        backoff.onFailure();
      }
      expect(backoff.interval, const Duration(seconds: 4));

      backoff.onFailure();
      expect(backoff.interval, const Duration(seconds: 8));

      for (var i = 0; i < 10; i++) {
        backoff.onFailure();
      }
      expect(backoff.interval, const Duration(seconds: 10));
    });

    test('успех возвращает базовый интервал', () {
      final backoff = PollBackoff();

      for (var i = 0; i < 5; i++) {
        backoff.onFailure();
      }
      backoff.onSuccess();

      expect(backoff.interval, const Duration(seconds: 2));
    });
  });
}
