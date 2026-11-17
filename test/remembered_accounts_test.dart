// 이 기기에서 사용한 계정 = 원터치 로그인.
//
// 확인해야 할 것은 세 가지다.
//
//  1. 로그인에 성공한 계정이 "이 기기에서 사용한 계정" 목록에 남는다.
//  2. 저장된 비밀번호로 다시 로그인할 수 있다 (그게 이 기능의 존재 이유다).
//  3. 그 비밀번호는 **서버로 나가지 않는다**. 워크스페이스 스냅샷에 실리면
//     지난번에 애써 지운 평문 유출이 그대로 되살아난다.
//
// 그리고 하나 더: 다른 계정으로 로그인해도 앞서 저장한 계정이 사라지면 안 된다.
// 폰 한 대를 가족이 같이 쓰는 경우가 실제로 있다.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Store.init() 은 Hive.initFlutter() 를 부르고, 그건 path_provider 를 탄다.
    // 박스만 직접 열면 그 호출에서 MissingPluginException 이 난다.
    await Hive.close();
    dir = Directory.systemTemp.createTempSync('remembered_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
  });

  tearDown(() async {
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('로그인하면 이 기기 계정 목록에 남고, 저장된 비밀번호로 다시 들어간다', () async {
    final store = Store();
    await store.init();
    // 서버 없이 로컬만으로 검증한다 (이 기능은 기기 로컬 기능이다).
    store.useBackend(const NullBackend());

    expect(await store.addUser('mom', 'hunter2!', displayName: '엄마'), isNull);
    expect(await store.authenticate('mom', 'hunter2!'), isTrue);

    expect(store.rememberedAccountIds, contains('mom'));
    expect(store.savedPasswordFor('mom'), 'hunter2!');
    expect(store.rememberedAccounts.map((u) => u.id), contains('mom'));

    // 다시 로그인 — 폼에 아무것도 입력하지 않아도 된다.
    final pw = store.savedPasswordFor('mom');
    expect(pw, isNotNull);
    expect(await store.authenticate('mom', pw!), isTrue);
  });

  test('다른 계정으로 로그인해도 앞서 저장한 계정이 남는다', () async {
    final store = Store();
    await store.init();
    store.useBackend(const NullBackend());

    await store.addUser('dad', 'abcd1234', displayName: '아빠');
    await store.authenticate('dad', 'abcd1234');

    await store.addUser('kid', 'kidpw99', displayName: '아이');
    await store.authenticate('kid', 'kidpw99');

    final ids = store.rememberedAccountIds;
    expect(ids, containsAll(<String>['dad', 'kid']));
    expect(ids.first, 'kid', reason: '가장 최근에 쓴 계정이 맨 앞');
    expect(store.savedPasswordFor('dad'), 'abcd1234',
        reason: '앞서 저장한 비밀번호가 지워지면 안 된다');
  });

  test('평문은 서버 스냅샷에 실리지 않는다', () async {
    final store = Store();
    await store.init();
    store.useBackend(const NullBackend());

    await store.addUser('leaky', 'topsecret1', displayName: '누설');
    await store.authenticate('leaky', 'topsecret1');

    // 저장은 됐지만
    expect(store.savedPasswordFor('leaky'), 'topsecret1');

    // 업로드되는 것에는 없어야 한다.
    await store.queueAllForUpload('leaky');
    final snap = store.pendingSnapshot('leaky');
    final row = snap['accounts/leaky'] as Map?;
    expect(row, isNotNull);
    expect(row!.containsKey('password'), isFalse,
        reason: '기기에만 저장한 비밀번호가 워크스페이스로 새면 안 된다');
    expect(row['pwHash'], isNotNull,
        reason: '해시는 있어야 다른 기기가 검증할 수 있다');
  });

  test('틀린 비밀번호는 저장되지 않는다', () async {
    final store = Store();
    await store.init();
    store.useBackend(const NullBackend());

    await store.addUser('victim', 'rightpw1', displayName: '사용자');
    expect(await store.authenticate('victim', 'wrongpw1'), isFalse);
    expect(store.savedPasswordFor('victim'), isNull,
        reason: '실패한 시도가 저장되면 다음 원터치 로그인이 실패한다');
    expect(store.rememberedAccountIds, isNot(contains('victim')));
  });

  test('지우면 목록과 저장된 비밀번호가 함께 사라진다', () async {
    final store = Store();
    await store.init();
    store.useBackend(const NullBackend());

    await store.addUser('guest', 'guestpw1', displayName: '손님');
    await store.authenticate('guest', 'guestpw1');
    expect(store.savedPasswordFor('guest'), isNotNull);

    await store.forgetAccount('guest');
    expect(store.rememberedAccountIds, isNot(contains('guest')));
    expect(store.savedPasswordFor('guest'), isNull);
  });

  test('낡은 저장 비밀번호는 지워지고 계정은 목록에 남는다', () async {
    final store = Store();
    await store.init();
    store.useBackend(const NullBackend());

    await store.addUser('stale', 'oldpw123', displayName: '낡음');
    await store.authenticate('stale', 'oldpw123');
    expect(store.savedPasswordFor('stale'), 'oldpw123');

    await store.forgetSavedPassword('stale');
    expect(store.savedPasswordFor('stale'), isNull);
    expect(store.rememberedAccountIds, contains('stale'),
        reason: '비밀번호만 지우고 계정은 남겨야 다시 입력 한 번으로 끝난다');
  });
}
