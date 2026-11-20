import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ## 조건부 import — 플랫폼별 구현을 고르는 문법
// 왼쪽(웹)이 참이면 web_update_web.dart 를, 아니면 stub 을 씁니다.
// 두 파일 모두 applyWebUpdateImpl() 을 같은 이름으로 제공하므로
// 아래 코드는 플랫폼을 신경 쓰지 않아도 됩니다.
import 'web_update_stub.dart'
    if (dart.library.js_interop) 'web_update_web.dart';

/// Checks whether a newer build of the app has been deployed.
///
/// ## 왜 자동 업데이트가 아니라 "물어보는" 업데이트인가
///
/// 이 앱은 사용자가 일정을 쓰는 도구입니다. 자동으로 새로고침하면 **입력 중인
/// 내용이 사라집니다.** 오전에 회의록을 쓰다가 갑자기 화면이 깜빡이면 그건
/// 업데이트가 아니라 사고입니다.
///
/// 그래서 흐름은 이렇게 설계했습니다:
///
///   1. 앱이 조용히 새 빌드가 있는지 물어본다 (사용자는 모름)
///   2. 있으면 **팝업으로 알린다** — 무엇이 바뀌었는지 함께 보여준다
///   3. 사용자가 "지금 업데이트" 또는 "나중에"를 고른다
///   4. "나중에"를 고르면 그 결정을 기억하고 한동안 다시 묻지 않는다
///
/// 이게 "자발적 업데이트 유도"입니다. 강제하지 않되, 모르고 지나가지도 않게.
///
/// ## 무엇을 비교하는가
///
/// `version.json` 의 `build` 값과 지금 실행 중인 빌드(`BUILD_ID`)를 비교합니다.
/// 앱 버전(`1.0.0+1`)은 사람이 정하는 값이라 배포마다 바뀌지 않습니다.
/// 반면 `BUILD_ID` 는 배포 스크립트가 빌드 시각으로 넣으므로 **배포할 때마다
/// 반드시 달라집니다.** "새 빌드가 떴는가"를 묻는 질문에는 이쪽이 정답입니다.
///
/// ## 왜 `version.json` 인가
///
/// 서비스 워커가 캐시하는 파일이 아닙니다. Nginx/GitHub Pages 설정에서
/// `no-cache` 로 두면 항상 서버의 최신 값을 읽습니다. `main.dart.js` 를
/// 직접 받아 해시를 비교하는 방법도 있지만, 3.8MB 를 매번 내려받는 건
/// 낭비입니다. 98바이트짜리 JSON 이면 충분합니다.
///
/// ## 실패는 조용해야 합니다
///
/// 네트워크가 없거나, 오프라인이거나, 서버가 잠깐 죽었을 때 이 기능이
/// 사용자에게 오류를 띄우면 안 됩니다. 업데이트 확인은 **부가 기능**이고,
/// 실패해도 앱은 그대로 쓸 수 있어야 합니다. 그래서 모든 예외를 삼키고
/// "확인 못 함"으로 끝냅니다.
class UpdateService {
  UpdateService({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      _baseUrl = baseUrl;

  final http.Client _client;
  final String? _baseUrl;

  /// 지금 실행 중인 빌드. `--dart-define=BUILD_ID=...` 에서 옵니다.
  ///
  /// 비어 있으면 이 빌드는 BUILD_ID 없이 만들어졌다는 뜻이고, 그러면
  /// 비교할 기준이 없으므로 업데이트 확인을 하지 않습니다.
  static const String currentBuildId = String.fromEnvironment('BUILD_ID');

  /// 확인을 시도할 최소 간격.
  ///
  /// 앱을 열 때마다 서버를 두드리면 로그만 채우고 얻는 게 없습니다.
  /// 하루에 한 번이면 충분합니다.
  static const Duration checkInterval = Duration(hours: 12);

  /// "나중에"를 눌렀을 때 다시 묻지 않을 기간.
  ///
  /// 너무 짧으면 성가시고, 너무 길면 새 버전이 있어도 모릅니다.
  /// 3일로 잡았습니다 — 사용자가 "이번 주에 한 번은" 보게 되는 정도.
  static const Duration snoozeDuration = Duration(days: 3);

  static const String _kLastCheck = 'update/last_check_ms';
  static const String _kSnoozeUntil = 'update/snooze_until_ms';
  static const String _kSkippedBuild = 'update/skipped_build';

  /// 서버에서 읽어올 주소.
  ///
  /// 배포 위치 기준 상대경로입니다. GitHub Pages 든 가비아 Nginx 든
  /// 앱이 서빙되는 곳 옆에 `version.json` 이 있으므로 그대로 동작합니다.
  /// (절대 주소를 박으면 이전할 때마다 코드를 고쳐야 합니다)
  ///
  /// ## 캐시 무력화 쿼리가 붙어 있는 이유
  /// Flutter 가 만든 서비스 워커는 `version.json` 을 **자기 캐시 목록에
  /// 넣습니다** (`RESOURCES` 상수). 그리고 목록에 있는 파일은
  /// *캐시 우선*으로 응답합니다. 즉 그냥 `version.json` 을 요청하면
  /// 브라우저는 **서비스 워커가 들고 있는 옛 사본**을 받습니다.
  ///
  /// 그러면 이 기능이 정확히 반대로 동작합니다 — 새 빌드가 배포되어도
  /// 앱은 영원히 "최신입니다"라고 답합니다. 2026-11-20 시험에서 실제로
  /// 이 증상이 나왔습니다(캐시된 0900, 서버는 1000).
  ///
  /// 서비스 워커는 자기 목록에 **없는** URL 이면 가로채지 않고
  /// 브라우저에 넘깁니다. 그래서 매번 다른 쿼리를 붙이면 요청이
  /// 목록 밖이 되어 네트워크로 나갑니다. `Cache-Control: no-cache`
  /// 헤더만으로는 부족합니다 — 그건 HTTP 캐시에만 유효하고, 서비스
  /// 워커의 캐시 우선 전략은 그 헤더를 보지 않습니다.
  Uri get _versionUri {
    final base = _baseUrl ?? _defaultBase();
    final plain = Uri.parse('$base/version.json');
    return plain.replace(
      queryParameters: {'_': DateTime.now().millisecondsSinceEpoch.toString()},
    );
  }

  String _defaultBase() {
    // 웹에서는 지금 페이지의 출처를 그대로 씁니다. 이러면 로컬 미리보기
    // (http://127.0.0.1:5060) 에서도, 운영(https://www.aqdesign.co.kr) 에서도
    // 각자 자기 서버의 version.json 을 봅니다 — 코드 수정이 필요 없습니다.
    if (kIsWeb) {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && origin != 'null') return origin;
    }
    return '';
  }

  /// 서버에 새 빌드가 있는지 확인합니다.
  ///
  /// 반환값이 null 이면 "확인할 수 없었다"는 뜻입니다 (네트워크 오류,
  /// BUILD_ID 없음, JSON 깨짐 등). 호출하는 쪽은 null 을 "없음"으로
  /// 취급해야 합니다 — 오류를 띄우지 않습니다.
  Future<UpdateCheck?> check({bool force = false}) async {
    // ## BUILD_ID 가 없으면 확인하지 않습니다
    // 비교 기준이 없는데 "새 버전이 있습니다"라고 하면 거짓말이 됩니다.
    // 이 빌드가 언제 것인지 모르면서 저쪽이 더 새것인지 알 수 없으니까요.
    if (currentBuildId.isEmpty) return null;

    // 웹이 아니면 이 방식은 의미가 없습니다 (모바일 앱은 스토어 업데이트).
    if (!kIsWeb) return null;

    final prefs = await SharedPreferences.getInstance();

    if (!force) {
      final last = prefs.getInt(_kLastCheck) ?? 0;
      final elapsed = DateTime.now().millisecondsSinceEpoch - last;
      if (elapsed < checkInterval.inMilliseconds) {
        // 아직 확인할 때가 아닙니다. 다만 "확인 안 함"과 "새 버전 없음"은
        // 다르므로 null 을 돌려줍니다.
        return null;
      }

      final snooze = prefs.getInt(_kSnoozeUntil) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch < snooze) {
        return null;
      }
    }

    String? remoteBuild;
    String? remoteVersion;
    String? notes;

    try {
      // ## 두 겹으로 캐시를 피합니다
      // 1) URL 에 매번 다른 쿼리 (_=...) — 서비스 워커의 RESOURCES 목록
      //    밖으로 나가므로 워커가 가로채지 않습니다.
      // 2) Cache-Control: no-cache — 그 사이에 낀 HTTP 캐시까지 막습니다.
      //
      // 둘 중 하나만으로는 부족합니다. 쿼리만 붙이면 중간 프록시가 같은
      // 쿼리를 재사용할 수 있고, 헤더만 붙이면 서비스 워커가 먼저 답합니다.
      final res = await _client
          .get(
            _versionUri,
            headers: {
              'Cache-Control': 'no-cache, no-store, max-age=0',
              'Pragma': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 6));

      if (res.statusCode != 200) return null;

      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map) return null;

      remoteBuild = (body['build'] ?? body['build_id'] ?? '') as String?;
      remoteVersion = body['version'] as String?;
      notes = body['notes'] as String?;

      // 확인 시각을 기록합니다. 실패했을 때는 기록하지 않습니다 —
      // 서버가 잠깐 죽었다고 12시간 동안 확인을 안 하면 안 되니까요.
      await prefs.setInt(_kLastCheck, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // ## 여기서 조용히 끝나는 것이 의도입니다
      // 오프라인, 타임아웃, DNS 실패, JSON 깨짐 — 전부 같은 처리입니다.
      // 업데이트 확인 실패는 사용자가 알 필요가 없는 실패입니다.
      return null;
    }

    if (remoteBuild == null || remoteBuild.isEmpty) return null;

    // 같으면 새 빌드가 없습니다.
    if (remoteBuild == currentBuildId) {
      return UpdateCheck(
        available: false,
        currentBuild: currentBuildId,
        remoteBuild: remoteBuild,
        remoteVersion: remoteVersion,
      );
    }

    // ## 이미 건너뛰기로 한 빌드인가
    // "나중에"를 누른 그 빌드가 여전히 최신이면 다시 묻지 않습니다.
    // 그 사이 또 배포되면 빌드 ID 가 달라지므로 새로 물어봅니다.
    final skipped = prefs.getString(_kSkippedBuild) ?? '';
    if (!force && skipped == remoteBuild) {
      final until = prefs.getInt(_kSnoozeUntil) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch < until) {
        return UpdateCheck(
          available: false,
          currentBuild: currentBuildId,
          remoteBuild: remoteBuild,
          remoteVersion: remoteVersion,
        );
      }
    }

    return UpdateCheck(
      available: true,
      currentBuild: currentBuildId,
      remoteBuild: remoteBuild,
      remoteVersion: remoteVersion,
      notes: notes,
    );
  }

  /// 사용자가 "나중에"를 골랐을 때 호출합니다.
  ///
  /// 이 빌드에 대해서는 [snoozeDuration] 동안 다시 묻지 않습니다.
  Future<void> snooze(String remoteBuild) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSkippedBuild, remoteBuild);
    await prefs.setInt(
      _kSnoozeUntil,
      DateTime.now().add(snoozeDuration).millisecondsSinceEpoch,
    );
  }

  /// 사용자가 "지금 업데이트"를 골랐을 때 호출합니다.
  ///
  /// ## 웹에서 "업데이트"란 결국 새로고침입니다
  /// 파일은 이미 서버에 있습니다. 브라우저가 옛 것을 들고 있을 뿐이므로,
  /// 서비스 워커와 캐시를 비우고 페이지를 다시 받으면 됩니다.
  ///
  /// 이 처리는 `web/index.html` 의 `window.juneForceUpdate()` 가 합니다.
  /// Dart 에서 브라우저 캐시를 직접 비울 방법이 없어서, 그 함수를 부릅니다.
  /// 함수가 없으면(구버전 HTML) 그냥 새로고침합니다 — 최소한의 동작은 보장.
  static Future<void> applyUpdate() async {
    if (!kIsWeb) return;

    try {
      await applyWebUpdateImpl();
    } catch (_) {
      // 이 함수가 실패해도 사용자를 막지 않습니다.
    }
  }

  void dispose() => _client.close();
}

/// Result of an update check.
class UpdateCheck {
  const UpdateCheck({
    required this.available,
    required this.currentBuild,
    required this.remoteBuild,
    this.remoteVersion,
    this.notes,
  });

  /// 서버에 지금 실행 중인 것과 다른 빌드가 있는가.
  final bool available;

  /// 지금 실행 중인 빌드 ID.
  final String currentBuild;

  /// 서버에 올라가 있는 빌드 ID.
  final String remoteBuild;

  /// 서버의 앱 버전 (`1.0.0` 등). 표시용.
  final String? remoteVersion;

  /// 이 빌드에 대한 짧은 설명. `version.json` 의 `notes`.
  final String? notes;
}
