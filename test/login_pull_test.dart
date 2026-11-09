import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:june_scheduler/services/cloud/nas_backend.dart';
import 'package:june_scheduler/services/cloud/sync_engine.dart';
import 'package:june_scheduler/services/store.dart';

/// Signing in must load the server's data, not overwrite it.
///
/// Runs against a real gateway (STORAGE=local, throwaway data directory), so the
/// whole HTTP + merge path is exercised. The scenario is the user's request:
///
///   1. device A signs in and builds a workspace (task, renamed tab, a pref),
///   2. device B — a brand-new install — signs in with the same id,
///   3. B must show A's data,
///   4. A's data must still be on the server afterwards.
///
/// Step 4 is the one that used to fail: a fresh device seeded its defaults,
/// queued them, and pushed before pulling — so it could overwrite the very
/// workspace it was supposed to receive.
///
/// The two devices must not share local storage, or "B" would literally be "A".
/// [nextDevice] therefore swaps the Hive directory and closes the previous
/// instance, which is what starting the app on a second machine amounts to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const port = 8127;
  const secret = 'pulltest123';
  late Process server;
  late Directory dataDir;
  late Directory devDir;
  int devSeq = 0;

  NasBackend backend() =>
      NasBackend(baseUrl: 'http://127.0.0.1:$port', secret: secret);

  setUpAll(() async {
    final script = File('server/gateway/server.js');
    if (!script.existsSync()) return;
    dataDir = Directory.systemTemp.createTempSync('pulldata_');
    server = await Process.start(
      'node',
      [script.absolute.path],
      environment: {
        'PORT': '$port',
        'STORAGE': 'local',
        'DATA_DIR': dataDir.path,
        'SYNC_SECRET': secret,
      },
    );
    server.stdout.drain<void>();
    server.stderr.drain<void>();
    for (var i = 0; i < 60; i++) {
      if (await backend().ping()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });

  tearDownAll(() async {
    if (File('server/gateway/server.js').existsSync()) {
      server.kill(ProcessSignal.sigkill);
    }
    await Hive.close();
  });

  setUp(() async {
    await Hive.close();
    devDir = Directory.systemTemp.createTempSync('pull_dev_${devSeq++}_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => devDir.path,
    );
  });

  tearDown(() async {
    await Hive.close();
  });

  /// A completely separate install: new empty storage directory.
  Future<Store> nextDevice({NasBackend? on}) async {
    await Hive.close();
    devDir = Directory.systemTemp.createTempSync('pull_dev_${devSeq++}_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => devDir.path,
    );
    final s = Store();
    await s.init();
    s.useBackend(on ?? backend());
    return s;
  }

  bool hasServer() => File('server/gateway/server.js').existsSync();

  test('새 기기 B가 로그인하면 A의 데이터를 불러온다 (덮어쓰지 않는다)', () async {
    if (!hasServer()) {
      markTestSkipped('게이트웨이 서버 없음');
      return;
    }

    // ---- device A: build a workspace -------------------------------------
    final a = await nextDevice();
    expect(await a.authenticate(Store.testId, Store.testPw), isTrue);
    await a.sync.start();

    final made = await a.addTask('A가 만든 일정 — 동기화 확인용', 'todo');
    final todoCat = a.categoryById('todo')!;
    todoCat.label = 'A의 할일탭';
    await a.saveCategory(todoCat);
    await a.setSkinKey('ocean');
    await a.sync.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(a.pendingDataCount, 0, reason: 'A의 편집은 서버로 올라가야 합니다');

    final docAfterA = await backend().read(a.workspaceId);
    final serverCount = docAfterA.entities.length;
    expect(serverCount, greaterThan(0));
    final workspace = a.workspaceId;

    // ---- device B: a genuinely separate install -------------------------
    final b = await nextDevice();
    // `test` is the demo account, so a fresh install seeds a few sample tasks
    // for it. What matters is that A's real work is not here yet.
    expect(
      b.tasksForOwner(Store.testId).where((t) => t.id == made.id),
      isEmpty,
      reason: 'B는 A의 일정을 아직 모르는 상태여야 실험이 성립합니다',
    );
    expect(await b.authenticate(Store.testId, Store.testPw), isTrue);

    // The line under test: sign-in starts the pull.
    await b.sync.start();
    await Future<void>.delayed(const Duration(milliseconds: 900));

    // 1) B sees A's task.
    final onB = b.tasksForOwner(Store.testId).where((t) => t.id == made.id);
    expect(onB, isNotEmpty, reason: 'B가 서버의 일정을 받아와야 합니다');
    expect(onB.first.title, 'A가 만든 일정 — 동기화 확인용');

    // 2) B sees A's tab name, not the default one.
    expect(b.categoryById('todo')?.label, 'A의 할일탭',
        reason: 'B가 서버의 탭 이름을 받아와야 합니다');

    // 3) B sees A's skin preference.
    expect(b.skinKey, 'ocean', reason: '설정도 함께 따라와야 합니다');

    // 4) The server is untouched — B did not push an empty workspace.
    final docAfterB = await backend().read(workspace);
    expect(docAfterB.entities.length, serverCount,
        reason: 'B가 로그인해도 서버 레코드 수가 달라지면 안 됩니다');
    final srvTask = docAfterB.entities['tasks/${made.id}'] as Map?;
    expect(srvTask, isNotNull, reason: 'A의 일정이 서버에 그대로 있어야 합니다');
    expect(srvTask!['title'], 'A가 만든 일정 — 동기화 확인용');
    expect(b.sync.state, anyOf(SyncState.idle, SyncState.syncing));

    b.sync.stop();
    a.sync.stop();
  });

  test('B의 미전송 편집은 pull 로 사라지지 않는다', () async {
    if (!hasServer()) {
      markTestSkipped('게이트웨이 서버 없음');
      return;
    }

    final a = await nextDevice();
    await a.authenticate(Store.testId, Store.testPw);
    await a.sync.start();
    await a.addTask('서버에 있는 일정', 'todo');
    await a.sync.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final workspace = a.workspaceId;
    a.sync.stop();

    // B signs in with no server at all and writes something it cannot upload.
    final b = await nextDevice(
      on: NasBackend(baseUrl: 'http://127.0.0.1:8199', secret: secret),
    );
    await b.authenticate(Store.testId, Store.testPw);
    await b.sync.start();

    final offline = await b.addTask('오프라인에서 쓴 소중한 글', 'todo');
    await b.sync.flush(manual: true);
    expect(b.pendingDataCount, greaterThan(0),
        reason: '서버가 없으니 대기열에 남아야 합니다');

    // The real server returns.
    b.useBackend(backend());
    await b.sync.start();
    await Future<void>.delayed(const Duration(seconds: 1));

    // The local edit must have been pushed, not discarded by a pull.
    final doc = await backend().read(workspace);
    final rec = doc.entities['tasks/${offline.id}'] as Map?;
    expect(rec, isNotNull, reason: '미전송 편집은 pull 로 사라지면 안 됩니다');
    expect(rec!['title'], '오프라인에서 쓴 소중한 글');

    // A's earlier data is still there: the push merged rather than replaced.
    final titles = doc.entities.entries
        .where((e) => e.key.startsWith('tasks/'))
        .map((e) => (e.value as Map)['title'])
        .toSet();
    expect(titles, contains('서버에 있는 일정'));

    b.sync.stop();
  });

  test('서버가 비어 있으면 로컬 기본값을 올린다 (신규 계정)', () async {
    if (!hasServer()) {
      markTestSkipped('게이트웨이 서버 없음');
      return;
    }

    final fresh = await nextDevice();
    // An id nobody has used: its workspace does not exist on the server.
    final id = 'newbie${DateTime.now().millisecondsSinceEpoch % 100000}';
    expect(await fresh.addUser(id, 'pw1234', displayName: 'New'), isNull);
    expect(await fresh.authenticate(id, 'pw1234'), isTrue);

    final first = await fresh.addTask('신규 계정의 첫 일정', 'todo');
    await fresh.sync.start();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // The first poll answer is what tells the engine "this workspace is empty",
    // which is when it queues everything (including the default tabs) for upload.
    await fresh.sync.syncNow();
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final doc = await backend().read(fresh.workspaceId);
    expect(doc.entities['tasks/${first.id}'], isNotNull,
        reason: '신규 계정은 자기 데이터를 올려야 합니다');
    // Default tabs came along so the new account is usable.
    final catKeys = doc.entities.keys.where((k) => k.startsWith('categories/'));
    expect(catKeys, isNotEmpty, reason: '기본 탭도 함께 만들어져야 합니다');

    fresh.sync.stop();
  });
}
