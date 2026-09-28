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

  group('validateName', () {
    test('mirrors firmware name_is_valid', () {
      expect(validateName('Дима'), isNull);
      expect(validateName(''), isNotNull);
      expect(validateName('a:b'), isNotNull);
      expect(validateName('System'), isNotNull);
      expect(validateName('SystemAdmin'), isNotNull);
      expect(validateName('system'), isNull);
      expect(validateName('Ж' * 15), isNull);
      expect(validateName('Ж' * 16), isNotNull);
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

    test('legacy text with colon is not split into id', () {
      final f = parseIncomingFrame('User:Встреча в 12:30, приходи');
      expect(f.id, '');
      expect(f.text, 'Встреча в 12:30, приходи');
      expect(f.echoKey, 'User:Встреча в 12:30, приходи');

      final g = parseIncomingFrame('User:Внимание: сбор у входа');
      expect(g.id, '');
      expect(g.text, 'Внимание: сбор у входа');
    });

    test('id frame keeps colons inside text', () {
      final f = parseIncomingFrame('Remote:r7:Встреча в 12:30');
      expect(f.id, 'r7');
      expect(f.text, 'Встреча в 12:30');
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

  group('PRO frames', () {
    test('status with detail', () {
      final f = parseIncomingFrame('status:abc12:delivered:8045');
      expect(f.kind, IncomingKind.status);
      expect(f.id, 'abc12');
      expect(f.radioState, RadioState.delivered);
      expect(f.detail, '8045');
    });

    test('status without detail and unknown state', () {
      final f = parseIncomingFrame('status:abc12:aired');
      expect(f.radioState, RadioState.aired);
      expect(f.detail, '');
      expect(parseIncomingFrame('status:abc12:weird').radioState,
          RadioState.unknown);
      expect(parseIncomingFrame('status:abc12').kind, IncomingKind.ignore);
      expect(
          parseIncomingFrame('status:не id:aired').kind, IncomingKind.ignore);
    });

    test('stat json', () {
      final f = parseIncomingFrame(
          'stat:{"rx":5,"crc":1,"abort":0,"msgs":2,"incomplete":1,"tx":3,'
          '"acked":2,"noack":1,"rx_busy":false,"tx_busy":true,"signal_db":-12,'
          '"preamble":98,"station":"8045"}');
      expect(f.kind, IncomingKind.stat);
      final s = f.stats!;
      expect(s.rxFrames, 5);
      expect(s.crcErrors, 1);
      expect(s.rxMessages, 2);
      expect(s.rxIncomplete, 1);
      expect(s.txMessages, 3);
      expect(s.txAcked, 2);
      expect(s.txNoack, 1);
      expect(s.txBusy, isTrue);
      expect(s.rxBusy, isFalse);
      expect(s.signalDb, -12);
      expect(s.preamblePct, 98);
      expect(s.station, '8045');
      expect(s.ackPct, 66);
    });

    test('stat with bad json is ignored, missing keys default to 0', () {
      expect(parseIncomingFrame('stat:{oops').kind, IncomingKind.ignore);
      expect(parseIncomingFrame('stat:[1]').kind, IncomingKind.ignore);
      final s = parseIncomingFrame('stat:{}').stats!;
      expect(s.rxFrames, 0);
      expect(s.station, '');
    });

    test('peers list', () {
      final f = parseIncomingFrame('peers:8045=12,A1B2=340,bad,x=-1,=5');
      expect(f.kind, IncomingKind.peers);
      expect(
          f.peers, [const PeerInfo('8045', 12), const PeerInfo('A1B2', 340)]);
      expect(parseIncomingFrame('peers:').peers, isEmpty);
    });

    test('name busy / ok are system frames', () {
      final busy = parseIncomingFrame('System:name busy');
      expect(busy.kind, IncomingKind.system);
      expect(busy.text, kSystemNameBusy);
      expect(parseIncomingFrame('System:name ok').text, kSystemNameOk);
    });

    test('reserved names are rejected', () {
      for (final n in kReservedNames) {
        expect(validateName(n), isNotNull, reason: n);
      }
      expect(validateName('status1'), isNull);
    });

    test('a user named like a service prefix does not break chat parsing', () {
      // Имя "status" не пройдёт validateName, но "statusX" — обычный чат.
      final f = parseIncomingFrame('statusX:ab1:hi');
      expect(f.kind, IncomingKind.chat);
      expect(f.from, 'statusX');
    });

    test('withDecryptedText marks undecryptable and keeps echoKey', () {
      final f = parseIncomingFrame('Bob:ab1:#e1.xxxx');
      final ok = f.withDecryptedText('привет');
      expect(ok.text, 'привет');
      expect(ok.undecryptable, isFalse);
      expect(ok.echoKey, f.echoKey);
      final bad = f.withDecryptedText(null);
      expect(bad.undecryptable, isTrue);
      expect(bad.text, contains('ключ не совпадает'));
    });
  });

  group('validateApConfig', () {
    test('mirrors firmware limits', () {
      expect(validateApConfig('', 'password1'), isNotNull);
      expect(validateApConfig('a' * 33, 'password1'), isNotNull);
      expect(validateApConfig('Сеть' * 5, 'password1'), isNotNull); // 40 байт
      expect(validateApConfig('a"b', 'password1'), isNotNull);
      expect(validateApConfig('AFSK', 'short'), isNotNull);
      expect(validateApConfig('AFSK', 'a' * 64), isNotNull);
      expect(validateApConfig('AFSK', 'пароль12'), isNotNull);
      expect(validateApConfig('AFSK-TRX-1', 'afsk12345'), isNull);
      expect(validateApConfig('a' * 32, 'a' * 63), isNull);
    });
  });
}
