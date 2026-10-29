import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/sync_crypto.dart';

void main() {
  test('round trip with korean + nested data', () {
    final c = SyncCrypto('ABCD2345XY');
    final data = {
      'rev': 7,
      'entities': {
        'tasks/t1': {'id': 't1', 'title': '한글 제목 ✓ 🔥', 'updatedAt': 1793244000000},
        'categories/test::todo': {'id': 'todo', 'label': '할일', 'updatedAt': 1793244000001},
      },
    };
    final blob = c.encryptJson(data);
    final back = c.decryptJson(blob);
    expect(jsonEncode(back), jsonEncode(data));
  });

  test('different code cannot decrypt', () {
    final a = SyncCrypto('CODEAAAAAA');
    final b = SyncCrypto('CODEBBBBBB');
    final blob = a.encryptJson({'x': 1});
    expect(b.decryptJson(blob), isNull);
  });

  test('random iv gives different ciphertext each time', () {
    final c = SyncCrypto('ABCD2345XY');
    expect(c.encryptJson({'x': 1}), isNot(c.encryptJson({'x': 1})));
  });

  test('garbage returns null instead of throwing', () {
    final c = SyncCrypto('ABCD2345XY');
    expect(c.decryptJson('not-base64!!'), isNull);
    expect(c.decryptJson(''), isNull);
  });

  test('size overhead stays shard friendly', () {
    final c = SyncCrypto('ABCD2345XY');
    final data = {'d': {'tasks/t1': {'id': 't1', 'title': 'x' * 900}}};
    final blob = c.encryptJson(data);
    expect(blob.length, lessThan(2600));
  });
}
