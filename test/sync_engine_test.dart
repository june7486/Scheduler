import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/cloud/sync_engine.dart';
import 'package:june_scheduler/services/store.dart';

import 'fakes/memory_backend.dart';

/// A backend that throws the moment it is touched, like Firestore does when
/// Firebase was never initialised.
class _BrokenBackend implements CloudBackend {
  @override
  String get name => 'broken';
  @override
  bool get isConfigured => throw StateError('No Firebase App');
  @override
  Future<CloudDoc> read(String workspaceId) async =>
      throw StateError('No Firebase App');
  @override
  Future<CloudWriteResult> write(String id, CloudDoc doc) async =>
      throw StateError('No Firebase App');
  @override
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
  }) =>
      throw StateError('No Firebase App');
  @override
  Future<void> dispose() async {}
}

/// Exercises the real production path: sign in, edit, and prove the record
/// reaches the cloud and comes back to a second device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  final List<Store> created = [];

  setUp(() async {
    // Hive caches open boxes by name for the whole process. Without closing
    // them, the second test would read the first test's records.
    await Hive.close();
    tmp = Directory.systemTemp.createTempSync('june_sync_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });

  // Timers started by one test fire during the next one and flutter_test
  // reports them as that test's failure. Stop every engine we created.
  tearDown(() async {
    for (final s in created) {
      s.sync.stop();
    }
    created.clear();
    await Hive.close();
  });

  Future<Store> device() async {
    final s = Store();
    await s.init();
    created.add(s);
    return s;
  }

  test('login binds the device to the account workspace', () async {
    final store = await device();
    store.useBackend(MemoryBackend());

    expect(await store.authenticate(Store.testId, Store.testPw), isTrue);

    expect(store.syncEnabled, isTrue, reason: '로그인하면 동기화가 켜져야 합니다');
    expect(store.workspaceId, isNotEmpty);
    // Deterministic: the same account always lands on the same document.
    expect(store.workspaceId, Store.workspaceCodeFor(Store.testId));
    expect(store.workspaceId, startsWith('ACC'));
  });

  test('an edit reaches the server and empties the outbox', () async {
    final backend = MemoryBackend();
    final store = await device();
    store.useBackend(backend);
    await store.authenticate(Store.testId, Store.testPw);

    final svc = store.sync;
    await svc.start();
    // The first snapshot seeds the workspace.
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final task = await store.addTask('서버 저장 검증', 'todo');
    expect(store.pendingCount, greaterThan(0), reason: '편집은 대기열에 들어가야 합니다');

    await svc.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(store.pendingCount, 0, reason: '서버가 받으면 대기열이 비어야 합니다');
    final remote = backend.raw(store.workspaceId);
    expect(remote.containsKey('tasks/${task.id}'), isTrue,
        reason: '서버 문서에 실제로 저장되어야 합니다');
    expect((remote['tasks/${task.id}'] as Map)['title'], '서버 저장 검증');
    expect(svc.state, anyOf(SyncState.idle, SyncState.syncing));
  });

  test('a second device sees the first device data', () async {
    final backend = MemoryBackend();

    final a = await device();
    a.useBackend(backend);
    await a.authenticate(Store.testId, Store.testPw);
    final svcA = a.sync;
    await svcA.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final t = await a.addTask('A가 만든 일정', 'todo');
    await svcA.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(a.pendingCount, 0);

    // A completely separate device, same account.
    final b = await device();
    b.useBackend(backend);
    await b.authenticate(Store.testId, Store.testPw);
    final svcB = b.sync;
    await svcB.start();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final fromServer = b.tasksForOwner(Store.testId)
        .where((x) => x.id == t.id)
        .toList();
    expect(fromServer, isNotEmpty, reason: 'B는 서버에서 받아야 합니다');
    expect(fromServer.first.title, 'A가 만든 일정');
    expect(b.pendingCount, 0, reason: 'B는 올릴 것이 없어야 합니다');
  });

  test('a deletion propagates as a tombstone', () async {
    final backend = MemoryBackend();
    final a = await device();
    a.useBackend(backend);
    await a.authenticate(Store.testId, Store.testPw);
    final svcA = a.sync;
    await svcA.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final t = await a.addTask('지울 항목', 'todo');
    await svcA.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await a.deleteTask(t);
    await svcA.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final remote = backend.raw(a.workspaceId);
    final rec = remote['tasks/${t.id}'] as Map?;
    expect(rec, isNotNull, reason: '삭제는 tombstone으로 남아야 합니다');
    expect(rec!['deletedAt'], isNotNull);
  });

  test('local edits survive an offline period and flush on reconnect', () async {
    final backend = MemoryBackend();
    final store = await device();
    store.useBackend(backend);
    await store.authenticate(Store.testId, Store.testPw);
    final svc = store.sync;
    await svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    backend.offline = true;
    final t = await store.addTask('오프라인 편집', 'todo');
    await svc.flush(manual: true);
    expect(store.pendingCount, greaterThan(0), reason: '오프라인이면 대기해야 합니다');

    backend.offline = false;
    await svc.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(store.pendingCount, 0, reason: '복구되면 밀린 편집이 올라가야 합니다');
    expect(backend.raw(store.workspaceId).containsKey('tasks/${t.id}'), isTrue);
  });

  test('sync never claims success when it does nothing', () async {
    // Signed out: there is no workspace, so the honest answer is "off".
    final store = await device();
    store.useBackend(MemoryBackend());
    final svc = store.sync;
    await svc.flush(manual: true);
    expect(svc.state, SyncState.off);
    expect(svc.lastSync, isNull, reason: '한 번도 동기화하지 않았습니다');
  });

  test('a broken backend reports notConfigured instead of pretending', () async {
    final store = await device();
    store.useBackend(_BrokenBackend());
    await store.authenticate(Store.testId, Store.testPw);
    final svc = store.sync;
    await svc.start();
    expect(svc.state, SyncState.notConfigured,
        reason: '설정이 없으면 그렇게 말해야 합니다');
    expect(svc.lastSync, isNull);
  });
}
