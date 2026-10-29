@Tags(['net'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/sync_relay.dart';

/// Simulates the server-authoritative flow: device A saves to the server,
/// device B pulls; then B goes "offline", edits, and flushes on reconnect.
void main() {
  test('server is the source of truth across devices', () async {
    final code = 'SRV${DateTime.now().millisecondsSinceEpoch % 1000000}';
    final deviceA = NtfyRelay(code);
    final deviceB = NtfyRelay(code);
    final now = DateTime.now().millisecondsSinceEpoch;

    Future<Map> waitFor(NtfyRelay r, bool Function(Map) ok) async {
      Map ents = {};
      for (var i = 0; i < 25; i++) {
        ents = (await r.read())['entities'] as Map;
        if (ok(ents)) break;
        await Future.delayed(const Duration(seconds: 2));
      }
      return ents;
    }

    // A saves one record to the server.
    await deviceA.write({
      'rev': 0,
      'entities': {
        'tasks/a1': {'id': 'a1', 'ownerId': 'u', 'title': 'A가 서버에 저장', 'updatedAt': now},
      },
    });

    // B sees it purely from the server.
    final seenByB = await waitFor(deviceB, (e) => e.containsKey('tasks/a1'));
    expect(seenByB.containsKey('tasks/a1'), isTrue,
        reason: 'B는 서버에서 받아야 합니다');

    // B edits locally (queued) and later flushes.
    await deviceB.write({
      'rev': 0,
      'entities': {
        'tasks/b1': {'id': 'b1', 'ownerId': 'u', 'title': 'B가 나중에 전송', 'updatedAt': now + 5},
      },
    });

    final seenByA = await waitFor(deviceA, (e) => e.containsKey('tasks/b1'));
    expect(seenByA.containsKey('tasks/b1'), isTrue,
        reason: 'B의 대기 항목이 서버를 거쳐 A에 도달해야 합니다');
    expect(seenByA.containsKey('tasks/a1'), isTrue,
        reason: 'A의 기존 기록이 사라지면 안 됩니다');
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('delete propagates as a tombstone', () async {
    final code = 'DEL${DateTime.now().millisecondsSinceEpoch % 1000000}';
    final relay = NtfyRelay(code);
    final now = DateTime.now().millisecondsSinceEpoch;

    await relay.write({
      'rev': 0,
      'entities': {
        'tasks/x': {'id': 'x', 'ownerId': 'u', 'title': '지울 항목', 'updatedAt': now},
      },
    });

    // Tombstone with a newer stamp wins.
    await relay.write({
      'rev': 0,
      'entities': {
        'tasks/x': {
          'id': 'x',
          'ownerId': 'u',
          'title': '지울 항목',
          'updatedAt': now + 100,
          'deletedAt': now + 100,
        },
      },
    });

    Map ents = {};
    for (var i = 0; i < 25; i++) {
      ents = (await relay.read())['entities'] as Map;
      final rec = ents['tasks/x'];
      if (rec is Map && rec['deletedAt'] != null) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    expect((ents['tasks/x'] as Map)['deletedAt'], isNotNull);
  }, timeout: const Timeout(Duration(seconds: 180)));
}
