import 'package:flutter_test/flutter_test.dart';
import 'package:radio_bridge_dual/chat_protocol.dart';
import 'package:radio_bridge_dual/message_store.dart';

void main() {
  group('status: frame parsing', () {
    test('parses state and detail', () {
      final f = parseIncomingFrame('status:m1:delivered:8045');
      expect(f.kind, IncomingKind.status);
      expect(f.id, 'm1');
      expect(f.radioState, RadioState.delivered);
      expect(f.detail, '8045');
    });

    test('unknown state and bad id', () {
      expect(parseIncomingFrame('status:m1:weird').radioState,
          RadioState.unknown);
      expect(parseIncomingFrame('status:').kind, IncomingKind.ignore);
      expect(parseIncomingFrame('status:a b:aired').kind, IncomingKind.ignore);
    });

    test('reserved names are rejected', () {
      expect(validateName('status'), isNotNull);
      expect(validateName('peers'), isNotNull);
      expect(validateName('Дима'), isNull);
    });
  });

  group('MessageStore ACK statuses', () {
    test('echo -> accepted, aired -> delivered with station', () {
      final store = MessageStore();
      store.addOutgoing('m1', 'User', 'Hi');
      store.ingest(parseIncomingFrame('User:m1:Hi'), myName: 'User');
      expect(store.messages[0].status, MessageStatus.accepted);

      expect(store.applyStatus('m1', RadioState.aired), isTrue);
      expect(store.messages[0].status, MessageStatus.aired);

      expect(store.applyStatus('m1', RadioState.delivered, detail: '8045'),
          isTrue);
      expect(store.messages[0].status, MessageStatus.delivered);
      expect(store.messages[0].ackStation, '8045');

      // шаг назад после delivered не применяется
      expect(store.applyStatus('m1', RadioState.noack), isFalse);
      expect(store.messages[0].status, MessageStatus.delivered);
    });

    test('noack and failed, unknown id', () {
      final store = MessageStore();
      store.addOutgoing('m2', 'User', 'Hi');
      expect(store.applyStatus('m2', RadioState.noack), isTrue);
      expect(store.messages[0].status, MessageStatus.noack);
      expect(store.applyStatus('m2', RadioState.aired), isFalse);
      expect(store.applyStatus('m2', RadioState.failed), isTrue);
      expect(store.messages[0].status, MessageStatus.failed);
      expect(store.applyStatus('nope', RadioState.aired), isFalse);
    });

    test('status does not apply to foreign messages', () {
      final store = MessageStore();
      store.ingest(parseIncomingFrame('Remote:r1:Hello'), myName: 'User');
      expect(store.applyStatus('r1', RadioState.delivered), isFalse);
    });
  });
}
