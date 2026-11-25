// 2.0 동기화 결함 두 개를 고정하는 시험.
//
// ## 무엇을 지키려는가
//
// ### 결함 ① 두 번째 기기에서 카테고리·일정이 사라짐
// 서버가 비어 있을 때 앱이 "이 기기도 비었네"라고 판단해 기본값을 **새로
// 만들어 올리면**, 첫 기기가 이미 만든 워크스페이스를 덮어씁니다. 사용자가
// 보기에는 두 번째 기기에서 카테고리가 사라진 것으로 보입니다.
//
// 판단 기준은 "이 기기의 로컬 박스가 비었는가"가 아니라
// **"이 기기가 그 워크스페이스를 한 번이라도 본 적이 있는가"** 여야 합니다.
//
// ### 결함 ② 여러 기기에서 기본 일정이 중복 생성됨
// 기본 일정 id 를 `uuid.v4()` 로 만들면 기기마다 다른 키가 나오고, 서버 병합은
// 키가 다르면 다른 기록으로 받아들입니다. 두 기기가 각자 만들면 4건이 남습니다.
// id 가 (소유자, 종류) 로부터 **결정적**이면 두 기기가 같은 키를 만들어 하나로
// 합쳐집니다.
//
// ## 이 시험이 지키지 않는 것
// 기존 사용자의 일정. 아래 시험은 "기본값을 새로 만들 것인가"만 봅니다.
//
// ## 왜 실제 게이트웨이를 띄우는가
// id 규칙을 시험 파일에 다시 적어 두고 그 값을 확인하면, store.dart 가 바뀌어도
// 시험이 통과합니다. 그래서 두 개의 **진짜 Store** 를 서로 다른 Hive 디렉터리에
// 세우고, 한쪽이 만든 id 를 다른 쪽이 실제로 같은 값으로 만드는지 봅니다.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/cloud/nas_backend.dart';
import 'package:june_scheduler/services/store.dart';

/// store.dart 의 `_seedTaskId` 와 **같은 규칙**이어야 합니다.
///
/// 이 함수는 store 를 부를 수 없는 곳에서 기대값을 계산하는 용도입니다.
/// 아래 시험은 이 값을 store 가 실제로 만든 id 와 대조하므로, 규칙이 한쪽만
/// 바뀌면 즉시 깨집니다.
String expectedSeedTaskId(String ownerId, String slot) {
  final digest = sha256.convert(utf8.encode('june-seed-task-v1|$ownerId|$slot'));
  final hex = digest.toString();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20, 32)}';
}

/// 기본 일정 6종. `seedRecurringBillsIfEmpty` + `seedDailyRoutinesIfEmpty` 가
/// 만드는 종류를 그대로 적었습니다.
const _billSlots = ['bill-rent', 'bill-warehouse'];
const _dailySlots = ['daily-medicine', 'daily-laundry', 'daily-clean', 'daily-bed'];
const _allSlots = [..._billSlots, ..._dailySlots];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const port = 8147;
  const secret = 'defecttest-secret-0123456789';
  late Process server;
  late Directory dataDir;
  late Directory devDir;
  late Directory hiveRoot;
  int devSeq = 0;
  int accountSeq = 0;

  NasBackend backend() =>
      NasBackend(baseUrl: 'http://127.0.0.1:$port', secret: secret);

  bool hasServer() => File('server/gateway/server.js').existsSync();

  setUpAll(() async {
    if (!hasServer()) return;
    dataDir = Directory.systemTemp.createTempSync('defectdata_');
    hiveRoot = Directory.systemTemp.createTempSync('defecthive_');
    server = await Process.start(
      'node',
      [File('server/gateway/server.js').absolute.path],
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
    if (hasServer()) server.kill(ProcessSignal.sigkill);
    await Hive.close();
  });

  /// 마지막으로 세운 기기. 다음 기기를 세우기 전에 반드시 멈춥니다.
  Store? previous;

  /// 기기를 다 쓴 뒤 폴러를 멈춥니다. `Hive.close()` 전에 반드시 부릅니다.
  Future<void> park(Store s) async {
    s.sync.stop();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    s.sync.stop();
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  setUp(() async {
    await Hive.close();
    devDir = Directory.systemTemp.createTempSync('defectdev_${devSeq++}_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => devDir.path,
    );
  });

  tearDown(() async {
    // 다음 시험 전에 이전 기기의 폴러가 살아 있으면 닫힌 박스를 건드립니다.
    if (previous != null) {
      await park(previous!);
      previous = null;
    }
    await Hive.close();
  });

  /// 완전히 별개의 설치. 새 저장 디렉터리 = 다른 기기.
  ///
  /// ## 왜 이전 기기를 확실히 세워 두는가
  /// 로그인([Store.authenticate])은 동기화를 스스로 시작합니다. 그러니 기기를
  /// 바꿀 때 이전 기기의 폴러를 그냥 두면, 닫힌 Hive 박스를 건드려
  /// `HiveError: Box has already been closed` 로 시험이 죽습니다. 실제 앱에서는
  /// 한 탭이 한 기기라 이 문제가 없지만, 한 프로세스에 기기 둘을 세우는
  /// 시험에서는 반드시 정리해야 합니다.
  Future<Store> nextDevice({NasBackend? on}) async {
    if (previous != null) {
      await park(previous!);
      previous = null;
    }
    await Hive.close();
    devDir = Directory.systemTemp.createTempSync('defectdev_${devSeq++}_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => devDir.path,
    );
    Hive.init(hiveRoot.path);
    final s = Store();
    await s.init();
    s.useBackend(on ?? backend());
    previous = s;
    return s;
  }


  /// 이 시험 전용 계정 id. 시험끼리 워크스페이스가 섞이지 않게 매번 새로 만듭니다.
  String freshAccountId() =>
      'dft${DateTime.now().millisecondsSinceEpoch % 1000000}${accountSeq++}';

  /// 동기화가 서버를 한 번 확인할 때까지 기다립니다.
  Future<void> waitForServerSeen(Store s) async {
    for (var i = 0; i < 40; i++) {
      if (s.cachedRev > 0 || s.cachedGen > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  group('결함 ② 기본 일정 id 가 결정적이다 (실제 Store 두 개로 확인)', () {
    test('서로 다른 기기가 같은 소유자에 대해 같은 id 를 만든다', () async {
      if (!hasServer()) {
        markTestSkipped('게이트웨이 서버 없음');
        return;
      }

      final id = freshAccountId();

      // ---- 기기 A: 동기화를 켜고 서버를 본 뒤 기본 일정을 만든다 ----
      final a = await nextDevice();
      expect(await a.addUser(id, 'pw1234', displayName: 'A'), isNull);
      expect(await a.authenticate(id, 'pw1234'), isTrue);
      await a.sync.start();
      await waitForServerSeen(a);
      expect(a.cachedRev > 0 || a.cachedGen > 0, isTrue,
          reason: '기본 일정을 만들려면 서버를 먼저 봐야 합니다');
      expect(await a.seedDefaultsOnceAfterSync(), isTrue);

      final aTasks = a.tasksForOwner(id);
      final billIds = aTasks
          .where((t) => t.categoryId == 'repeat')
          .map((t) => t.id)
          .toSet();
      final dailyIds = aTasks
          .where((t) => t.categoryId == 'daily')
          .map((t) => t.id)
          .toSet();
      expect(billIds.length, 2, reason: '월세·창고비 두 건');
      expect(dailyIds.length, 4, reason: '일상 루틴 네 건');

      // store 가 만든 id 가 규칙과 일치하는가.
      expect(billIds, _billSlots.map((s) => expectedSeedTaskId(id, s)).toSet());
      expect(dailyIds, _dailySlots.map((s) => expectedSeedTaskId(id, s)).toSet());

      await a.sync.flush(manual: true);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final workspace = a.workspaceId;
      await park(a);

      // ---- 기기 B: 서버를 못 본 채(오프라인) 같은 계정의 기본 일정을 만든다 ----
      // 실제 사용자 시나리오: 두 번째 기기를 네트워크 없이 켜서 기본 일정이
      // 생겼고, 나중에 연결되었습니다. 그때 만드는 키가 A 와 같아야 병합에서
      // 중복이 생기지 않습니다.
      final b = await nextDevice();
      expect(await b.addUser(id, 'pw1234', displayName: 'A'), isNull);
      expect(await b.authenticate(id, 'pw1234'), isTrue);
      // 서버를 보지 못한 상태를 강제합니다.
      await b.setSyncConfig(enabled: false);
      await park(b);
      expect(b.syncEnabled, isFalse);
      expect(await b.seedDefaultsOnceAfterSync(), isTrue,
          reason: '동기화를 쓰지 않는 기기는 자기 자신이 유일한 진실입니다');

      final bBillIds = b
          .tasksForOwner(id)
          .where((t) => t.categoryId == 'repeat')
          .map((t) => t.id)
          .toSet();
      expect(bBillIds, billIds,
          reason: '기기가 달라도 같은 키여야 병합에서 하나가 됩니다');

      // ---- B 의 봉투를 서버에 직접 합쳐 본다: 6건이어야 한다 ----
      final merged = await backend().write(
        workspace,
        CloudDoc(entities: b.syncSnapshot(id), rev: 0, gen: 0),
      );
      expect(merged.ok, isTrue, reason: '병합 자체는 성공해야 합니다');

      final seedIds = _allSlots.map((s) => expectedSeedTaskId(id, s)).toSet();
      final after = await backend().read(workspace);
      final seedOnServer = after.entities.keys
          .where((k) => k.startsWith('tasks/') && seedIds.contains(k.substring(6)))
          .toSet();
      expect(seedOnServer.length, 6,
          reason: '두 기기가 각자 만들어도 서버에는 6건만 남아야 합니다 '
              '(uuid.v4() 였다면 12건이 됩니다)');
    });

    test('기본 일정을 두 번 채워도 늘어나지 않는다', () async {
      if (!hasServer()) {
        markTestSkipped('게이트웨이 서버 없음');
        return;
      }

      final id = freshAccountId();
      final s = await nextDevice();
      expect(await s.addUser(id, 'pw1234', displayName: 'S'), isNull);
      expect(await s.authenticate(id, 'pw1234'), isTrue);
      await s.sync.start();
      await waitForServerSeen(s);

      expect(await s.seedDefaultsOnceAfterSync(), isTrue);
      final first = s.tasksForOwner(id).length;

      // 같은 세션에서 다시 불러도 한 번만 만듭니다.
      expect(await s.seedDefaultsOnceAfterSync(), isTrue);
      expect(s.tasksForOwner(id).length, first,
          reason: '_seededThisSession 이 두 번째를 막아야 합니다');

      // 시딩 함수를 직접 다시 불러도, 이미 있으므로 아무것도 만들지 않습니다.
      await s.seedRecurringBillsIfEmpty();
      await s.seedDailyRoutinesIfEmpty();
      expect(s.tasksForOwner(id).length, first,
          reason: '이미 12일 반복·daily 일정이 있으면 스스로 빠져나가야 합니다');
      await park(s);
    });

    test('기본 일정 id 는 uuid 형태를 유지한다 — 기존 정렬·표시 코드 보호', () async {
      const id = 'rnk7558';
      for (final slot in _allSlots) {
        final v = expectedSeedTaskId(id, slot);
        expect(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
                  r'[0-9a-f]{4}-[0-9a-f]{12}$')
              .hasMatch(v),
          isTrue,
          reason: '$slot → $v 가 uuid 형태가 아닙니다',
        );
      }
      // 6종이 서로 겹치지 않아야 하나가 다른 하나를 덮지 않습니다.
      expect(_allSlots.map((s) => expectedSeedTaskId(id, s)).toSet().length,
          _allSlots.length);
    });
  });

  group('결함 ① 두 번째 기기가 첫 기기의 카테고리·일정을 지우지 않는다', () {
    test('B 가 로그인해도 A 의 일정·탭 이름·서버 레코드 수가 그대로다', () async {
      if (!hasServer()) {
        markTestSkipped('게이트웨이 서버 없음');
        return;
      }

      final id = freshAccountId();

      // ---- 기기 A: 워크스페이스를 만든다 ----
      final a = await nextDevice();
      expect(await a.addUser(id, 'pw1234', displayName: 'A'), isNull);
      expect(await a.authenticate(id, 'pw1234'), isTrue);
      await a.sync.start();
      await waitForServerSeen(a);

      final made = await a.addTask('A가 만든 일정 — 결함 ① 확인용', 'todo');
      final todo = a.categoryById('todo')!;
      todo.label = 'A의 할일탭';
      await a.saveCategory(todo);
      await a.sync.flush(manual: true);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final workspace = a.workspaceId;
      final serverBefore = await backend().read(workspace);
      final countBefore = serverBefore.entities.length;
      expect(countBefore, greaterThan(0));
      await park(a);

      // ---- 기기 B: 새 설치로 같은 계정에 로그인 ----
      final b = await nextDevice();
      expect(await b.addUser(id, 'pw1234', displayName: 'A'), isNull);
      expect(await b.authenticate(id, 'pw1234'), isTrue);
      await b.sync.start();
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      // 1) A 의 일정이 B 에 보인다.
      final onB = b.tasksForOwner(id).where((t) => t.id == made.id);
      expect(onB, isNotEmpty, reason: 'B 가 서버의 일정을 받아와야 합니다');
      expect(onB.first.title, 'A가 만든 일정 — 결함 ① 확인용');

      // 2) A 가 바꾼 탭 이름이 살아 있다 (기본값으로 되돌아가지 않았다).
      expect(b.categoryById('todo')?.label, 'A의 할일탭',
          reason: '기본 카테고리로 덮어쓰면 사용자에게는 "카테고리가 사라진" 것으로 보입니다');

      // 3) 서버 레코드 수가 그대로다 — B 가 빈 워크스페이스를 올리지 않았다.
      final serverAfter = await backend().read(workspace);
      expect(serverAfter.entities.length, countBefore,
          reason: 'B 로그인으로 서버 레코드가 늘거나 줄면 안 됩니다');
      expect(serverAfter.entities['tasks/${made.id}'], isNotNull);
      await park(b);
    });

    test('빈 서버에 기본 카테고리를 미리 넣지 않는다 — 첫 기기가 만든 것만 남는다',
        () async {
      if (!hasServer()) {
        markTestSkipped('게이트웨이 서버 없음');
        return;
      }

      final id = freshAccountId();
      final a = await nextDevice();
      expect(await a.addUser(id, 'pw1234', displayName: 'A'), isNull);
      expect(await a.authenticate(id, 'pw1234'), isTrue);

      // 서버를 보기 전에는 기본 일정을 만들지 않습니다.
      expect(a.cachedRev, 0);
      expect(a.cachedGen, 0);
      expect(await a.seedDefaultsOnceAfterSync(), isFalse,
          reason: '서버를 못 본 채 기본값을 올리면 첫 기기의 자료를 덮어씁니다');
      expect(
        a.tasksForOwner(id).where((t) => t.categoryId == 'repeat'),
        isEmpty,
        reason: '동기화 중이고 서버를 못 봤으면 기본 일정을 만들면 안 됩니다',
      );

      await a.sync.start();
      await waitForServerSeen(a);
      expect(await a.seedDefaultsOnceAfterSync(), isTrue,
          reason: '서버를 본 뒤에는 만들 수 있어야 합니다');
      await a.sync.flush(manual: true);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final workspace = a.workspaceId;
      await park(a);

      // 빈 서버였으므로 첫 기기가 만든 것만 있어야 합니다.
      final doc = await backend().read(workspace);
      final seedIds = _allSlots.map((s) => expectedSeedTaskId(id, s)).toSet();
      final serverSeedTasks = doc.entities.entries
          .where((e) =>
              e.key.startsWith('tasks/') && seedIds.contains(e.key.substring(6)))
          .map((e) => e.key)
          .toSet();
      expect(serverSeedTasks.length, 6,
          reason: '기본 일정은 6건(월세·창고비·일상 4건)이어야 합니다');
    });
  });

  group('기존 사용자 일정 보호', () {
    test('사용자가 만든 12일 반복 일정이 있으면 월세를 새로 만들지 않는다', () async {
      if (!hasServer()) {
        markTestSkipped('게이트웨이 서버 없음');
        return;
      }

      final id = freshAccountId();
      final s = await nextDevice();
      expect(await s.addUser(id, 'pw1234', displayName: 'U'), isNull);
      expect(await s.authenticate(id, 'pw1234'), isTrue);
      await s.sync.start();
      await waitForServerSeen(s);

      // 사용자가 직접 12일 반복 일정을 하나 만들었다고 가정합니다.
      final mine = await s.addTask('내가 만든 12일 반복', 'repeat');
      mine.recurrence = 'monthly';
      mine.recurrenceDay = 12;
      await s.saveTask(mine);

      final before = s.tasksForOwner(id).length;
      await s.seedRecurringBillsIfEmpty();
      expect(s.tasksForOwner(id).length, before,
          reason: '이미 12일 반복 일정이 있으면 기본 월세를 만들지 않습니다');
      await park(s);
    });
  });
}
