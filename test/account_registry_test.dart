import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:june_scheduler/services/cloud/nas_backend.dart';
import 'package:june_scheduler/services/store.dart';

/// The account registry: one account list, shared by every device.
///
/// The user's complaint was that ids were *not* centrally managed — each device
/// kept its own copy, so the same name could mean two different passwords. These
/// tests pin the behaviour that fixes it:
///
///   * device A creates an id → it lands in the shared registry,
///   * device B, which has never seen that id, can sign in with it,
///   * device B is **refused** when the password is wrong (a local row must not
///     be able to override the central password),
///   * a password change on A is honoured by B on the next sign-in.
///
/// Runs against a real gateway (STORAGE=local, throwaway directory) so the HTTP
/// path and the registry's last-writer-wins merge are both exercised.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const port = 8128;
  const secret = 'regtest123';
  late Process server;
  late Directory dataDir;
  late Directory devDir;
  int devSeq = 0;

  NasBackend backend() =>
      NasBackend(baseUrl: 'http://127.0.0.1:$port', secret: secret);

  bool hasServer() => File('server/gateway/server.js').existsSync();

  setUpAll(() async {
    if (!hasServer()) return;
    dataDir = Directory.systemTemp.createTempSync('regdata_');
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

  tearDown(() async {
    await Hive.close();
  });

  /// A brand-new install: empty storage directory, fresh boxes.
  Future<Store> nextDevice() async {
    await Hive.close();
    devDir = Directory.systemTemp.createTempSync('reg_dev_${devSeq++}_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => devDir.path,
    );
    final s = Store();
    await s.init();
    s.useBackend(backend());
    return s;
  }

  /// A nickname nobody has used, so each test starts from a clean id.
  String freshId(String tag) =>
      '$tag${DateTime.now().microsecondsSinceEpoch % 1000000}';

  test('A가 만든 아이디는 서버 명부에 올라가고, 한 번도 본 적 없는 B도 로그인한다', () async {
    if (!hasServer()) {
      markTestSkipped('게이트웨이 서버 없음');
      return;
    }
    final id = freshId('central');

    // ---- device A: create the account ------------------------------------
    final a = await nextDevice();
    expect(await a.addUser(id, 'alpha-pass', displayName: 'A의 계정'), isNull);

    // The registry is written at creation time, not only at sign-in, so the id
    // is claimed everywhere at once.
    final reg = await backend().read(Store.registryWorkspaceId);
    final rec = reg.entities['accounts/$id'] as Map?;
    expect(rec, isNotNull, reason: '아이디가 서버 명부에 저장되어야 합니다');
    expect(rec!['pwHash'], isA<String>());
    expect(rec.containsKey('password'), isFalse,
        reason: '명부에 평문 비밀번호가 남으면 안 됩니다');
    expect(rec['displayName'], 'A의 계정');

    // ---- device B: never seen this id -----------------------------------
    final b = await nextDevice();
    expect(b.userById(id), isNull, reason: 'B는 이 아이디를 아직 모릅니다');
    expect(await b.authenticate(id, 'alpha-pass'), isTrue,
        reason: '명부로 인증해 어느 기기에서든 로그인되어야 합니다');
    expect(b.currentUserId, id);

    b.sync.stop();
    a.sync.stop();
  });

  test('등록된 아이디는 다른 비밀번호로 로그인할 수 없다', () async {
    if (!hasServer()) {
      markTestSkipped('게이트웨이 서버 없음');
      return;
    }
    final id = freshId('strict');

    final a = await nextDevice();
    expect(await a.addUser(id, 'right-pass'), isNull);

    final b = await nextDevice();
    expect(await b.authenticate(id, 'wrong-pass'), isFalse,
        reason: '중앙 명부의 비밀번호와 다르면 거부해야 합니다');
    expect(b.currentUserId, isEmpty);
    // Still refused on the second attempt — a failed try must not "remember"
    // the wrong password anywhere.
    expect(await b.authenticate(id, 'wrong-pass'), isFalse);
    expect(await b.authenticate(id, 'right-pass'), isTrue);

    b.sync.stop();
    a.sync.stop();
  });

  test('로컬에 남은 옛 비밀번호로는 로그인되지 않는다 (기기별 아이디 방지)', () async {
    if (!hasServer()) {
      markTestSkipped('게이트웨이 서버 없음');
      return;
    }
    final id = freshId('legacy');

    // A registers with one password...
    final a = await nextDevice();
    expect(await a.addUser(id, 'server-pass'), isNull);
    expect(await a.authenticate(id, 'server-pass'), isTrue);
    await a.sync.start();

    // ...then changes it. This has to reach the registry, otherwise every other
    // device keeps using the old one — a per-device password by another name.
    await a.updatePassword(id, 'changed-pass');
    await a.sync.flush(manual: true);
    a.sync.stop();

    final reg = await backend().read(Store.registryWorkspaceId);
    final rec = reg.entities['accounts/$id'] as Map?;
    expect(rec, isNotNull);
    expect(Store.verifyAccountPassword(rec!, 'changed-pass'), isTrue,
        reason: '바뀐 비밀번호가 명부에 반영되어야 합니다');
    expect(Store.verifyAccountPassword(rec, 'server-pass'), isFalse);

    // A device that never saw the old password at all.
    final c = await nextDevice();
    expect(await c.authenticate(id, 'server-pass'), isFalse,
        reason: '서버에서 바뀐 비밀번호는 기기별 사본보다 우선합니다');
    expect(await c.authenticate(id, 'changed-pass'), isTrue);

    c.sync.stop();
  });

  test('다른 기기에서 같은 아이디를 새로 만들면 거부된다', () async {
    if (!hasServer()) {
      markTestSkipped('게이트웨이 서버 없음');
      return;
    }
    final id = freshId('dup');

    final a = await nextDevice();
    expect(await a.addUser(id, 'first-pass'), isNull);

    final b = await nextDevice();
    final err = await b.addUser(id, 'second-pass', displayName: 'B의 계정');
    expect(err, isNotNull,
        reason: '이미 등록된 아이디를 다른 비밀번호로 다시 만들 수 없어야 합니다');
    expect(err, contains('already registered'));

    b.sync.stop();
    a.sync.stop();
  });

  test('옛 비밀번호로 로그인한 기기가 명부의 비밀번호를 되돌리지 않는다', () async {
    if (!hasServer()) {
      markTestSkipped('게이트웨이 서버 없음');
      return;
    }
    final id = freshId('revert');

    final a = await nextDevice();
    expect(await a.addUser(id, 'old-pass'), isNull);
    expect(await a.authenticate(id, 'old-pass'), isTrue);

    // The password changes centrally.
    await a.updatePassword(id, 'new-pass');

    // The same device keeps running. Its routine sign-in republishes the account
    // record with a fresh `updatedAt`, and the registry is last-writer-wins — so
    // without the withPassword guard this call silently restores `old-pass` for
    // every device. That is the per-device account problem wearing a disguise.
    await a.publishAccount(id);

    final reg = await backend().read(Store.registryWorkspaceId);
    final rec = reg.entities['accounts/$id'] as Map?;
    expect(Store.verifyAccountPassword(rec!, 'new-pass'), isTrue,
        reason: '로그인만으로 새 비밀번호가 되돌아가면 안 됩니다');
    expect(Store.verifyAccountPassword(rec, 'old-pass'), isFalse);

    a.sync.stop();
  });

  test('삭제한 아이디는 어느 기기에서도 로그인되지 않고, 다시 만들 수 있다', () async {
    if (!hasServer()) {
      markTestSkipped('게이트웨이 서버 없음');
      return;
    }
    final id = freshId('retire');

    final a = await nextDevice();
    expect(await a.addUser(id, 'bye-pass'), isNull);
    await a.deleteUser(id);

    // A device that never held the row still cannot use it: the registry says
    // disabled, and that outranks an account record lying around in a workspace.
    final b = await nextDevice();
    expect(await b.authenticate(id, 'bye-pass'), isFalse,
        reason: '삭제된 아이디는 다른 기기에서도 로그인되면 안 됩니다');

    // ...and the id is free again, not permanently poisoned.
    expect(await b.addUser(id, 'fresh-pass'), isNull,
        reason: '삭제한 아이디는 다시 만들 수 있어야 합니다');
    expect(await b.authenticate(id, 'fresh-pass'), isTrue);

    b.sync.stop();
    a.sync.stop();
  });
}
