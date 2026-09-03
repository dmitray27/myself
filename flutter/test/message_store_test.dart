import 'package:flutter_test/flutter_test.dart';
import 'package:radio_bridge_dual/chat_protocol.dart';
import 'package:radio_bridge_dual/message_store.dart';

void main() {
  group('MessageStore echo matching', () {
    test('confirms echo by id, not by text', () {
      final store = MessageStore();

      store.addOutgoing('id1', 'User', 'Hello');
      store.addOutgoing('id2', 'User', 'Hello');

      final frame1 = parseIncomingFrame('User:id1:Hello');
      final outcome1 = store.ingest(frame1, myName: 'User');
      expect(outcome1, IngestOutcome.echoConfirmed);
      expect(store.messages[0].status, MessageStatus.delivered);

      // Второе эхо с тем же текстом, но другим id — не должно сбить счёт
      final frame2 = parseIncomingFrame('User:id2:Hello');
      final outcome2 = store.ingest(frame2, myName: 'User');
      expect(outcome2, IngestOutcome.echoConfirmed);
      expect(store.messages[1].status, MessageStatus.delivered);
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
  });
}
