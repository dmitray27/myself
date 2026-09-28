import 'package:flutter_test/flutter_test.dart';
import 'package:radio_bridge_dual/history_store.dart';
import 'package:radio_bridge_dual/message_store.dart';

void main() {
  group('history encode/decode', () {
    test('round-trip preserves messages and statuses', () {
      final list = [
        Message('1', 'User', 'Привет', true,
            timestamp: DateTime(2026, 1, 2, 3, 4, 5),
            status: MessageStatus.delivered,
            ackStation: '8045'),
        Message('2', 'Remote', 'Ответ', false,
            timestamp: DateTime(2026, 1, 2, 3, 5)),
        Message('3', 'User', 'Ещё', true, status: MessageStatus.noack),
      ];
      final decoded = decodeHistory(encodeHistory(list));
      expect(decoded.length, 3);
      expect(decoded[0].status, MessageStatus.delivered);
      expect(decoded[0].ackStation, '8045');
      expect(decoded[1].isMe, isFalse);
      expect(decoded[2].status,
          MessageStatus.failed); // ACK после перезапуска не придёт
    });

    test('corrupt data yields empty list, bad entries are skipped', () {
      expect(decodeHistory(''), isEmpty);
      expect(decodeHistory('not json'), isEmpty);
      expect(decodeHistory('{"a":1}'), isEmpty);
      final mixed = decodeHistory(
          '[{"id":"1","from":"A","text":"ok","me":false,"ts":1,"st":"delivered"},'
          '5, {"id":2}]');
      expect(mixed.length, 1);
      expect(mixed.single.text, 'ok');
    });

    test('unknown status falls back safely', () {
      final list = decodeHistory(
          '[{"id":"1","from":"A","text":"ok","me":true,"ts":1,"st":"???"}]');
      expect(list.length, 1);
    });
  });

  group('MemoryHistoryStore', () {
    test('save then load', () async {
      final store = MemoryHistoryStore();
      await store.save([Message('1', 'A', 'x', false)]);
      final loaded = await store.load();
      expect(loaded.single.id, '1');
    });
  });

  group('formatHistory', () {
    test('lists messages with delivery status for own ones', () {
      final text = formatHistory([
        Message('1', 'User', 'Привет', true,
            timestamp: DateTime(2026, 1, 2, 3, 4, 5),
            status: MessageStatus.delivered,
            ackStation: '8045'),
        Message('2', 'Remote', 'Ответ', false,
            timestamp: DateTime(2026, 1, 2, 3, 5, 0)),
      ], myName: 'User');
      expect(text, contains('история (User)'));
      expect(text,
          contains('[2026-01-02 03:04:05] User: Привет — доставлено (8045)'));
      expect(text, contains('[2026-01-02 03:05:00] Remote: Ответ\n'));
      expect(text, isNot(contains('Remote: Ответ —')));
    });
  });
}
