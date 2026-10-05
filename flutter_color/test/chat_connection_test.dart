import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:radio_bridge_dual/chat_connection.dart';

class FakeSocket implements ChatSocket {
  final controller = StreamController<String>();
  final sent = <String>[];
  bool closed = false;

  @override
  Stream get frames => controller.stream;

  @override
  Future<void> get ready => Future.value();

  @override
  void send(String frame) => sent.add(frame);

  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }
}

void main() {
  test('server close tears down socket and notifies onDisconnected at once',
      () async {
    final socket = FakeSocket();
    final connection = ChatConnection(socketFactory: () => socket);
    var disconnected = 0;
    final statuses = <ConnectionStatus>[];
    connection.onDisconnected = () async {
      disconnected++;
    };
    connection.onChanged = () => statuses.add(connection.status);

    expect(await connection.connect(), isTrue);
    expect(connection.isConnected, isTrue);

    await socket.controller.close();
    await Future<void>.delayed(Duration.zero);

    expect(disconnected, 1);
    expect(socket.closed, isTrue);
    expect(connection.status, ConnectionStatus.error);
    expect(connection.lastError, 'Соединение закрыто сервером');
    expect(connection.send('msg:a:b'), isFalse);
    expect(connection.isBusy, isFalse);
    expect(statuses, contains(ConnectionStatus.error));
  });

  test('stream error is handled the same way', () async {
    final socket = FakeSocket();
    final connection = ChatConnection(socketFactory: () => socket);
    var disconnected = 0;
    connection.onDisconnected = () async {
      disconnected++;
    };

    await connection.connect();
    socket.controller.addError(StateError('boom'));
    await Future<void>.delayed(Duration.zero);

    expect(disconnected, 1);
    expect(socket.closed, isTrue);
    expect(connection.status, ConnectionStatus.error);
  });

  test('explicit disconnect does not double-notify', () async {
    final socket = FakeSocket();
    final connection = ChatConnection(socketFactory: () => socket);
    var disconnected = 0;
    connection.onDisconnected = () async {
      disconnected++;
    };

    await connection.connect();
    await connection.disconnect();
    await Future<void>.delayed(Duration.zero);

    expect(disconnected, 1);
    expect(connection.status, ConnectionStatus.disconnected);
  });
}
