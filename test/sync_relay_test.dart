@Tags(['net'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/sync_relay.dart';

void main() {
  test('ntfy relay writes and reads back a merged workspace', () async {
    final code = 'TEST${DateTime.now().millisecondsSinceEpoch % 100000}';
    final relay = NtfyRelay(code);

    final empty = await relay.read();
    expect((empty['entities'] as Map).isEmpty, isTrue);

    final now = DateTime.now().millisecondsSinceEpoch;
    await relay.write({
      'rev': 1,
      'entities': {
        'tasks/aaa': {'id': 'aaa', 'ownerId': 'u1', 'title': '첫 번째 할일', 'updatedAt': now},
        'tasks/bbb': {'id': 'bbb', 'ownerId': 'u1', 'title': '두 번째', 'updatedAt': now + 1},
      },
    });

    Map<dynamic, dynamic> ents = {};
    for (var i = 0; i < 20; i++) {
      ents = (await relay.read())['entities'] as Map;
      if (ents.length == 2) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    expect(ents.length, 2);
    expect((ents['tasks/aaa'] as Map)['title'], '첫 번째 할일');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a second device merges instead of overwriting', () async {
    final code = 'MERGE${DateTime.now().millisecondsSinceEpoch % 100000}';
    final a = NtfyRelay(code);
    final b = NtfyRelay(code);
    final now = DateTime.now().millisecondsSinceEpoch;

    await a.write({
      'rev': 1,
      'entities': {
        'tasks/a1': {'id': 'a1', 'title': 'A의 항목', 'updatedAt': now},
      },
    });

    // ntfy.sh replicates topics with a short delay; wait until A's record is
    // actually visible before B writes (this mirrors real polling behaviour).
    for (var i = 0; i < 20; i++) {
      final seen = (await a.read())['entities'] as Map;
      if (seen.containsKey('tasks/a1')) break;
      await Future.delayed(const Duration(seconds: 2));
    }

    // B never pulled first — it just pushes its own record.
    await b.write({
      'rev': 0,
      'entities': {
        'tasks/b1': {'id': 'b1', 'title': 'B의 항목', 'updatedAt': now + 10},
      },
    });

    final seenByB = (await b.read())['entities'] as Map;
    expect(seenByB.containsKey('tasks/a1'), isTrue,
        reason: 'A의 기록이 사라지면 안 됩니다');
    expect(seenByB.containsKey('tasks/b1'), isTrue);
    expect(seenByB.length, 2);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('large workspace is sharded and reassembled', () async {
    final code = 'BIG${DateTime.now().millisecondsSinceEpoch % 100000}';
    final relay = NtfyRelay(code);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ents = <String, dynamic>{};
    for (var i = 0; i < 60; i++) {
      ents['tasks/t$i'] = {
        'id': 't$i',
        'title': '항목 $i',
        'note': '메모 내용입니다 ' * 3,
        'updatedAt': now + i,
      };
    }
    await relay.write({'rev': 1, 'entities': ents});
    Map<dynamic, dynamic> back = {};
    for (var i = 0; i < 20; i++) {
      back = (await relay.read())['entities'] as Map;
      if (back.length == 60) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    expect(back.length, 60);
    expect((back['tasks/t59'] as Map)['title'], '항목 59');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('wrong code sees nothing', () async {
    final relay = NtfyRelay('CODEAAAAAA');
    final other = NtfyRelay('CODEBBBBBB');
    await relay.write({
      'rev': 1,
      'entities': {
        'tasks/x': {'id': 'x', 'title': '비밀', 'updatedAt': 1},
      },
    });
    final peek = await other.read();
    expect((peek['entities'] as Map).isEmpty, isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
