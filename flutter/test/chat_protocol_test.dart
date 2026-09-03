import 'package:flutter_test/flutter_test.dart';
import 'package:radio_bridge_dual/chat_protocol.dart';

void main() {
  group('buildMessageFrame', () {
    test('new frame includes id', () {
      final frame = buildMessageFrame('User', 'Hello', id: 'abc123');
      expect(frame, 'msg:User:abc123:Hello');
    });

    test('legacy frame omits id', () {
      final frame = buildMessageFrame('User', 'Hello');
      expect(frame, 'msg:User:Hello');
    });
  });

  group('parseIncomingFrame', () {
    test('parses new from:<id>:text', () {
      final f = parseIncomingFrame('User:abc123:Hello world');
      expect(f.kind, IncomingKind.chat);
      expect(f.from, 'User');
      expect(f.id, 'abc123');
      expect(f.text, 'Hello world');
      expect(f.echoKey, 'abc123');
    });

    test('parses legacy from:text', () {
      final f = parseIncomingFrame('User:Hello world');
      expect(f.kind, IncomingKind.chat);
      expect(f.from, 'User');
      expect(f.id, '');
      expect(f.text, 'Hello world');
      expect(f.echoKey, 'User:Hello world');
    });

    test('parses history with id', () {
      final f = parseIncomingFrame('hist:User:abc123:Hello');
      expect(f.kind, IncomingKind.chat);
      expect(f.from, 'User');
      expect(f.id, 'abc123');
      expect(f.text, 'Hello');
      expect(f.isHistory, true);
    });

    test('ignores empty frames', () {
      expect(parseIncomingFrame('').kind, IncomingKind.ignore);
      expect(parseIncomingFrame('   ').kind, IncomingKind.ignore);
    });

    test('pings are recognized', () {
      expect(parseIncomingFrame('ping').kind, IncomingKind.ping);
    });

    test('system messages are recognized', () {
      final f = parseIncomingFrame('System:Radio ready');
      expect(f.kind, IncomingKind.system);
      expect(f.text, 'Radio ready');
    });
  });

  group('echoKeyFor', () {
    test('returns id when present', () {
      expect(echoKeyFor('User', 'Hello', id: 'x1'), 'x1');
    });

    test('falls back to name:text without id', () {
      expect(echoKeyFor('User', 'Hello'), 'User:Hello');
    });
  });

  group('messageFitsFrame', () {
    test('counts bytes correctly for cyrillic with id', () {
      const name = 'User';
      const text = 'Проверка'; // 16 bytes UTF-8
      const id = 'abc123'; // 6 bytes
      // 'msg:' + 'User' + ':' + id + ':' + text
      // = 4 + 4 + 1 + 6 + 1 + 16 = 32 bytes
      expect(messageFitsFrame(name, text, id: id), true);
    });
  });
}
