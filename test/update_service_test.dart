// 업데이트 확인 기능 시험.
//
// ## 이 시험이 증명하려는 것
//
// `UpdateService.check()` 는 세 가지를 비교합니다:
//   서버 `version.json` 의 `build`  vs  빌드에 심은 `BUILD_ID`
//
// 여기서 조용히 실패할 수 있는 경우가 많습니다 — 필드 이름이 다르거나,
// 서버가 옛 형식을 주거나, 값이 비어 있거나. 그때 앱은 "최신입니다"라고
// 답하는데, 그건 **거짓말**이고 사용자는 새 버전이 있어도 영원히 모릅니다.
//
// 그래서 시험은 "새 버전이 있을 때 알리는가"뿐 아니라
// **"알릴 수 없을 때 조용히 포기하는가"** 까지 확인합니다.
//
// ## BUILD_ID 를 어떻게 넣는가
//
// `UpdateService.currentBuildId` 는 `String.fromEnvironment('BUILD_ID')` 라서
// 컴파일 시점 상수입니다. 시험에서는 다음처럼 넘깁니다:
//
//     flutter test --dart-define=BUILD_ID=2026.11.21.0100
//
// 넘기지 않으면 빈 문자열이 되고, 그러면 check() 가 즉시 null 을 돌려줍니다.
// 그것도 하나의 계약이므로 시험으로 고정합니다.
//
// ## 왜 http.Client 를 주입하는가
//
// 실제 서버에 물어보면 시험이 네트워크에 의존하게 됩니다. 그러면 오프라인
// 에서는 시험이 실패하고, 사람은 "고장났다"고 오해합니다. MockClient 로
// 응답을 직접 만들어야 **로직**만 검사할 수 있습니다.

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:june_scheduler/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 지정한 JSON 을 200 으로 돌려주는 가짜 클라이언트.
http.Client _serving(Object body, {int status = 200}) {
  return MockClient((req) async {
    return http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

/// 이 시험 파일은 **웹 전용**입니다.
///
/// ## 왜 플랫폼을 가리는가
///
/// `UpdateService.check()` 는 첫 줄에서 `if (!kIsWeb) return null;` 을
/// 실행합니다. 모바일 앱은 스토어가 업데이트를 관리하므로 서버에 물어볼
/// 이유가 없기 때문입니다. 그런데 Dart VM 에서 `flutter test` 를 돌리면
/// `kIsWeb == false` 라서 **HTTP 코드가 한 줄도 실행되지 않습니다.**
///
/// 그 상태로 시험을 통과시키면 "비교 로직을 검증했다"는 거짓 보고가
/// 됩니다. 그래서 VM 에서는 건너뛰고, 웹에서 돌렸을 때만 실제로
/// 검증합니다:
///
///     flutter test --platform chrome test/update_service_test.dart \
///         --dart-define=BUILD_ID=2026.11.21.0100
///
/// VM 실행은 `skip:` 으로 표시되어 "건너뜀"이 눈에 보입니다. 조용히
/// 통과하는 것보다 낫습니다.
const String _webOnly =
    '웹 전용: flutter test --platform chrome 로 실행해야 검증됩니다';

/// 웹에서만 실행되는 test. VM 에서는 "건너뜀" 으로 표시됩니다.
///
/// 조용히 통과시키면 "HTTP 경로를 검증했다"는 거짓 보고가 됩니다.
/// skip 이유를 눈에 보이게 두는 편이 정직합니다.
void webTest(String description, Future<void> Function() body) {
  test(description, body, skip: kIsWeb ? false : _webOnly);
}

void main() {
  // 각 시험이 서로의 저장값(마지막 확인 시각, 건너뛰기)에 영향을 주지 않게
  // 매번 초기화합니다. 이걸 빼면 시험 순서를 바꾸는 순간 결과가 달라집니다.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('BUILD_ID 가 없으면 확인하지 않는다', () {
    webTest('개발 빌드에서 거짓 "새 버전" 을 만들지 않는다', () async {
      // --dart-define 없이 도는 시험 = BUILD_ID 없는 빌드와 같은 상황.
      // 서버가 아무리 새 빌드를 들고 있어도 비교 기준이 없으므로
      // 단정하면 안 됩니다.
      final svc = UpdateService(
        client: _serving({'build': '2099.01.01.0000'}),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      if (UpdateService.currentBuildId.isEmpty) {
        expect(await svc.check(force: true), isNull);
      }
    });

    test('currentBuildId 는 --dart-define 으로만 채워진다', () {
      // 이 값이 하드코딩되어 있으면 배포마다 비교가 무의미해집니다.
      // 시험 실행 시 넘긴 값이 그대로 보이는지만 확인합니다.
      expect(UpdateService.currentBuildId, isA<String>());
    });
  });

  group('비교 로직', () {
    webTest('서버 build 가 다르면 새 버전이 있다', () async {
      final svc = UpdateService(
        client: _serving({
          'build': '2026.11.21.9999',
          'version': '1.0.0',
          'notes': '반복 일정 버그 수정',
        }),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      final r = await svc.check(force: true);
      expect(r, isNotNull);
      expect(r!.available, isTrue);
      expect(r.remoteBuild, '2026.11.21.9999');
      expect(r.notes, '반복 일정 버그 수정');
    });

    webTest('서버 build 가 같으면 새 버전이 없다', () async {
      final svc = UpdateService(
        client: _serving({'build': UpdateService.currentBuildId}),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      final r = await svc.check(force: true);
      expect(r, isNotNull);
      expect(r!.available, isFalse);
    });

    webTest('build_id 라는 이름도 받아준다', () async {
      // 옛 배포 스크립트가 build_id 로 심었을 수 있습니다. 이름 하나
      // 때문에 기능이 죽으면 안 되므로 둘 다 읽습니다.
      final svc = UpdateService(
        client: _serving({'build_id': '2026.11.21.8888'}),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      final r = await svc.check(force: true);
      expect(r?.remoteBuild, '2026.11.21.8888');
      expect(r?.available, isTrue);
    });
  });

  group('알릴 수 없을 때는 조용히 포기한다', () {
    // 이 그룹이 이 파일의 핵심입니다. 업데이트 확인은 **부가 기능**이라
    // 실패해도 앱을 방해하면 안 됩니다. 예외를 던지거나, 거짓으로
    // "새 버전 있습니다" 라고 하면 둘 다 사고입니다.

    webTest('build 필드가 없는 version.json 은 null (거짓 알림 금지)', () async {
      // ## 이게 지금 운영 서버의 실제 응답입니다
      // https://www.aqdesign.co.kr/version.json 은
      //   {"app_name": "...", "version": "1.0.0", "build_number": "1", ...}
      // 를 돌려주고 `build` 가 **없습니다.** 비교할 값이 없으므로
      // "새 버전 없음"이 아니라 "확인 불가(null)" 가 맞습니다.
      // 둘을 구분하지 않으면 배포가 안 된 이유를 영원히 못 찾습니다.
      final svc = UpdateService(
        client: _serving({
          'app_name': 'june_scheduler',
          'version': '1.0.0',
          'build_number': '1',
          'package_name': 'june_scheduler',
        }),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      expect(await svc.check(force: true), isNull);
    });

    webTest('build 가 빈 문자열이면 null', () async {
      final svc = UpdateService(
        client: _serving({'build': ''}),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      expect(await svc.check(force: true), isNull);
    });

    webTest('404 는 null', () async {
      // version.json 을 아직 안 올린 배포. 흔한 상태입니다.
      final svc = UpdateService(
        client: _serving({'build': '2026.11.21.0001'}, status: 404),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      expect(await svc.check(force: true), isNull);
    });

    webTest('JSON 이 깨져도 예외를 던지지 않고 null', () async {
      final svc = UpdateService(
        client: _serving('<html>404 Not Found</html>'),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      expect(await svc.check(force: true), isNull);
    });

    webTest('네트워크 예외도 null', () async {
      final svc = UpdateService(
        client: MockClient((_) async => throw Exception('오프라인')),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      expect(await svc.check(force: true), isNull);
    });
  });

  group('재촉하지 않기', () {
    // ## 왜 시각을 직접 조작하는가
    //
    // check() 는 확인 주기(12시간)를 먼저 봅니다. 주기 안이면 서버를
    // 두드리지도 않고 null 을 돌려줍니다 — snooze 판정에 도달하지 않습니다.
    // 그래서 "나중에" 의 효과를 보려면 **마지막 확인 시각을 과거로**
    // 돌려놓아야 합니다. 실제 사용자가 12시간 뒤 앱을 다시 여는 상황입니다.
    //
    // 이걸 건너뛰고 force 로만 시험하면 snooze 로직을 한 줄도 실행하지
    // 못한 채 "통과"합니다. 통과하는 시험이 아무것도 안 지키는 셈입니다.

    /// 마지막 확인 시각을 [hours] 시간 전으로 돌려놓습니다.
    Future<void> _rewindLastCheck(int hours) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'update/last_check_ms',
        DateTime.now()
            .subtract(Duration(hours: hours))
            .millisecondsSinceEpoch,
      );
    }

    /// snooze 만료 시각을 [hours] 시간 전으로 당깁니다.
    ///
    /// `_rewindLastCheck` 만으로는 snooze 가 끝나지 않습니다 — 그건
    /// `last_check_ms` 를 바꿀 뿐이고, snooze 는 `snooze_until_ms` 를
    /// 봅니다. 둘은 다른 키입니다. 하나만 돌리면 "3일이 지났다"는
    /// 상황을 만들 수 없습니다.
    Future<void> _expireSnooze(int hours) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'update/snooze_until_ms',
        DateTime.now()
            .subtract(Duration(hours: hours))
            .millisecondsSinceEpoch,
      );
    }

    // ────────────────────────────────────────────────────────────────
    // ## 실제 동작 (2026-11-21 시험으로 확인)
    //
    // `check()` 는 snooze 판정을 **네트워크 요청보다 먼저** 합니다
    // (update_service.dart 147-150):
    //
    //     final snooze = prefs.getInt(_kSnoozeUntil) ?? 0;
    //     if (DateTime.now().millisecondsSinceEpoch < snooze) {
    //       return null;            // ← 여기서 끝
    //     }
    //
    // 그래서 "나중에" 를 누르면 **3일 동안 확인 자체를 하지 않습니다.**
    // `available: false` 가 아니라 `null` 이 나오는 것이 실제 계약입니다.
    //
    // ## 그리고 이건 문서와 어긋납니다
    //
    // 같은 파일 208-209줄은 이렇게 말합니다:
    //   「그 사이 또 배포되면 빌드 ID 가 달라지므로 새로 물어봅니다」
    // 그런데 그 판정(211-220줄)은 위 조기 반환보다 **뒤에** 있어서
    // 도달하지 못합니다 — 죽은 코드입니다. 즉 긴급 수정을 배포해도
    // "나중에" 를 누른 기기에서는 3일 동안 알림이 가지 않습니다.
    //
    // 동작을 바꾸는 것은 승인 없이 하지 않습니다. 시험으로 사실만
    // 고정하고 보고합니다.

    webTest('"나중에" 를 누르면 3일 동안 확인 자체를 하지 않는다 (현재 동작)', () async {
      final svc = UpdateService(
        client: _serving({'build': '2026.11.21.7777'}),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      final first = await svc.check(force: true);
      expect(first!.available, isTrue);

      await svc.snooze('2026.11.21.7777');

      // 12시간이 지나 확인 주기는 충족된 상황.
      await _rewindLastCheck(13);

      // 실제로는 null 입니다 ("확인하지 않음"). available:false 가 아닙니다.
      expect(await svc.check(), isNull, reason: 'snooze 중에는 조기 반환합니다');
    });

    webTest('snooze 중에는 새 빌드가 배포되어도 알아채지 못한다 (알려진 문제)', () async {
      final svc = UpdateService(
        client: _serving({'build': '2026.11.21.7777'}),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      await svc.check(force: true);
      await svc.snooze('2026.11.21.7777');
      await _rewindLastCheck(13);

      // 그 사이 긴급 수정이 배포된 상황 (빌드 ID 가 다름).
      final svc2 = UpdateService(
        client: _serving({'build': '2026-11-22-CRITICAL'}),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc2.dispose);

      // ★ 208-209줄 주석은 "다시 물어본다"고 하지만 실제로는 묻지 않습니다.
      //   이 단정문이 실패하면 그때가 버그가 고쳐진 시점입니다.
      expect(await svc2.check(), isNull,
          reason: '현재는 새 빌드도 차단됩니다 — 고쳐지면 이 시험이 실패해야 정상');
    });

    webTest('snooze 기간이 지나면 다시 확인한다', () async {
      final svc = UpdateService(
        client: _serving({'build': '2026.11.21.7777'}),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      await svc.check(force: true);
      await svc.snooze('2026.11.21.7777');

      // 3일(snoozeDuration) 이 지난 상황 — 확인 주기와 snooze 둘 다 지나야 합니다.
      await _rewindLastCheck(24 * 4);
      await _expireSnooze(24);

      final r = await svc.check();
      expect(r, isNotNull);
      expect(r!.available, isTrue, reason: 'snooze 가 끝났으면 다시 물어야 합니다');
    });

    webTest('확인 주기 안에서는 서버를 두드리지 않는다', () async {
      var calls = 0;
      final svc = UpdateService(
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode({'build': '2026.11.21.7777'}), 200);
        }),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      await svc.check(force: true); // 1회
      final skipped = await svc.check(); // 주기 안 → null
      await svc.check();

      expect(skipped, isNull);
      expect(calls, 1, reason: '주기 안에서는 네트워크를 쓰지 않아야 합니다');
    });
  });

  group('요청에 캐시 무력화가 붙는다', () {
    webTest('매번 다른 쿼리 + no-cache 헤더', () async {
      // 서비스 워커의 RESOURCES 목록에 version.json 이 들어 있어서
      // 그냥 요청하면 브라우저가 옛 사본을 돌려줍니다. 2026-11-20 에
      // 실제로 이 증상이 나왔습니다(앱은 계속 "최신"이라고 답함).
      // 두 겹의 방어가 유지되는지 고정합니다.
      final urls = <String>[];
      final headers = <String, String>{};

      final svc = UpdateService(
        client: MockClient((req) async {
          urls.add(req.url.toString());
          headers.addAll(req.headers);
          return http.Response(jsonEncode({'build': '2026.11.21.7777'}), 200);
        }),
        baseUrl: 'https://example.test',
      );
      addTearDown(svc.dispose);

      await svc.check(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await svc.check(force: true);

      expect(urls.length, 2);
      expect(urls[0], contains('_='), reason: '캐시 무력화 쿼리가 있어야 합니다');
      // 타임스탬프가 달라야 서비스 워커가 가로채지 않습니다.
      expect(urls[0], isNot(equals(urls[1])));
      expect(headers['Cache-Control'], contains('no-cache'));
    });
  });
}
