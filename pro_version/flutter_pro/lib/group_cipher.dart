import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/pointycastle.dart'
    show AEADParameters, KeyParameter;

/// Шифрование текста общим ключом группы. Прошивка (ESP32) пересылает
/// зашифрованный текст как есть — для неё это обычная строка.
///
/// Формат в эфире: `#e1.<base64url(nonce(12) || ciphertext || tag(16))>`.
/// Префикс без ':' — не ломает разбор кадра `<имя>:<id>:<текст>`.
/// AES-256-GCM, ключ = SHA-256(парольная фраза). Накладные расходы —
/// 28 байт плюс base64 (~4/3 от длины шифротекста).
class GroupCipher {
  GroupCipher(String passphrase, {Random? random})
      : _key =
            Uint8List.fromList(sha256.convert(utf8.encode(passphrase)).bytes),
        _random = random ?? Random.secure();

  static const String prefix = '#e1.';
  static const int _nonceLen = 12;
  static const int _tagBits = 128;

  final Uint8List _key;
  final Random _random;

  /// Короткий отпечаток ключа для сверки между абонентами («у всех 3F9A?»).
  String get fingerprint =>
      sha256.convert(_key).toString().substring(0, 4).toUpperCase();

  static bool isEncrypted(String text) => text.startsWith(prefix);

  String encrypt(String plaintext) {
    final nonce = Uint8List(_nonceLen);
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = _random.nextInt(256);
    }
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true,
          AEADParameters(KeyParameter(_key), _tagBits, nonce, Uint8List(0)));
    final out = cipher.process(Uint8List.fromList(utf8.encode(plaintext)));
    final packed = Uint8List(nonce.length + out.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, out);
    return '$prefix${base64Url.encode(packed)}';
  }

  /// null, если текст не расшифровывается этим ключом (другой ключ или
  /// повреждение). Незашифрованный текст возвращается как есть.
  String? decrypt(String text) {
    if (!isEncrypted(text)) return text;
    Uint8List packed;
    try {
      packed =
          base64Url.decode(base64Url.normalize(text.substring(prefix.length)));
    } on FormatException {
      return null;
    }
    if (packed.length < _nonceLen + _tagBits ~/ 8) return null;
    final nonce = packed.sublist(0, _nonceLen);
    final body = packed.sublist(_nonceLen);
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(false,
            AEADParameters(KeyParameter(_key), _tagBits, nonce, Uint8List(0)));
      return utf8.decode(cipher.process(body));
    } catch (_) {
      return null;
    }
  }
}
