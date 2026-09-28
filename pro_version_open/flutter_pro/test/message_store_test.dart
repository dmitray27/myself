import 'package:flutter_test/flutter_test.dart';
import 'package:radio_bridge_dual/chat_protocol.dart';
import 'package:radio_bridge_dual/message_store.dart';

Message send(MessageStore store, String id, String text) {
  final m = store.addOutgoing(id, 'User', text);
  store.markSent(m);
  return m;
}

void main() {
  group('MessageStore echo matching', () {
    test('echo confirms by id and only means accepted, not delivered', () {
      final store = MessageStore();
      send(store, 'id1', 'Hello');
      send(store, 'id2', 'Hello');

      final outcome1 =
          store.ingest(parseIncomingFrame('User:id1:Hello'), myName: 'User');
      expect(outcome1, IngestOutcome.echoConfirmed);
      expect(store.messages[0].status, MessageStatus.accepted);
      expect(store.messages[1].status, MessageStatus.sending);

      final outcome2 =
          store.ingest(parseIncomingFrame('User:id2:Hello'), myName: 'User');
      expect(outcome2, IngestOutcome.echoConfirmed);
      expect(store.messages[1].status, MessageStatus.accepted);
    });

    test('legacy echo without id still works', () {
      final store = MessageStore();
      send(store, '', 'Hello');
      final outcome =
          store.ingest(parseIncomingFrame('User:Hello'), myName: 'User');
      expect(outcome, IngestOutcome.echoConfirmed);
    });

    test('second echo of a retransmitted message is ignored', () {
      final store = MessageStore();
      send(store, 'id1', 'Hello');
      store.ingest(parseIncomingFrame('User:id1:Hello'), myName: 'User');
      final again =
          store.ingest(parseIncomingFrame('User:id1:Hello'), myName: 'User');
      expect(again, IngestOutcome.duplicateIgnored);
      expect(store.messages.length, 1);
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

  group('MessageStore radio status', () {
    test('aired -> delivered with station, later statuses do not roll back',
        () {
      final store = MessageStore();
      final m = send(store, 'a1', 'Hi');
      store.ingest(parseIncomingFrame('User:a1:Hi'), myName: 'User');

      expect(store.applyStatus('a1', RadioState.aired), isTrue);
      expect(m.status, MessageStatus.aired);
      expect(
        store.applyStatus('a1', RadioState.delivered, detail: '8045'),
        isTrue,
      );
      expect(m.status, MessageStatus.delivered);
      expect(m.ackStation, '8045');
      expect(m.isFinal, isTrue);

      expect(store.applyStatus('a1', RadioState.noack), isFalse);
      expect(store.applyStatus('a1', RadioState.aired), isFalse);
      expect(m.status, MessageStatus.delivered);
    });

    test('noack and failed are applied; unknown id/state ignored', () {
      final store = MessageStore();
      final m = send(store, 'n1', 'Hi');
      expect(store.applyStatus('n1', RadioState.noack), isTrue);
      expect(m.status, MessageStatus.noack);
      expect(m.isFinal, isFalse);
      expect(store.applyStatus('n1', RadioState.aired), isFalse);
      expect(store.applyStatus('n1', RadioState.failed), isTrue);
      expect(m.status, MessageStatus.failed);

      expect(store.applyStatus('zzz', RadioState.delivered), isFalse);
      final other = send(store, 'u1', 'Hi');
      expect(store.applyStatus('u1', RadioState.unknown), isFalse);
      expect(other.status, MessageStatus.sending);
    });

    test('status for a message never echoed clears pending echo', () {
      final store = MessageStore();
      final m = send(store, 's1', 'Hi');
      expect(store.isAwaitingEcho(m), isTrue);
      store.applyStatus('s1', RadioState.aired);
      expect(store.isAwaitingEcho(m), isFalse);
      expect(store.hasPendingEcho, isFalse);
    });

    test('delivered is never produced by local echo alone', () {
      final store = MessageStore();
      final m = send(store, 'd1', 'Hi');
      store.ingest(parseIncomingFrame('User:d1:Hi'), myName: 'User');
      store.ingest(parseIncomingFrame('hist:User:d1:Hi'), myName: 'User');
      expect(m.status, MessageStatus.accepted);
    });
  });

  group('MessageStore retry bookkeeping', () {
    test('markSent counts attempts and requeuePending resets to sending', () {
      final store = MessageStore();
      final m = send(store, 'r1', 'Hi');
      expect(m.attempts, 1);
      store.markSent(m);
      expect(m.attempts, 2);
      expect(store.requeuePending(), isTrue);
      expect(m.status, MessageStatus.sending);
      expect(store.hasPendingEcho, isFalse);
      expect(store.requeuePending(), isFalse);
    });

    test('expirePending returns expired messages but keeps them retryable', () {
      final store = MessageStore(echoTimeout: const Duration(seconds: 6));
      final t0 = DateTime(2026, 1, 1);
      final m = store.addOutgoing('x1', 'User', 'Hi', now: t0);
      store.markSent(m, now: t0);
      expect(store.expirePending(now: t0.add(const Duration(seconds: 5))),
          isEmpty);
      final expired =
          store.expirePending(now: t0.add(const Duration(seconds: 6)));
      expect(expired, [m]);
      expect(m.status, MessageStatus.sending);
      expect(store.unfinished, [m]);
    });

    test('pending echo overflow fails the oldest message', () {
      final store = MessageStore(maxPendingEcho: 2);
      final a = send(store, 'a', 'A');
      send(store, 'b', 'B');
      send(store, 'c', 'C');
      expect(a.status, MessageStatus.failed);
      expect(store.hasPendingEcho, isTrue);
    });
  });

  group('Message persistence', () {
    test('round-trips through json', () {
      final m = Message(
        'p1',
        'User',
        'Привет',
        true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        status: MessageStatus.delivered,
        attempts: 2,
        ackStation: '8045',
      );
      final copy = Message.fromJson(m.toJson());
      expect(copy, isNotNull);
      expect(copy!.id, 'p1');
      expect(copy.text, 'Привет');
      expect(copy.isMe, isTrue);
      expect(copy.status, MessageStatus.delivered);
      expect(copy.ackStation, '8045');
      expect(copy.timestamp, m.timestamp);
    });

    test('rejects malformed json', () {
      expect(Message.fromJson(null), isNull);
      expect(Message.fromJson('x'), isNull);
      expect(Message.fromJson({'id': 1}), isNull);
    });

    test('restore keeps order and trims to maxMessages', () {
      final store = MessageStore(maxMessages: 2);
      store.restore([
        Message('1', 'A', 'one', false),
        Message('2', 'A', 'two', false),
        Message('3', 'A', 'three', false),
      ]);
      expect(store.messages.map((m) => m.id), ['2', '3']);
    });
  });
}
