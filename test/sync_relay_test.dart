@Tags(['net'])
library;


import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/sync_crypto.dart';
import 'package:june_scheduler/services/sync_relay.dart';

/// End-to-end check of the real transport, exercising exactly what the browser
/// does: one write, then reads that must see the record. Two relay instances
/// with the same code simulate two devices.
void main() {
  test('device A write is visible to device B', () async {
    final code = 'AB${DateTime.now().millisecondsSinceEpoch % 100000}';
    final a = NtfyRelay(code);
    final b = NtfyRelay(code);
    final now = DateTime.now().millisecondsSinceEpoch;

    await a.write({
      'rev': 1,
      'entities': {
        'tasks/a1': {'id': 'a1', 'ownerId': 'u1', 'title': 'A 작업', 'updatedAt': now},
        'categories/u1::c1': {
          'id': 'c1',
          'ownerId': 'u1',
          'name': '업무',
          'updatedAt': now,
        },
      },
    });

    var doc = await b.read();
    for (var i = 0; i < 15 && doc.entities.length < 2; i++) {
      await Future.delayed(const Duration(seconds: 2));
      doc = await b.read();
    }
    expect(doc.entities.length, 2, reason: 'B가 A의 기록을 못 봤습니다');
    expect(doc.authoritative, isTrue);
    expect((doc.entities['tasks/a1'] as Map)['title'], 'A 작업');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('B writes without pulling first — A is not erased', () async {
    final code = 'MG${DateTime.now().millisecondsSinceEpoch % 100000}';
    final a = NtfyRelay(code);
    final b = NtfyRelay(code);
    final now = DateTime.now().millisecondsSinceEpoch;

    await a.write({
      'rev': 1,
      'entities': {
        'tasks/a1': {'id': 'a1', 'ownerId': 'u1', 'title': 'A', 'updatedAt': now},
      },
    });
    // let ntfy replicate
    for (var i = 0; i < 15; i++) {
      final d = await a.read();
      if (d.entities.containsKey('tasks/a1')) break;
      await Future.delayed(const Duration(seconds: 2));
    }

    await b.write({
      'rev': 0,
      'entities': {
        'tasks/b1': {'id': 'b1', 'ownerId': 'u1', 'title': 'B', 'updatedAt': now + 5},
      },
    });

    // ntfy replicates between nodes with a short delay; give the new document
    // time to become visible cluster-wide before asserting.
    var seen = await a.read();
    for (var i = 0; i < 15 && !seen.entities.containsKey('tasks/b1'); i++) {
      await Future.delayed(const Duration(seconds: 2));
      seen = await a.read();
    }
    expect(seen.entities.containsKey('tasks/a1'), isTrue,
        reason: 'A의 기록이 사라졌습니다');
    expect(seen.entities.containsKey('tasks/b1'), isTrue,
        reason: 'B의 기록이 서버에 없습니다');
    expect(seen.entities.length, 2);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('a torn write never prunes the cache (unknown != empty)', () async {
    // Nothing was ever written to this topic.
    final fresh = NtfyRelay('EMPTY${DateTime.now().millisecondsSinceEpoch % 100000}');
    final doc = await fresh.read();
    expect(doc.entities.isEmpty, isTrue);
    expect(doc.authoritative, isFalse,
        reason: '빈 응답을 "전부 삭제됨"으로 해석하면 안 됩니다');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('large workspace is sharded and reassembled', () async {
    final code = 'BG${DateTime.now().millisecondsSinceEpoch % 100000}';
    final relay = NtfyRelay(code);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ents = <String, dynamic>{};
    for (var i = 0; i < 50; i++) {
      ents['tasks/t$i'] = {
        'id': 't$i',
        'ownerId': 'u1',
        'title': '항목 $i',
        'note': '메모 내용입니다 ' * 2,
        'updatedAt': now + i,
      };
    }
    await relay.write({'rev': 1, 'entities': ents});

    final reader = NtfyRelay(code);
    var back = <String, dynamic>{};
    for (var i = 0; i < 20; i++) {
      back = (await reader.read()).entities;
      if (back.length >= 50) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    expect(back.length, 50);
    expect((back['tasks/t49'] as Map)['title'], '항목 49');
  }, timeout: const Timeout(Duration(seconds: 150)));

  test('wrong code cannot read the workspace', () async {
    final relay = NtfyRelay('GOOD${DateTime.now().millisecondsSinceEpoch % 100000}');
    final other = NtfyRelay('BAD${DateTime.now().millisecondsSinceEpoch % 100000}');
    await relay.write({
      'rev': 1,
      'entities': {
        'tasks/x': {'id': 'x', 'title': '비밀', 'updatedAt': 1},
      },
    });
    final peek = await other.read();
    expect(peek.entities.isEmpty, isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('crypto round-trip', () {
    final c = SyncCrypto('ABCDEFGH12');
    final blob = c.encryptJson({'a': 1, '한글': '값'});
    expect(c.decryptJson(blob), {'a': 1, '한글': '값'});
    expect(SyncCrypto('WRONGCODE1').decryptJson(blob), isNull);
  });
}
