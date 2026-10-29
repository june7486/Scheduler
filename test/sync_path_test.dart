// ignore_for_file: avoid_print
@Tags(['net'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/store.dart';
import 'package:june_scheduler/services/sync_relay.dart';
import 'package:june_scheduler/services/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // flutter_test installs an HttpOverrides that answers EVERY request with
    // 400 ("no network will actually be made"). These tests must reach the
    // real relay, so drop it.
    HttpOverrides.global = null;
    final dir = Directory.systemTemp.createTempSync('hive_path_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
  });

  test('REAL PATH: login -> edit -> server actually holds the record', () async {
    HttpOverrides.global = null;
    final store = Store();
    await store.init();
    expect(await store.authenticate(Store.testId, Store.testPw), isTrue);

    print('LOGIN: user=${store.currentUserId} on=${store.syncEnabled} '
        'code=${store.syncCode}');

    // Use the engine the app itself created, exactly like production.
    final svc = store.sync;
    print('URL: stored="${store.syncUrl}" effective="${svc.baseUrl}"');
    await svc.tick(manual: true);
    print('TICK1: state=${svc.state} msg="${svc.message}" '
        'pending=${store.pendingCount}');

    final t = await store.addTask('실제 경로 검증 항목', 'todo');
    print('ADD: pending=${store.pendingCount} keys=${store.pendingKeys}');
    final snap = store.pendingSnapshot(store.currentUserId);
    print('SNAPSHOT: ${snap.length} ${snap.keys}');

    await svc.tick(manual: true);
    // The engine may still be busy with the login cycle; it schedules a
    // follow-up pass automatically. Wait for convergence like the UI does.
    for (var i = 0; i < 40 && store.pendingCount > 0; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      await svc.tick();
    }
    print('TICK2: state=${svc.state} msg="${svc.message}" '
        'pending=${store.pendingCount}');

    expect(store.pendingCount, 0,
        reason: '서버가 받아들였다면 대기열이 비어야 합니다');

    // Independent read-back from the server.
    final verifier = NtfyRelayProbe(store.syncCode);
    final remote = await verifier.entities();
    print('SERVER: ${remote.length} records');
    expect(remote.containsKey('tasks/${t.id}'), isTrue,
        reason: '서버에 실제로 저장되어야 합니다');
    expect((remote['tasks/${t.id}'] as Map)['title'], '실제 경로 검증 항목');
  }, timeout: const Timeout(Duration(seconds: 240)));

  test('REAL PATH: after a reload the session restores and sync keeps working',
      () async {
    HttpOverrides.global = null;
    final store = Store();
    await store.init(); // fresh page load
    await store.setCurrentUser(Store.testId);
    print('RESTORE: user="${store.currentUserId}" on=${store.syncEnabled}');

    expect(store.currentUserId, Store.testId,
        reason: '새로고침 후에도 사용자가 복원되어야 합니다');
    expect(store.syncEnabled, isTrue);

    final svc = store.sync;
    await svc.tick(manual: true);
    print('TICK: state=${svc.state} msg="${svc.message}"');
    expect(svc.state, isNot(SyncState.offline),
        reason: '복원 후에는 오프라인이면 안 됩니다');
  }, timeout: const Timeout(Duration(seconds: 240)));

  test('tick never claims success without a signed-in user', () async {
    final store = Store();
    await store.init();
    final svc = SyncService(store);
    await svc.tick(manual: true);
    expect(svc.state, SyncState.offline,
        reason: '로그인 없이 성공한 척하면 안 됩니다');
    expect(svc.lastSync, isNull);
  }, timeout: const Timeout(Duration(seconds: 60)));
}

/// Minimal server-side read used to verify independently of the app code.
class NtfyRelayProbe {
  NtfyRelayProbe(this.code);
  final String code;
  Future<Map> entities() async {
    final relay = _build();
    final st = await relay.read();
    return st.entities;
  }

  dynamic _build() {
    // Reuse the production relay so the probe reads the same document.
    return NtfyRelayFactory.of(code);
  }
}
