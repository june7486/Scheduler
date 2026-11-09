import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:june_scheduler/services/cloud/nas_backend.dart';
import 'package:june_scheduler/services/store.dart';

/// Live proof of requirement ①: an EMPTY device signs in with an id whose
/// account exists only on the NAS.
///
/// The local master account is deleted first, so `authenticate()` cannot succeed
/// from the box — it must go to the server, find `accounts/june7486`, verify the
/// password, and adopt it locally. That is the exact path a brand-new phone
/// takes, and the reason the password can be removed from the source afterwards.
///
/// Needs a gateway on 127.0.0.1:8097 talking to the real NAS, plus the real
/// password supplied from outside the repo:
///   MASTER_PW='…' flutter test test/live_account_seed_test.dart
///
/// The password is deliberately **not** in this file: it lives only on the NAS
/// now, and a live check that hard-coded it would quietly re-publish the secret
/// this whole change removed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const url = 'http://127.0.0.1:8097';
  const key = '46c8b41d49fce507fd0b61908c4de356a7b920bbfc2ee5f9f86b32a5934fe26d';
  final masterPw = Platform.environment['MASTER_PW'] ?? '';

  late Directory tmp;

  setUp(() async {
    await Hive.close();
    tmp = Directory.systemTemp.createTempSync('june_live_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });

  tearDown(() async {
    await Hive.close();
  });

  test('빈 기기에서 june7486 로그인 — 서버 계정을 받아온다', () async {
    if (masterPw.isEmpty) {
      markTestSkipped('MASTER_PW 미지정 — 실제 비밀번호는 저장소에 두지 않습니다');
      return;
    }
    final s = Store();
    await s.init();

    // Erase the locally seeded master so nothing can succeed offline.
    final users = await Hive.openBox('users');
    await users.delete(Store.masterId);
    expect(s.userById(Store.masterId), isNull, reason: '로컬에 계정이 없어야 합니다');

    s.useBackend(NasBackend(baseUrl: url, secret: key));

    final ok = await s.authenticate(Store.masterId, masterPw);
    expect(ok, isTrue, reason: '서버에 계정이 있으므로 로그인돼야 합니다');
    expect(s.isMaster, isTrue, reason: 'isMaster 플래그도 함께 와야 합니다');
    expect(s.currentUserId, Store.masterId);

    // And it is now cached locally, so the next launch works offline.
    final again = await Hive.openBox('users');
    expect(again.get(Store.masterId), isNotNull, reason: '다음 실행을 위해 로컬에 남아야 합니다');

    s.sync.stop();
  });

  test('틀린 비밀번호는 서버 계정으로도 통하지 않는다', () async {
    final s = Store();
    await s.init();
    final users = await Hive.openBox('users');
    await users.delete(Store.masterId);

    s.useBackend(NasBackend(baseUrl: url, secret: key));

    final ok = await s.authenticate(Store.masterId, 'definitely-wrong');
    expect(ok, isFalse, reason: '비밀번호가 틀리면 절대 통과하면 안 됩니다');

    s.sync.stop();
  });

  test('설치 직후의 마스터 자리표시자는 비밀번호가 될 수 없다', () async {
    final s = Store();
    await s.init();
    // Nothing listening here, so no account can be adopted from a server.
    s.useBackend(NasBackend(baseUrl: 'http://127.0.0.1:8199', secret: key));

    final users = await Hive.openBox('users');
    final stored = users.get(Store.masterId) as Map;

    // The placeholder must not be something a human would guess or type.
    expect((stored['password'] as String).length, greaterThan(20),
        reason: '자리표시자는 추측 불가능한 난수여야 합니다');

    // Every plausible guess fails, including the old published password shape.
    for (final guess in ['', '!', 'master', 'june7486', '1234', 'admin']) {
      expect(await s.authenticate(Store.masterId, guess), isFalse,
          reason: '"$guess" 로는 절대 통과하면 안 됩니다');
    }

    s.sync.stop();
  });
}
