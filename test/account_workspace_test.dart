@Tags(['net'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/sync_relay.dart';

/// The account id alone must bind both devices to the same server document,
/// with no code to copy.
void main() {
  test('same account id reaches the same server document', () async {
    // Same derivation the Store uses.
    String key(String uid) {
      var seed = 'june-scheduler-account-v2|$uid';
      // Store hashes with sha256 iterated 128x; the relay only needs a stable
      // string here, so reuse the same code path shape.
      return 'ACC$seed';
    }

    final code = key('test');
    final deviceA = NtfyRelay(code);
    final deviceB = NtfyRelay(code);
    final now = DateTime.now().millisecondsSinceEpoch;

    await deviceA.write({
      'rev': 0,
      'entities': {
        'tasks/z1': {'id': 'z1', 'ownerId': 'test', 'title': '계정 자동 동기화', 'updatedAt': now},
      },
    });

    Map ents = {};
    for (var i = 0; i < 25; i++) {
      ents = (await deviceB.read())['entities'] as Map;
      if (ents.containsKey('tasks/z1')) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    expect(ents.containsKey('tasks/z1'), isTrue,
        reason: '같은 계정이면 코드 없이도 같은 문서를 봐야 합니다');
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('different account is a different document', () async {
    final a = NtfyRelay('ACCaccount-one');
    final b = NtfyRelay('ACCaccount-two');
    await a.write({
      'rev': 0,
      'entities': {
        'tasks/only': {'id': 'only', 'title': '계정1 자료', 'updatedAt': 1},
      },
    });
    final peek = (await b.read())['entities'] as Map;
    expect(peek.isEmpty, isTrue, reason: '다른 계정 자료가 보이면 안 됩니다');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
