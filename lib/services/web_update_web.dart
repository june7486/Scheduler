// 웹 전용 구현 — 브라우저 캐시를 비우고 새 번들을 받게 합니다.
//
// ## 여기서 하려는 일
// 파일은 이미 서버에 있습니다. 브라우저가 옛 사본을 들고 있을 뿐입니다.
// 그래서 "업데이트"는 새로 다운로드하는 일이 아니라 **캐시를 잊게 하는 일**
// 입니다. 구체적으로 세 가지를 합니다:
//
//   1. 서비스 워커 등록 해제 + 캐시 저장소 비우기
//   2. 현재 페이지를 캐시 무시 쿼리로 다시 요청
//
// ## 왜 Dart 로 안 하고 index.html 의 함수를 부르는가
// 서비스 워커와 CacheStorage 는 JS API 입니다. Dart 에서도 js_interop 으로
// 닿을 수 있지만, 그러면 이 파일이 js 라이브러리에 묶여서 컴파일이
// 까다로워집니다. index.html 에 작은 함수 하나를 두고 그것을 부르는 편이
// 단순하고, 나중에 그 함수만 고쳐도 됩니다.
//
// ## 실패해도 새로고침은 합니다
// 서비스 워커 해제가 실패하는 경우가 있습니다(다른 탭이 잡고 있는 등).
// 그때 아무것도 안 하면 사용자는 "업데이트를 눌렀는데 아무 일도 안 일어났다"
// 로 경험합니다. 최소한 새로고침은 해야 합니다.

import 'dart:js_interop';

@JS('juneForceUpdate')
external JSFunction? _juneForceUpdate();

/// 브라우저에게 "새 번들을 받아라"고 시킵니다.
///
/// `web/index.html` 에 정의된 `window.juneForceUpdate()` 를 부릅니다.
/// 그 함수가 없으면(구버전 HTML) 호출이 실패하는데, 그 경우에도
/// 아래 fallback 이 새로고침은 보장합니다.
Future<void> applyWebUpdateImpl() async {
  try {
    final fn = _juneForceUpdate();
    if (fn != null) {
      // JS 쪽 함수를 그대로 호출합니다. callMethod 를 쓰면 JSAny 라서
      // 메서드를 못 찾습니다(실제로 analyze 가 잡았습니다).
      fn.callAsFunction();
    }
  } catch (_) {
    // 함수가 없거나 호출이 실패했습니다. index.html 쪽 fallback 에 맡깁니다.
  }
}
