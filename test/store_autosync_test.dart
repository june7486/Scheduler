import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Store.init() uses Hive.initFlutter(), which asks path_provider for a
    // directory. Provide one so the store can boot headlessly.
    final dir = Directory.systemTemp.createTempSync('hive_autosync_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
  });

  test('signing in binds the account to its own workspace automatically',
      () async {
    final store = Store();
    await store.init();
    addTearDown(() => store.dispose());

    expect(store.syncEnabled, isFalse, reason: '로그인 전에는 꺼져 있어야 합니다');

    final ok = await store.authenticate(Store.testId, Store.testPw);
    expect(ok, isTrue);

    // No code, no toggle: it must now be on and bound to this account.
    expect(store.syncEnabled, isTrue);
    expect(store.syncCode, isNotEmpty);
    expect(store.syncCode.startsWith('ACC'), isTrue,
        reason: '계정에서 유도한 키여야 합니다');
    expect(store.syncOwnerId, Store.testId);

    // The same account on another device derives the same key.
    final other = Store();
    await other.init();
    await other.authenticate(Store.testId, Store.testPw);
    expect(other.syncCode, store.syncCode,
        reason: '같은 계정이면 코드 입력 없이 같은 문서에 붙어야 합니다');
  });

  test('workspace key is derived from the account, not from local state',
      () {
    // Two Stores in one test share one Hive database, so comparing live
    // instances proves nothing. Compare the derivation directly.
    final a = Store.workspaceCodeFor(Store.testId);
    final b = Store.workspaceCodeFor(Store.masterId);

    expect(a, isNot(b), reason: '계정이 다르면 문서도 달라야 합니다');
    expect(a, startsWith('ACC'));
    expect(b, startsWith('ACC'));
    // Deterministic: the same account always lands on the same document.
    expect(Store.workspaceCodeFor(Store.testId), a);
    expect(a.length, greaterThan(20), reason: '추측 불가능한 길이여야 합니다');
  });

  test('pending outbox marks writes until the server acks them', () async {
    final store = Store();
    await store.init();
    await store.authenticate(Store.testId, Store.testPw);

    final before = store.pendingCount;
    final t = await store.addTask('서버 저장 테스트', 'todo');

    expect(store.pendingCount, greaterThan(before),
        reason: '새 항목은 서버 전송 대기열에 들어가야 합니다');
    expect(store.pendingSnapshot(Store.testId)
        .containsKey('tasks/${t.id}'), isTrue);

    // Simulate the server acknowledging it.
    await store.clearPending(['tasks/${t.id}']);
    expect(store.pendingSnapshot(Store.testId)
        .containsKey('tasks/${t.id}'), isFalse);
  });
}
