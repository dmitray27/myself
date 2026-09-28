import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_bridge_dual/chat_protocol.dart';
import 'package:radio_bridge_dual/group_cipher.dart';

void main() {
  group('GroupCipher', () {
    test('round-trips cyrillic text', () {
      final c = GroupCipher('секретная фраза');
      final wire = c.encrypt('Привет, эфир!');
      expect(GroupCipher.isEncrypted(wire), isTrue);
      expect(wire.contains(':'), isFalse);
      expect(c.decrypt(wire), 'Привет, эфир!');
    });

    test('same plaintext gives different wire text (random nonce)', () {
      final c = GroupCipher('k');
      expect(c.encrypt('a'), isNot(c.encrypt('a')));
    });

    test('deterministic with seeded random', () {
      final a = GroupCipher('k', random: Random(1)).encrypt('x');
      final b = GroupCipher('k', random: Random(1)).encrypt('x');
      expect(a, b);
    });

    test('wrong key returns null', () {
      final wire = GroupCipher('one').encrypt('text');
      expect(GroupCipher('two').decrypt(wire), isNull);
    });

    test('tampered or malformed payload returns null', () {
      final c = GroupCipher('k');
      final wire = c.encrypt('text');
      final tampered = wire.substring(0, wire.length - 2) +
          (wire.endsWith('A') ? 'BB' : 'AA');
      expect(c.decrypt(tampered), isNull);
      expect(c.decrypt('#e1.'), isNull);
      expect(c.decrypt('#e1.!!!not base64!!!'), isNull);
      expect(c.decrypt('#e1.AAAA'), isNull);
    });

    test('plaintext passes through decrypt unchanged', () {
      expect(GroupCipher('k').decrypt('open text'), 'open text');
      expect(GroupCipher.isEncrypted('open text'), isFalse);
    });

    test('fingerprint depends only on passphrase', () {
      expect(GroupCipher('k').fingerprint, GroupCipher('k').fingerprint);
      expect(GroupCipher('k').fingerprint, isNot(GroupCipher('K').fingerprint));
      expect(GroupCipher('k').fingerprint.length, 4);
    });

    test('encrypted 300-char cyrillic message still fits a frame', () {
      final c = GroupCipher('k');
      final text = 'Ж' * 300; // 600 байт UTF-8
      final wire = c.encrypt(text);
      expect(messageFitsFrame('a' * 15, wire, id: 'x' * 12), isTrue);
    });
  });
}
