// 스킨 선택 패널이 실제로 압축됐는가 — 그리고 다시 부풀지 않는가.
//
// ## 왜 높이를 재는 테스트인가
// "패널을 압축했다"는 말은 눈으로 확인하기 어렵다. 조금 줄어도 줄어든 것처럼
// 보이고, 여백을 하나 늘려도 여전히 "압축된 패널"처럼 보인다. 이 패널이
// 부풀면 생기는 실제 증상은 딱 하나다: **글자 크기를 키우려고 연 사람이
// 글자 크기를 못 찾는다.** 그래서 화면 밖으로 밀려나는지를 직접 잰다.
//
// ## 측정하기 전의 실제 상태 (기록)
// 390×760 화면에서 이 패널은:
//   스킨 선택 346px · 화면 테마 699px · 손글씨 804px · 글꼴 875px · 글자 크기 1159px
// 손글씨·글꼴·글자 크기 셋 다 화면 아래였다. 스크롤하면 되지만, 스크롤이
// 있다는 것 자체를 모르는 사람에게는 없는 것과 같다.
//
// ## 그리고 이건 "모든 모드에서" 라는 요구를 지키는 테스트다
// 테마를 고르는 도중에 패널 크기가 테마를 따라 변하면, 무엇을 기준으로
// 비교하는 중인지가 흔들린다. 그래서 이 패널은 minimalChrome 을 읽지 않는다.
// 그 약속을 여기서 잰다 — 모드를 바꿔도 패널의 각 요소 위치가 같아야 한다.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/l10n/l10n.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/store.dart';
import 'package:june_scheduler/theme/app_theme.dart';
import 'package:june_scheduler/widgets/skin_lang_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Store store;
  var opened = false;

  /// 박스는 파일 전체에서 한 번만 연다.
  ///
  /// 테스트마다 `Hive.close()` 후 다시 열면 두 번째 테스트가 영원히 끝나지
  /// 않는다 (`did not complete`). testWidgets 의 가짜 시계 아래에서 close 의
  /// future 가 완료되지 않기 때문이다. 같은 함정에 두 번 빠지지 않으려고
  /// 여기에도 적어 둔다.
  Future<void> openStoreOnce() async {
    if (opened) return;
    opened = true;
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('skinpanel_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    store = Store();
    await store.init();
    store.useBackend(const NullBackend());
  }

  /// 정해진 화면 크기에서 패널을 연다.
  Future<void> openPanel(
    WidgetTester tester, {
    Size size = const Size(390, 760),
  }) async {
    await tester.runAsync(openStoreOnce);
    L10n.currentLang = AppLang.ko;

    setDesign('paper');
    setFontPrefs('system', 1.0);
    setHandwriting(false);
    setMinimalChrome(true);
    setGlobalBrightness(Brightness.light);

    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<Store>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.build(AppSkins.defaultId, Brightness.light),
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    await tester.pump();

    showSkinPicker(tester.element(find.byType(Scaffold)), store);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 요소의 세로 위치. 없으면 실패시킨다 — "안 보임" 과 "없음" 은 다르지만
  /// 여기서는 둘 다 같은 문제다.
  double topOf(WidgetTester tester, Finder f, String what) {
    expect(f, findsWidgets, reason: '$what 를 찾지 못했다');
    return tester.getRect(f.first).top;
  }

  tearDown(() {
    try {
      store.sync.stop();
    } catch (_) {}
  });

  testWidgets('390×760 에서 글자 크기 슬라이더가 스크롤 없이 보인다', (tester) async {
    await openPanel(tester);

    final slider = find.byType(Slider);
    expect(slider, findsOneWidget, reason: '슬라이더 자체가 없다');

    final rect = tester.getRect(slider);
    expect(
      rect.bottom,
      lessThanOrEqualTo(760),
      reason: '슬라이더 아래끝이 ${rect.bottom.toStringAsFixed(1)}px — '
          '화면(760) 밖이다. 이 패널을 여는 이유가 대개 글자 크기인데 '
          '그것이 가장 멀리 있으면 안 된다',
    );
    expect(rect.top, greaterThanOrEqualTo(0));
  });

  testWidgets('모든 항목이 한 화면에 들어온다', (tester) async {
    await openPanel(tester);

    const items = ['스킨 선택', '화면 테마', '손글씨 펜 글씨', '글꼴', '글자 크기'];
    for (final label in items) {
      final top = topOf(tester, find.text(label), label);
      expect(
        top,
        lessThan(760),
        reason: '$label 이 ${top.toStringAsFixed(1)}px 지점 — 스크롤해야 보인다',
      );
    }

    // 순서도 확인한다. 내용은 남았는데 순서가 뒤집히면 같은 문제다.
    final tops = [for (final l in items) topOf(tester, find.text(l), l)];
    for (var i = 1; i < tops.length; i++) {
      expect(
        tops[i],
        greaterThan(tops[i - 1]),
        reason: '${items[i]} 가 ${items[i - 1]} 보다 위에 있다 — 순서가 뒤집혔다',
      );
    }
  });

  testWidgets('360×640 처럼 작은 화면에서도 전부 들어온다', (tester) async {
    await openPanel(tester, size: const Size(360, 640));

    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    expect(
      tester.getRect(slider).bottom,
      lessThanOrEqualTo(640),
      reason: '작은 화면에서 슬라이더가 다시 화면 밖으로 밀렸다',
    );
  });

  testWidgets('스킨 타일이 세 열로 놓인다 (두 열이면 네 줄이 된다)', (tester) async {
    await openPanel(tester);

    // 각 스킨 이름의 x 좌표를 모아 '열'의 개수를 센다.
    final xs = <double>{};
    for (final id in AppSkins.ids) {
      final f = find.text(skinName(id));
      expect(f, findsOneWidget, reason: '${skinName(id)} 타일이 없다');
      // 소수점 흔들림을 없애기 위해 4px 단위로 묶는다.
      xs.add((tester.getRect(f).left / 4).round() * 4.0);
    }

    expect(
      xs.length,
      3,
      reason: '열이 ${xs.length}개다. 3열이어야 7개가 3줄에 앉는다 '
          '(2열이면 4줄 — 예전 상태)',
    );
  });

  testWidgets('테마와 무관하게 패널 크기가 같다 (모든 모드에서 동일)', (tester) async {
    // 먼저 압축 크롬이 켜진 상태에서 잰다.
    await openPanel(tester);
    final withMinimal = [
      for (final l in ['스킨 선택', '글꼴', '글자 크기'])
        topOf(tester, find.text(l), l),
    ];
    final sliderWithMinimal = tester.getRect(find.byType(Slider)).bottom;

    // 패널을 닫고, 압축 크롬을 끈 채로 다시 연다.
    Navigator.of(tester.element(find.byType(Scaffold))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    setMinimalChrome(false);
    setDesign('terminal'); // 고밀도 테마까지 겹쳐서
    await tester.pump();

    showSkinPicker(tester.element(find.byType(Scaffold)), store);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final withoutMinimal = [
      for (final l in ['스킨 선택', '글꼴', '글자 크기'])
        topOf(tester, find.text(l), l),
    ];

    expect(
      withoutMinimal,
      withMinimal,
      reason: '테마를 바꾸자 패널의 항목 위치가 달라졌다. '
          '이 패널은 테마를 *고르는* 자리이므로 크기가 흔들리면 안 된다',
    );
    expect(
      tester.getRect(find.byType(Slider)).bottom,
      sliderWithMinimal,
      reason: '슬라이더 위치가 테마에 따라 움직인다',
    );
  });
}
