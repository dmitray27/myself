import 'package:flutter_test/flutter_test.dart';
import 'package:radiochat/chat_protocol.dart';
import 'package:radiochat/message_store.dart';

void main() {
  group('MessageStore echo matching', () {
    test('confirms echo by id, not by text', () {
      final store = MessageStore();

      store.addOutgoing('id1', 'User', 'Hello');
      store.addOutgoing('id2', 'User', 'Hello');

      final frame1 = parseIncomingFrame('User:id1:Hello');
      final outcome1 = store.ingest(frame1, myName: 'User');
      expect(outcome1, IngestOutcome.echoConfirmed);
      expect(store.messages[0].status, MessageStatus.accepted);

      // Второе эхо с тем же текстом, но другим id — не должно сбить счёт
      final frame2 = parseIncomingFrame('User:id2:Hello');
      final outcome2 = store.ingest(frame2, myName: 'User');
      expect(outcome2, IngestOutcome.echoConfirmed);
      expect(store.messages[1].status, MessageStatus.accepted);
    });

    test('legacy echo without id still works', () {
      final store = MessageStore();
      store.addOutgoing('', 'User', 'Hello');
      final frame = parseIncomingFrame('User:Hello');
      final outcome = store.ingest(frame, myName: 'User');
      expect(outcome, IngestOutcome.echoConfirmed);
    });

    test('deduplicates history by id', () {
      final store = MessageStore();
      final frame = parseIncomingFrame('hist:User:abc123:Hello');
      store.ingest(frame, myName: 'User');
      final outcome = store.ingest(frame, myName: 'User');
      expect(outcome, IngestOutcome.duplicateIgnored);
      expect(store.messages.length, 1);
    });

    test('same id from different senders is not a duplicate', () {
      final store = MessageStore();
      store.ingest(parseIncomingFrame('hist:Alice:1:Hello'), myName: 'User');
      final outcome = store.ingest(
        parseIncomingFrame('hist:Remote:1:Привет'),
        myName: 'User',
      );
      expect(outcome, IngestOutcome.addedHistory);
      expect(store.messages.length, 2);
    });

    test('same text with different ids is not a duplicate', () {
      final store = MessageStore();
      store.ingest(parseIncomingFrame('hist:Remote:r1:Да'), myName: 'User');
      final outcome = store.ingest(
        parseIncomingFrame('hist:Remote:r2:Да'),
        myName: 'User',
      );
      expect(outcome, IngestOutcome.addedHistory);
      expect(store.messages.length, 2);
    });
  });

  group('MessageStore late echo', () {
    test('late echo by id restores failed message instead of duplicating', () {
      final store = MessageStore(echoTimeout: const Duration(seconds: 1));
      final sent = DateTime(2026, 1, 1);
      store.addOutgoing('id9', 'User', 'Late', now: sent);
      expect(store.expirePending(now: sent.add(const Duration(seconds: 2))), true);
      expect(store.messages.single.status, MessageStatus.failed);

      final outcome =
          store.ingest(parseIncomingFrame('User:id9:Late'), myName: 'User');
      expect(outcome, IngestOutcome.echoConfirmed);
      expect(store.messages.length, 1);
      expect(store.messages.single.status, MessageStatus.accepted);
      expect(store.messages.single.isMe, true);
    });

    test('history frame restores failed message after reconnect', () {
      final store = MessageStore();
      final m = store.addOutgoing('id7', 'User', 'Hi');
      expect(store.failAllPending(), true);
      expect(m.status, MessageStatus.failed);

      final outcome =
          store.ingest(parseIncomingFrame('hist:User:id7:Hi'), myName: 'User');
      expect(outcome, IngestOutcome.echoConfirmed);
      expect(store.messages.length, 1);
      expect(m.status, MessageStatus.accepted);
    });

    test('late legacy echo without id matches own text', () {
      final store = MessageStore();
      final m = store.addOutgoing('', 'User', 'Old');
      store.markFailed(m);
      final outcome =
          store.ingest(parseIncomingFrame('User:Old'), myName: 'User');
      expect(outcome, IngestOutcome.echoConfirmed);
      expect(store.messages.length, 1);
      expect(m.status, MessageStatus.accepted);
    });

    test('same message from another station with my name is not swallowed', () {
      final store = MessageStore();
      final outcome =
          store.ingest(parseIncomingFrame('User:idX:Hello'), myName: 'User');
      expect(outcome, IngestOutcome.addedNew);
      expect(store.messages.length, 1);
    });
  });
}
