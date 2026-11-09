// 새 기기에서 로그인이 되는지 — 실제로 났던 사고를 그대로 재현한다.
//
// 사고: 데스크탑 크롬은 되는데 아이폰/안드로이드는 "아이디 또는 비밀번호가
// 올바르지 않습니다". 서버는 멀쩡했다 (레지스트리 해시도 정확했고 워크스페이스도
// 정상이었다). 원인은 클라이언트 쪽 두 가지였다.
//
//   1. 워크스페이스 사본이 pwHash 만 담게 바뀌었는데 `_adoptAccountFromServer`
//      는 여전히 `remote.password == pw` 로 비교했다. 사본에 password 가 없으니
//      올바른 비밀번호도 항상 거부됐다.
//
//      데스크탑 크롬이 유일하게 살아남은 이유: 그 기기는 이미 로컬에 계정과
//      평문을 갖고 있어서 "로컬 대조" 단계에서 통과했다. 새 기기는 로컬 사본이
//      없어 서버 사본까지 내려가는데, 바로 그 지점이 깨져 있었다.
//
//   2. 로그인 대기 시간이 4초여서 느린 연결에서는 레지스트리 조회가 잘리고
//      곧바로 위의 1번 경로로 떨어졌다.
//
// 그래서 이 테스트는 **레지스트리를 읽지 못하는 상황**을 반드시 만든다.
// 그게 사고 당시 아이폰/안드로이드의 상태였고, 1번 버그가 드러나는 유일한 조건이다.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/cloud/nas_backend.dart';
import 'package:june_scheduler/services/store.dart';

/// 레지스트리는 모르지만 계정 워크스페이스는 아는 백엔드.
///
/// 사고 당시의 실제 조건을 그대로 만든다: 계정 사본은 읽을 수 있으나 중앙
/// 목록 조회는 실패한다 (느린 연결로 타임아웃, 또는 프록시가 목록 요청만 거절).
class _RegistryBlindBackend implements CloudBackend {
  _RegistryBlindBackend(this.inner);
  final CloudBackend inner;

  int registryReads = 0;

  @override
  String get name => 'registry-blind';

  @override
  bool get isConfigured => true;

  @override
  Future<CloudDoc> read(String workspaceId, {int haveRev = 0}) async {
    if (workspaceId == Store.registryWorkspaceId) {
      registryReads++;
      // 중앙 목록은 "없는 것"으로 답한다. 예외가 아니라 빈 문서여야
      // authenticate 의 폴백 경로가 정상적으로 이어진다.
      return CloudDoc.unknown;
    }
    return inner.read(workspaceId, haveRev: haveRev);
  }

  @override
  Future<CloudWriteResult> write(
    String workspaceId,
    CloudDoc doc, {
    Map<String, dynamic>? extra,
  }) =>
      inner.write(workspaceId, doc, extra: extra);

  @override
  CloudSubscription watch(
    String workspaceId, {
    required void Function(CloudDoc doc) onRemote,
    required void Function(String reason) onError,
    int haveRev = 0,
  }) =>
      inner.watch(
        workspaceId,
        onRemote: onRemote,
        onError: onError,
        haveRev: haveRev,
      );

  @override
  Future<CloudWriteResult> resetWorkspace(String workspaceId) =>
      inner.resetWorkspace(workspaceId);

  @override
  Future<void> dispose() => inner.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const port = 8177;
  const secret = 'newdevtest123';
  const id = 'newdevice';
  const pw = 'Secret123!';

  late Process server;
  late Directory dataDir;
  late Directory devDir;
  late NasBackend backend;
  var devSeq = 0;

  setUpAll(() async {
    final script = File('server/gateway/server.js');
    if (!script.existsSync()) return;
    dataDir = Directory.systemTemp.createTempSync('newdev_data_');
    server = await Process.start(
      'node',
      [script.absolute.path],
      environment: {
        'STORAGE': 'local',
        'DATA_DIR': dataDir.path,
        'PORT': '$port',
        'SYNC_SECRET': secret,
        'CACHE_MS': '0',
      },
    );
    // 노드의 stdout/stderr 를 비워준다. 파이프를 읽지 않으면 버퍼가 차고
    // 프로세스가 쓰기에서 막혀 서버가 조용히 멈춘다 (테스트가 타임아웃된다).
    server.stdout.drain<void>();
    server.stderr.drain<void>();
    for (var i = 0; i < 80; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', port);
        s.destroy();
        break;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    backend = NasBackend(baseUrl: 'http://127.0.0.1:$port', secret: secret);
  });

  tearDownAll(() async {
    server.kill(ProcessSignal.sigkill);
    await server.exitCode;
    await Hive.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  /// 완전히 새로운 기기: Hive 디렉터리를 갈아끼운다.
  Future<Store> newDevice({CloudBackend? on}) async {
    await Hive.close();
    devDir = Directory.systemTemp.createTempSync('newdev_${devSeq++}_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => devDir.path,
    );
    final s = Store();
    await s.init();
    s.useBackend(on ?? backend);
    return s;
  }

  /// 다른 기기가 이미 가입해 둔 상태를 서버에만 만든다.
  ///
  /// 계정 사본에는 **평문이 없고 해시만** 있다 — 지금 배포본이 올리는 형태.
  Future<void> seedWorkspaceAccount() async {
    await backend.write(
      Store.workspaceCodeFor(id),
      CloudDoc(
        rev: 0,
        entities: {
          'accounts/$id': {
            'id': id,
            'displayName': '새 기기',
            'isMaster': false,
            'enabled': true,
            'pwHash': Store.hashPassword(id, pw),
            'createdAt': DateTime.now().toIso8601String(),
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          },
        },
      ),
    );
  }

  test('중앙 목록을 못 읽어도 계정 사본의 해시로 로그인한다', () async {
    await seedWorkspaceAccount();

    // 전제 확인: 사본에 평문이 없어야 이 테스트가 의미를 갖는다.
    final doc = await backend.read(Store.workspaceCodeFor(id));
    final row = doc.entities['accounts/$id'] as Map;
    expect(row.containsKey('password'), isFalse,
        reason: '전제: 계정 사본은 평문을 담지 않는다');
    expect(row['pwHash'], isNotNull, reason: '전제: 해시는 담는다');

    final blind = _RegistryBlindBackend(backend);
    final device = await newDevice(on: blind);

    final ok = await device.authenticate(id, pw);
    expect(blind.registryReads, greaterThan(0),
        reason: '이 테스트는 레지스트리를 먼저 시도해야 의미가 있다');
    expect(ok, isTrue,
        reason: '해시만 있는 사본으로도 새 기기가 로그인해야 한다 '
            '(예전에는 remote.password 비교로 항상 실패했다)');

    final me = device.userById(id)!;
    expect(me.password, pw,
        reason: '로그인 직후에는 오프라인 로그인용으로 평문을 보관한다');
    device.sync.stop();
  });

  test('레지스트리만 있고 사본이 없어도 로그인한다', () async {
    // 반대 방향: 중앙 목록이 살아 있고 계정 사본이 아직 없는 경우.
    await backend.write(
      Store.registryWorkspaceId,
      CloudDoc(
        rev: 0,
        entities: {
          'accounts/registryonly': {
            'id': 'registryonly',
            'displayName': '레지스트리만',
            'isMaster': false,
            'enabled': true,
            'pwHash': Store.hashPassword('registryonly', pw),
            'createdAt': DateTime.now().toIso8601String(),
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          },
        },
      ),
    );

    final device = await newDevice();
    expect(await device.authenticate('registryonly', pw), isTrue);
    device.sync.stop();
  });

  test('틀린 비밀번호는 계속 거부된다', () async {
    final blind = _RegistryBlindBackend(backend);
    final device = await newDevice(on: blind);

    expect(await device.authenticate(id, 'wrong-password'), isFalse);
    expect(await device.authenticate(id, pw), isTrue);
    device.sync.stop();
  });

  test('로그인 후 올라간 계정 사본에도 평문이 없다', () async {
    final device = await newDevice();
    expect(await device.authenticate(id, pw), isTrue);

    // 동기화가 계정 행을 올릴 시간을 준다.
    await device.sync.start();
    await Future.delayed(const Duration(milliseconds: 400));

    final doc = await backend.read(Store.workspaceCodeFor(id));
    final row = doc.entities['accounts/$id'] as Map;
    expect(row.containsKey('password'), isFalse,
        reason: '로그인 후 업로드에도 평문이 없어야 한다');
    expect(row['pwHash'], isNotNull,
        reason: '해시는 남아 있어야 다음 기기가 검증할 수 있다');
    device.sync.stop();
  });
}
