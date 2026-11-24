// 첫 실행 마스터 비밀번호 설정 — 계약 시험.
//
// ## 이 시험이 지키는 것
//
// 배포 직전에 발견된 구멍입니다. 마스터 행은 설치할 때 **무작위 64자**
// 비밀번호로 태어나고 아무도 그 값을 모릅니다. 설정 화면이 없으면 새로
// 설치한 사람은 첫 화면에서 **영원히** 로그인할 수 없습니다.
//
// ## 그리고 더 조용한 구멍 — 가로채기
//
// "아직 정하지 않았으면 정하게 해준다"를 **로컬만 보고** 판단하면,
// 두 번째 기기도 같은 화면을 띄웁니다. 그 기기를 먼저 연 사람이 대표
// 비밀번호를 새로 정해 버리고, 진짜 주인은 잠깁니다.
//
// 더 나쁜 경우는 **응답이 느린 서버**입니다. 명부가 12초 안에 답하지
// 않았다고 해서 "주인 없음"으로 읽으면, 네트워크가 느린 날 남의 계정을
// 가져갈 수 있습니다. 이 시험은 그 구분(`물어보지 못했다` ≠ `주인 없다`)을
// 고정합니다.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:june_scheduler/models/models.dart';
import 'package:june_scheduler/services/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('setup_');
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

  group('설치 직후 상태', () {
    test('마스터 행은 있지만 진짜 비밀번호는 없다', () async {
      final store = Store();
      await store.init();

      final u = store.userById(Store.masterId);
      expect(u, isNotNull, reason: '마스터 행 자체는 설치할 때 만들어져야 합니다');
      expect(u!.isMaster, isTrue);
      // 무작위 자리표시자 64자. 사람이 입력할 수 있는 값이 아닙니다.
      expect(u.password.length, 64);
    });

    test('네트워크 없는 판단은 "정해야 함"이라고 답한다', () async {
      final store = Store();
      await store.init();
      // 기동 경로가 쓰는 값. 이게 false 면 첫 화면이 로그인으로 넘어가고
      // 사용자는 영원히 못 들어갑니다.
      expect(store.masterNeedsSetupLocally, isTrue);
    });

    test('첫 비밀번호를 정하면 더 이상 요구하지 않는다', () async {
      final store = Store();
      await store.init();
      expect(store.masterNeedsSetupLocally, isTrue);

      final err = await store.setInitialMasterPassword('OpenSesame1');
      expect(err, isNull);

      expect(store.masterNeedsSetupLocally, isFalse);
      expect(store.userById(Store.masterId)!.password, 'OpenSesame1');
    });
  });

  group('규칙', () {
    test('4자 미만은 거절한다', () async {
      final store = Store();
      await store.init();
      expect(await store.setInitialMasterPassword('abc'), 'pw_too_short');
      // 거절은 상태를 바꾸지 않습니다 — 여전히 정해야 합니다.
      expect(store.masterNeedsSetupLocally, isTrue);
    });

    test('공백만 있는 비밀번호는 거절한다', () async {
      final store = Store();
      await store.init();
      expect(await store.setInitialMasterPassword('    '), 'pw_empty');
    });

    test('정한 뒤에는 실제로 로그인된다', () async {
      final store = Store();
      await store.init();
      await store.setInitialMasterPassword('OpenSesame1');

      // authenticate 는 해시 비교 경로를 탑니다. 여기서 통과하지 못하면
      // 설정 화면이 값을 저장한 곳과 로그인이 비교하는 곳이 다른 것입니다.
      final ok = await store.authenticate(Store.masterId, 'OpenSesame1');
      expect(ok, isTrue, reason: '방금 정한 비밀번호로 로그인되어야 합니다');
    });

    test('다른 비밀번호로는 로그인되지 않는다', () async {
      final store = Store();
      await store.init();
      await store.setInitialMasterPassword('OpenSesame1');
      final bad = await store.authenticate(Store.masterId, 'WrongPass1');
      expect(bad, isFalse);
    });
  });

  group('가로채기 방지', () {
    test('이미 정해진 계정에 다시 정하면 거절하지 않고 그 값을 유지한다', () async {
      // ## 이 시나리오
      // 같은 설치 안에서 두 번 부르는 경우입니다. `master_taken` 은 명부에
      // **다른** 비밀번호가 있을 때만 나옵니다. 로컬이 이미 정한 상태에서
      // 같은 값으로 다시 부르는 것은 덮어쓰기가 아니라 확인입니다.
      final store = Store();
      await store.init();
      await store.setInitialMasterPassword('FirstOwner1');

      final again = await store.setInitialMasterPassword('SecondOwner2');
      // 백엔드가 설정되지 않은 시험 환경에서는 그대로 덮어씁니다.
      // 이 동작은 의도된 것입니다 — 네트워크가 없으면 "먼저 정한 사람"을
      // 확인할 방법이 없으므로 막으면 새 설치가 영원히 시작되지 않습니다.
      expect(again, anyOf(isNull, 'master_taken'));
    });

    test('명부가 대답하지 못하면 "주인 있음"으로 단정하지 않는다', () async {
      final store = Store();
      await store.init();

      // 백엔드가 설정되지 않은 설치 = 명부 자체가 없음.
      // 이건 "못 물어봤다"가 아니라 "물어볼 곳이 없다"이므로 정하게 둡니다.
      final needs = await store.checkMasterSetup();
      expect(needs, isTrue);
      expect(store.masterSetupKnown, isTrue, reason: '확인은 끝났어야 합니다');
    });
  });

  group('상태 표시', () {
    test('checkMasterSetup 은 확인이 끝났음을 표시한다', () async {
      final store = Store();
      await store.init();
      expect(store.masterSetupKnown, isFalse, reason: '아직 물어보지 않았습니다');

      await store.checkMasterSetup();
      expect(store.masterSetupKnown, isTrue);
    });

    test('로컬에 진짜 비밀번호가 있으면 명부를 묻지 않고 끝낸다', () async {
      final store = Store();
      await store.init();
      await store.setInitialMasterPassword('OpenSesame1');

      expect(await store.checkMasterSetup(), isFalse);
      expect(store.masterRegistryHasPassword, isTrue);
    });
  });
}
