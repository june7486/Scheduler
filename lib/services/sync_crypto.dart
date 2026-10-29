import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// Payload protection for relays that are not private by nature (public topic
/// style backends). The key is derived from the workspace code, which is the
/// only secret the two devices already share — nothing extra to type in.
///
/// Format: base64( iv[16] || AES-256-CBC(pkcs7) )
class SyncCrypto {
  SyncCrypto(String code) : _key = _derive(code);

  final enc.Key _key;

  /// Iterated SHA-256 so a short-ish code still yields a well distributed key.
  static enc.Key _derive(String code) {
    var seed = utf8.encode('june-scheduler-sync-v1|${code.toUpperCase()}');
    var digest = sha256.convert(seed);
    for (var i = 0; i < 512; i++) {
      digest = sha256.convert([...digest.bytes, ...seed]);
    }
    return enc.Key(Uint8List.fromList(digest.bytes));
  }

  static final _rnd = Random.secure();

  String encryptJson(Object value) {
    final iv = enc.IV(Uint8List.fromList(
      List<int>.generate(16, (_) => _rnd.nextInt(256)),
    ));
    final encrypter = enc.Encrypter(enc.AES(_key, mode: enc.AESMode.cbc));
    final cipher = encrypter.encrypt(jsonEncode(value), iv: iv);
    return base64Encode([...iv.bytes, ...cipher.bytes]);
  }

  /// Returns null when the payload is not ours / was tampered with.
  Object? decryptJson(String blob) {
    try {
      final raw = base64Decode(blob.trim());
      if (raw.length <= 16) return null;
      final iv = enc.IV(Uint8List.fromList(raw.sublist(0, 16)));
      final data = enc.Encrypted(Uint8List.fromList(raw.sublist(16)));
      final encrypter = enc.Encrypter(enc.AES(_key, mode: enc.AESMode.cbc));
      final clear = encrypter.decrypt(data, iv: iv);
      return jsonDecode(clear);
    } catch (_) {
      return null;
    }
  }
}
