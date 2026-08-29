import 'package:flutter_test/flutter_test.dart';
import 'package:radio_bridge_dual/chat_protocol.dart';
import 'package:radio_bridge_dual/message_store.dart';

void main() {
  group('MessageStore', () {
    test('своё сообщение показывается сразу как неподтверждённое', () {
      final store = MessageStore();

      final message = store.addOutgoing('Bob', 'привет');

      expect(store.messages, hasLength(1));
      expect(message.isMe, isTrue);
      expect(message.status, MessageStatus.sending);
      expect(store.hasPendingEcho, isTrue);
    });

    test('эхо от прошивки подтверждает доставку и не дублирует сообщение', () {
      final store = MessageStore();
      final message = store.addOutgoing('Bob', 'привет');

      final outcome = store.ingest(
        parseIncomingFrame('Bob:привет'),
        myName: 'Bob',
      );

      expect(outcome, IngestOutcome.echoConfirmed);
      expect(message.status, MessageStatus.delivered);
      expect(store.messages, hasLength(1));
      expect(store.hasPendingEcho, isFalse);
    });

    test('одинаковый текст от собеседника с тем же именем не съедает эхо дважды',
        () {
      final store = MessageStore();
      final mine = store.addOutgoing('Bob', 'ок');

      store.ingest(parseIncomingFrame('Bob:ок'), myName: 'Bob');
      final second = store.ingest(parseIncomingFrame('Bob:ок'), myName: 'Bob');

      expect(mine.status, MessageStatus.delivered);
      expect(second, IngestOutcome.addedNew);
      expect(store.messages, hasLength(2));
      expect(store.messages.last.isMe, isFalse);
    });

    test('повтор истории после переподключения игнорируется', () {
      final store = MessageStore();

      final first = store.ingest(
        parseIncomingFrame('hist:Alice:привет'),
        myName: 'Bob',
      );
      final repeat = store.ingest(
        parseIncomingFrame('hist:Alice:привет'),
        myName: 'Bob',
      );

      expect(first, IngestOutcome.addedHistory);
      expect(repeat, IngestOutcome.duplicateIgnored);
      expect(store.messages, hasLength(1));
    });

    test('своё сообщение из истории помечается своим', () {
      final store = MessageStore();

      store.ingest(parseIncomingFrame('hist:Bob:я'), myName: 'Bob');

      expect(store.messages.single.isMe, isTrue);
    });

    test('новое сообщение собеседника не считается историей', () {
      final store = MessageStore();

      final outcome = store.ingest(
        parseIncomingFrame('Alice:привет'),
        myName: 'Bob',
      );

      expect(outcome, IngestOutcome.addedNew);
      expect(store.messages.single.isMe, isFalse);
    });

    test('неотправленный кадр помечается неудачным и уходит из очереди', () {
      final store = MessageStore();
      final message = store.addOutgoing('Bob', 'привет');

      store.markFailed(message);

      expect(message.status, MessageStatus.failed);
      expect(store.hasPendingEcho, isFalse);
    });

    test('просроченные отправки помечаются неудачными', () {
      final start = DateTime(2024, 1, 1, 12);
      final store = MessageStore(echoTimeout: const Duration(seconds: 6));
      final message = store.addOutgoing('Bob', 'привет', now: start);

      expect(
        store.expirePending(now: start.add(const Duration(seconds: 5))),
        isFalse,
      );
      expect(message.status, MessageStatus.sending);

      expect(
        store.expirePending(now: start.add(const Duration(seconds: 7))),
        isTrue,
      );
      expect(message.status, MessageStatus.failed);
      expect(store.hasPendingEcho, isFalse);
    });

    test('разрыв связи хоронит все ожидающие подтверждения', () {
      final store = MessageStore();
      final first = store.addOutgoing('Bob', 'раз');
      final second = store.addOutgoing('Bob', 'два');

      expect(store.failAllPending(), isTrue);
      expect(first.status, MessageStatus.failed);
      expect(second.status, MessageStatus.failed);
      expect(store.failAllPending(), isFalse);
    });

    test('очередь эха ограничена: самые старые становятся неудачными', () {
      final store = MessageStore(maxPendingEcho: 2);
      final first = store.addOutgoing('Bob', 'раз');
      store.addOutgoing('Bob', 'два');
      store.addOutgoing('Bob', 'три');

      expect(first.status, MessageStatus.failed);
      expect(store.messages, hasLength(3));
    });

    test('список сообщений не растёт бесконечно', () {
      final store = MessageStore(maxMessages: 3);

      for (var i = 0; i < 5; i++) {
        store.ingest(parseIncomingFrame('Alice:$i'), myName: 'Bob');
      }

      expect(store.messages, hasLength(3));
      expect(store.messages.first.text, '2');
      expect(store.messages.last.text, '4');
    });
  });
}
