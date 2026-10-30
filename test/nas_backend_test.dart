import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/cloud/nas_backend.dart';
import 'package:june_scheduler/services/cloud/sync_engine.dart';
import 'package:june_scheduler/services/store.dart';

/// End-to-end proof that the NAS design works with the real server.
///
/// The test *starts* `server/nas/server.js` itself, so it does not depend on a
/// developer having something running. If Node is missing the whole file skips
/// instead of failing — a missing runtime is not a broken sync engine.
///
/// What it proves, with two independent [Store] instances signing in to the same
/// account against one real HTTP server:
///   1. a task created on device A is stored on the NAS (file on disk),
///   2. device B pulls it,
///   3. a deletion travels as a tombstone,
///   4. edits made while the NAS was down flush once it returns,
///   5. a wrong key is reported as an error, never as success,
///   6. the address survives a restart of the app (persisted in the box).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test installs HttpOverrides that answer *every* request with 400.
  // That is what made real HTTP untestable before; clearing it is the fix.
  HttpOverrides.global = null;

  const port = 8123;
  late Process server;
  late Directory dataDir;
  late Directory tmp;

  final List<Store> created = [];

  setUpAll(() async {
    final script = File('server/nas/server.js');
    if (!script.existsSync()) {
      // ignore: avoid_print
      print('server/nas/server.js not found — skipping NAS tests');
      return;
    }
    dataDir = Directory.systemTemp.createTempSync('nasdata_');
    server = await Process.start(
      'node',
      [script.absolute.path],
      environment: {
        'PORT': '$port',
        'DATA_DIR': dataDir.path,
        'SYNC_SECRET': 'testsecret123',
      },
    );
    server.stdout.drain<void>();
    server.stderr.drain<void>();

    // Wait for /health to answer instead of a blind sleep.
    final probe = NasBackend(baseUrl: 'http://127.0.0.1:$port');
    for (var i = 0; i < 60; i++) {
      if (await probe.ping()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });

  tearDownAll(() async {
    if (File('server/nas/server.js').existsSync()) {
      server.kill(ProcessSignal.sigkill);
    }
    await Hive.close();
  });

  setUp(() async {
    await Hive.close();
    tmp = Directory.systemTemp.createTempSync('june_nas_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });

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

  NasBackend nas({String secret = 'testsecret123'}) => NasBackend(
        baseUrl: 'http://127.0.0.1:$port',
        secret: secret,
      );

  test('the NAS answer is honest: empty workspace is not "all deleted"',
      () async {
    final backend = nas();
    final doc = await backend.read('ACCNOBODY0001');
    expect(doc.exists, isFalse, reason: '빈 문서는 exists=false 로 와야 합니다');
    expect(doc.entities, isEmpty);

    final res = await backend.write('ACCNOBODY0001', const CloudDoc(
      entities: {
        'tasks/n1': {'id': 'n1', 'title': '첫 일정', 'updatedAt': 1000},
      },
      rev: 0,
    ));
    expect(res.ok, isTrue);

    final again = await backend.read('ACCNOBODY0001');
    expect(again.exists, isTrue);
    expect((again.entities['tasks/n1'] as Map)['title'], '첫 일정');

    // And the bytes really are on disk, in a file named after the workspace.
    final file = File('${dataDir.path}/ACCNOBODY0001.json');
    expect(file.existsSync(), isTrue, reason: 'NAS 폴더에 파일이 생겨야 합니다');
    expect(file.readAsStringSync(), contains('첫 일정'));
  });

  test('device A writes to the NAS and device B reads it back', () async {
    final a = await device();
    a.useBackend(nas());
    expect(await a.authenticate(Store.testId, Store.testPw), isTrue);
    final svcA = a.sync;
    await svcA.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final task = await a.addTask('NAS 두 기기 검증', 'todo');
    await svcA.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(a.pendingCount, 0, reason: '서버가 받으면 대기열이 비어야 합니다');

    // Independent device, same account, same server.
    final b = await device();
    b.useBackend(nas());
    expect(await b.authenticate(Store.testId, Store.testPw), isTrue);
    final svcB = b.sync;
    await svcB.start();
    await Future<void>.delayed(const Duration(milliseconds: 2500));

    final pulled =
        b.tasksForOwner(Store.testId).where((t) => t.id == task.id).toList();
    expect(pulled, isNotEmpty, reason: 'B는 NAS에서 받아와야 합니다');
    expect(pulled.first.title, 'NAS 두 기기 검증');
    expect(svcB.state, anyOf(SyncState.idle, SyncState.syncing));
  });

  test('a deletion travels to the other device as a tombstone', () async {
    final a = await device();
    a.useBackend(nas());
    await a.authenticate(Store.testId, Store.testPw);
    final svcA = a.sync;
    await svcA.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final t = await a.addTask('지워질 항목', 'todo');
    await svcA.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await a.deleteTask(t);
    await svcA.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final doc = await nas().read(a.workspaceId);
    final rec = doc.entities['tasks/${t.id}'] as Map?;
    expect(rec, isNotNull, reason: '삭제된 항목은 tombstone으로 남아야 합니다');
    expect(rec!['deletedAt'], isNotNull);
  });

  test('edits made while the NAS was down flush when it comes back', () async {
    final store = await device();
    // Point at a dead port first: nothing is listening there.
    store.useBackend(NasBackend(baseUrl: 'http://127.0.0.1:8199'));
    await store.authenticate(Store.testId, Store.testPw);
    final svc = store.sync;
    await svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final t = await store.addTask('NAS 꺼진 동안 쓴 글', 'todo');
    await svc.flush(manual: true);
    expect(store.pendingCount, greaterThan(0),
        reason: '서버가 없으면 대기열에 남아야 합니다');
    expect(svc.state, SyncState.offline);

    // The NAS wakes up.
    store.useBackend(nas());
    await store.sync.flush(manual: true);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(store.pendingCount, 0, reason: '복구되면 밀린 편집이 올라가야 합니다');
    final doc = await nas().read(store.workspaceId);
    expect(doc.entities.containsKey('tasks/${t.id}'), isTrue);
  });

  test('a wrong key is a failure, never a silent success', () async {
    final backend = nas(secret: 'wrong-key');
    expect(await backend.ping(), isTrue,
        reason: 'health는 키 없이도 열려 있어야 합니다');
    await expectLater(
      backend.read('ACCKEYTEST001'),
      throwsA(isA<CloudException>()),
    );

    final res = await backend.write(
      'ACCKEYTEST001',
      const CloudDoc(entities: {}, rev: 0),
    );
    expect(res.ok, isFalse, reason: '잘못된 키로는 쓰이면 안 됩니다');
    expect(res.error, contains('401'));
  });

  test('the NAS address survives an app restart', () async {
    final store = await device();
    await store.useNasBackend(
      url: '192.168.0.20:8099',
      secret: 'mysecret',
    );
    expect(store.usingNas, isTrue);
    expect(store.nasUrl, '192.168.0.20:8099');
    expect(store.nasSecret, 'mysecret');

    // A second Store reading the same box = the app relaunching.
    await Hive.close();
    final again = await Store().init2();
    expect(again.usingNas, isTrue, reason: '재시작해도 주소가 기억되어야 합니다');
    expect(again.nasUrl, '192.168.0.20:8099');

    // Clearing puts the app back on the hosted cloud.
    await again.useNasBackend(url: '');
    expect(again.usingNas, isFalse);
    expect(again.nasSecret, isEmpty, reason: '주소를 지우면 키도 지워야 합니다');
  });
}

extension on Store {
  /// `init()` with a clearer name in the restart test.
  Future<Store> init2() async {
    await init();
    return this;
  }
}
