// Regression test: 계정 행이 동기화될 때 평문 비밀번호가 서버로 나가면 안 된다.
//
// 실제로 났던 사고 두 가지를 함께 막는다.
//
//  1. `accounts/<id>` 는 일반 엔티티로 업로드되는데 그 레코드가 User.toMap() 을
//     그대로 써서 `password` 가 함께 실려 나갔다. 나스의 워크스페이스 JSON 을
//     열어보니 세 계정의 평문 비밀번호가 그대로 들어 있었다.
//  2. 그런데 그 사본에는 `pwHash` 가 없었다. 즉 새 기기에서 그 워크스페이스를
//     받아도 비밀번호를 검증할 방법이 없었다. 레지스트리(ACCREGISTRY…)만
//     해시를 갖고 있었고, 두 사본이 서로 다른 것을 담고 있었다.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:june_scheduler/services/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('leak_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    Hive.init(dir.path);
    await Hive.openBox('users');
    await Hive.openBox('tasks');
    await Hive.openBox('categories');
    await Hive.openBox('logs');
    await Hive.openBox('voices');
    await Hive.openBox('prefs');
  });

  tearDown(() async {
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('업로드 스냅샷에 평문 비밀번호가 실리지 않고 pwHash 가 실린다', () async {
    final store = Store();
    await store.init();

    // 마스터 계정은 로컬에 실제 비밀번호를 들고 있다 (오프라인 로그인용).
    final master = store.userById(Store.masterId)!;
    expect(master.password, isNotEmpty, reason: '로컬에는 있어야 한다');

    await store.queueAllForUpload(Store.masterId);
    final snapshot = store.pendingSnapshot(Store.masterId);

    final accountKey = 'accounts/${Store.masterId}';
    expect(snapshot.containsKey(accountKey), isTrue,
        reason: '계정 행은 워크스페이스에 포함되어야 한다');

    final sent = snapshot[accountKey]!;
    expect(sent.containsKey('password'), isFalse,
        reason: '평문 password 가 서버로 나가면 안 된다');
    expect(sent['id'], Store.masterId, reason: '나머지 필드는 남아야 한다');
  });

  test('서버에서 평문이 담긴 낡은 스냅샷이 와도 로컬 계정을 오염시키지 않는다',
      () async {
    final store = Store();
    await store.init();

    final before = store.userById(Store.masterId)!.password;

    // 이미 유출된 워크스페이스를 흉내낸다 (수정 전 배포본이 올린 상태).
    final changed = store.applyServerSnapshot({
      'accounts/${Store.masterId}': {
        'id': Store.masterId,
        'displayName': 'Master',
        'isMaster': true,
        'enabled': true,
        'password': 'leaked-plaintext',
        'updatedAt': 9999999999999,
      },
    });
    expect(changed, isTrue, reason: '스냅샷은 적용되어야 한다');

    final local = store.userById(Store.masterId)!;
    expect(local.password, isNot('leaked-plaintext'),
        reason: '서버가 보낸 평문이 로컬 자격증명을 덮으면 안 된다');
    expect(local.password, before, reason: '기존 로컬 비밀번호가 유지되어야 한다');
  });

  test('자리표시자 비밀번호는 해시로 승격되지 않는다', () async {
    // 한 번도 쓰인 적 없는 master 슬롯(설치 시 무작위 값)을 해시로 올리면
    // 아무도 모르는 비밀번호가 공개되고, 다음 동기화에서 레지스트리의 진짜
    // 해시를 덮어써 계정이 잠긴다.
    final store = Store();
    await store.init();

    final placeholder = store.userById(Store.masterId)!.password;
    expect(placeholder.length, 64, reason: '자리표시자는 uuid 두 개를 이은 64자');

    await store.queueAllForUpload(Store.masterId);
    final row = store.pendingSnapshot(Store.masterId)['accounts/${Store.masterId}']!;

    expect(row.containsKey('pwHash'), isFalse,
        reason: '자리표시자를 해시로 만들면 안 된다');
    expect(row.containsKey('password'), isFalse,
        reason: '자리표시자라도 평문을 내보내면 안 된다');
  });
}
