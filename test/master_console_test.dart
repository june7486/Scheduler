// 마스터 콘솔 계약 시험.
//
// ## 배경 — 이 시험이 지키는 결정
//
// 원래 이 앱은 **평문 비밀번호를 절대 서버로 보내지 않았습니다.**
// 실제 사고가 있었기 때문입니다 (나스 워크스페이스 JSON 에 계정 세 개의
// 평문이 그대로 들어 있었다). 그 가드를 `account_secret_leak_test.dart` 가
// 지키고 있습니다.
//
// 2026-11-23, 사용자가 요구했습니다:
//   "아이디별 내용과 패스워드를 마스터가 조회 및 변경, 삭제 할 수 있음
//    이 프로그램은 완벽한 보안용이 아니기 때문에 그렇게 설계하도록 할 것"
//
// 그래서 되돌렸습니다. 단 **이름을 나눠서** 되돌렸습니다:
//
//   `password` → 여전히 나가지 않습니다 (유출 흔적과 구별할 수 없으므로)
//   `pwPlain`  → 일부러 나갑니다 (마스터 콘솔용)
//
// ## 이 시험이 실패하면 무엇이 깨지는가
// - `pwPlain` 이 안 나가면 → 다른 기기의 마스터가 비밀번호를 못 봅니다
// - `pwPlain` 이 무시되면 → 기기 A 에서 바꾼 값이 기기 B 에 반영 안 됩니다
// - 자리표시자가 승격되면 → 아무도 모르는 비밀번호가 퍼져 계정이 잠깁니다

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
    dir = Directory.systemTemp.createTempSync('master_');
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

  group('pwPlain — 마스터 콘솔을 위한 평문', () {
    test('실제 비밀번호는 pwPlain 으로 나가고 password 로는 나가지 않는다', () async {
      final store = Store();
      await store.init();

      // 마스터에게 진짜 비밀번호를 준다 (첫 실행 설정 화면이 하는 일).
      await store.updatePassword(Store.masterId, 'MyRealPass123!');

      await store.queueAllForUpload(Store.masterId);
      final row = store.pendingSnapshot(Store.masterId)['accounts/${Store.masterId}']!;

      expect(row['pwPlain'], 'MyRealPass123!',
          reason: '마스터가 다른 기기에서 조회하려면 이 값이 있어야 합니다');
      expect(row.containsKey('password'), isFalse,
          reason: 'password 라는 이름은 여전히 나가면 안 됩니다');
      expect(row['pwHash'], isNotNull, reason: '검증용 해시도 함께 있어야 합니다');
    });

    test('자리표시자는 pwPlain 으로도 나가지 않는다', () async {
      final store = Store();
      await store.init();

      // 설치 직후 마스터는 무작위 64자 자리표시자를 들고 있다.
      final placeholder = store.userById(Store.masterId)!.password;
      expect(placeholder.length, 64);

      await store.queueAllForUpload(Store.masterId);
      final row = store.pendingSnapshot(Store.masterId)['accounts/${Store.masterId}']!;

      expect(row.containsKey('pwPlain'), isFalse,
          reason: '아무도 모르는 값은 자격증명이 아닙니다 — 조회해도 쓸모가 없고 '
              '진짜 비밀번호처럼 보이면 오해만 만듭니다');
      expect(row.containsKey('password'), isFalse);
    });

    test('서버의 pwPlain 이 로컬 비밀번호를 갱신한다 (기기 A → 기기 B)', () async {
      final store = Store();
      await store.init();

      // 기기 A 의 마스터가 비밀번호를 바꾼 상황을 흉내낸다.
      final changed = store.applyServerSnapshot({
        'accounts/${Store.masterId}': {
          'id': Store.masterId,
          'displayName': 'Master',
          'isMaster': true,
          'enabled': true,
          'pwHash': 'x' * 64,
          'pwPlain': 'ChangedOnPhone!',
          'updatedAt': 9999999999999,
        },
      });

      expect(changed, isTrue);
      expect(store.userById(Store.masterId)!.password, 'ChangedOnPhone!',
          reason: '다른 기기에서 바꾼 값이 이 기기에 와야 합니다');
    });

    test('옛 빌드가 남긴 평문(password)은 여전히 버린다', () async {
      // 이건 유출 흔적입니다. 우리가 의도해서 보낸 값이 아니므로 받으면 안 됩니다.
      final store = Store();
      await store.init();
      final before = store.userById(Store.masterId)!.password;

      store.applyServerSnapshot({
        'accounts/${Store.masterId}': {
          'id': Store.masterId,
          'displayName': 'Master',
          'isMaster': true,
          'enabled': true,
          'password': 'leaked-plaintext',
          'updatedAt': 9999999999999,
        },
      });

      expect(store.userById(Store.masterId)!.password, before,
          reason: '유출된 낡은 값이 자격증명을 덮으면 안 됩니다');
    });

    test('자리표시자 pwPlain 은 무시된다 — 계정 잠금 방지', () async {
      final store = Store();
      await store.init();
      final before = store.userById(Store.masterId)!.password;

      // 서버가 자리표시자를 평문으로 들고 있는 경우 (옛 빌드의 실수).
      store.applyServerSnapshot({
        'accounts/${Store.masterId}': {
          'id': Store.masterId,
          'displayName': 'Master',
          'isMaster': true,
          'enabled': true,
          'pwPlain': 'a' * 64,
          'updatedAt': 9999999999999,
        },
      });

      expect(store.userById(Store.masterId)!.password, before,
          reason: '무작위 64자를 비밀번호로 받아들이면 영원히 로그인할 수 없습니다');
    });
  });

  group('마스터의 삭제', () {
    test('purgeUserCompletely 는 마스터를 지우지 않는다', () async {
      final store = Store();
      await store.init();
      await store.purgeUserCompletely(Store.masterId);
      expect(store.userById(Store.masterId), isNotNull,
          reason: '마스터가 자기를 지우면 아무도 관리할 수 없습니다');
    });

    test('purgeUserCompletely 는 그 계정의 일정도 함께 지운다', () async {
      final store = Store();
      await store.init();
      await store.addUser('victim', 'pw1234', displayName: 'Victim');

      await store.saveTask(
        Task(
          id: 't1',
          title: '유령 일정',
          ownerId: 'victim',
          categoryId: 'todo',
        ),
      );
      expect(store.tasksForOwner('victim').length, 1);

      await store.purgeUserCompletely('victim');

      expect(store.userById('victim'), isNull, reason: '계정 행이 사라져야 합니다');
      expect(store.tasksForOwner('victim'), isEmpty,
          reason: '남은 일정은 주인 없는 유령 데이터가 됩니다');
    });
  });
}
