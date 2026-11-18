// 홈 화면의 두 가지 약속을 고정한다.
//
//  1. 완료됨 구역도 지금 고른 밀도 테마를 따라간다.
//  2. 할 일 추가는 위에도 있고 아래(FAB)에도 있다. 둘 중 하나가 사라지면 실패.
//
// ## 왜 이 테스트가 필요한가
// 두 항목 모두 "고쳤다"고 말하기 쉬운 종류의 일이다.
//
// 완료됨 구역은 오랫동안 별도의 작은 위젯으로 그려졌다. 그 위젯은 테마를 읽지
// 않았고 배경색이 `0xFFF7F8FC` 로 박혀 있었다. 그래서 고밀도 테마를 골라도 이
// 구역만 예전 모양 그대로였는데, 눈으로는 "조금 다르네" 정도로 보여서 지나치기
// 쉽다. 숫자로 잡아 둔다 — 완료 행의 높이가 테마를 따라 줄어들어야 한다.
//
// 상단 추가 버튼은 더 위험하다. 나중에 상단 바를 정리하다가 "중복이네" 하고
// 지우면, 하단 FAB 만 남아도 화면은 멀쩡해 보인다. 그런데 넓은 화면에서 목록을
// 읽는 눈은 위에 있고, FAB 은 반대편 구석이다. 그래서 개수를 센다: 두 개여야 한다.
//
// ## 준비(prepare)와 그리기(pump)를 나눈 이유
// 계정을 만들고 완료 항목을 넣는 일은 **한 번만** 해야 한다. 테마를 바꿔 가며
// 여러 번 그리는 테스트에서 준비까지 매번 돌리면 같은 제목의 항목이 쌓여
// `findsOneWidget` 이 무너진다. 한 번 준비하고, 여러 번 그린다.
//
// ## 그리고 여기서 또 한 번 크게 걸렸다 — Hive 를 두 번 열지 말 것
// 처음에는 테스트마다 `Hive.close()` 로 닫고 새 임시 폴더에 다시 열었다.
// 첫 테스트는 통과했고 둘째 테스트는 **6분을 기다려도 끝나지 않았다**
// ("did not complete"). 원인은 두 번째 `Hive.close()` 다. 앞 테스트의 Store 가
// 남긴 동기화 타이머가 박스에 마지막으로 쓰는 중이면 close 는 그 쓰기를 기다리고,
// testWidgets 의 가짜 시계 아래에서는 그 future 가 영원히 완료되지 않는다.
// 파일 하나에 박스 하나. 열면 파일이 끝날 때까지 그대로 둔다.
// 프로세스가 끝나면 OS 가 임시 폴더를 회수한다.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/l10n/l10n.dart';
import 'package:june_scheduler/screens/home_screen.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/store.dart';
import 'package:june_scheduler/theme/app_theme.dart';
import 'package:june_scheduler/widgets/task_row.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Store store;
  var prepared = false;

  /// 진짜 Hive 박스 위에 Store 하나를 띄운다. **파일 전체에서 한 번만.**
  ///
  /// `Hive.initFlutter()` 가 path_provider 를 부르므로 채널을 가짜로 물려야
  /// 한다. 이걸 빠뜨리면 테스트가 아니라 플러그인 예외가 먼저 난다.
  Future<void> openStoreOnce() async {
    if (prepared) return;
    prepared = true;

    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('home_chrome_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    store = Store();
    await store.init();
    store.useBackend(const NullBackend());

    // 빈 Store 에는 분류가 없다. 분류는 로그인(`_ensureUserSeed`)이나 명시적
    // seed 호출로만 생기므로, 카테고리 없이 화면을 띄우면 홈 화면이
    // `enabledCategories.first` 에서 터진다. 테스트도 사람과 같은 경로로
    // 들어가야 한다 — 그래야 그 뒤에 벌어지는 일도 사람이 겪는 일이다.
    await store.addUser('tester', 'testpw12', displayName: '테스터');
    await store.authenticate('tester', 'testpw12');

    // 완료된 항목 하나. 제목으로 정확히 짚기 위한 표식이다.
    final cat = store.enabledCategories.first;
    final t = await store.addTask('완료된 항목', cat.id);
    await store.toggleComplete(t);
  }

  /// store 준비를 진짜 비동기 영역에서 돌린다.
  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(openStoreOnce);
  }

  /// 홈 화면을 그린다. 몇 번이든 불러도 된다.
  Future<void> pumpHome(
    WidgetTester tester, {
    String designId = 'paper',
    double width = 900,
    Brightness brightness = Brightness.light,
  }) async {
    L10n.currentLang = AppLang.ko;

    // 전역 테마 상태를 화면과 맞춘다. main.dart 가 하는 일을 테스트에서 손으로.
    setDesign(designId);
    setFontPrefs('system', 1.0);
    setHandwriting(false);
    setMinimalChrome(store.minimalChromeKey);
    setGlobalBrightness(brightness);

    tester.view.physicalSize = Size(width * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<Store>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.build(AppSkins.defaultId, brightness),
          // ## `const HomeScreen()` 이면 안 된다 — 여기서 한 번 크게 데였다
          // 한 테스트 안에서 테마를 바꿔 가며 여러 번 그리는데, `const` 생성자는
          // 컴파일 타임에 **같은 인스턴스로 정규화**된다. 그러면 두 번째
          // `pumpWidget` 에서 Flutter 는 "새 위젯 == 옛 위젯" 이라 보고
          // `Element.updateChild` 에서 곧바로 반환한다 — build 를 아예 부르지
          // 않는다. 화면은 첫 테마 그대로인데 테스트는 통과한 것처럼 보이고,
          // 실제로는 모든 테마의 행 높이가 똑같이 측정된다(98px).
          // key 를 조합마다 바꿔 새 Element 를 만들면 매번 실제로 그린다.
          home: HomeScreen(key: ValueKey('$designId-$brightness-$width')),
        ),
      ),
    );
    // 홈 화면은 첫 프레임 뒤에 기본 항목(월세·창고비·생활 루틴)을 스스로 심고,
    // 그때 목록이 한 번 더 그려진다. pumpAndSettle 은 쓰지 않는다 — 스크롤
    // 리스너가 붙어 있어 조용해지지 않을 수 있다.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  tearDown(() {
    // 동기화만 세운다. Hive 는 닫지 않는다 — 위 주석의 이유.
    try {
      store.sync.stop();
    } catch (_) {}
  });

  group('할 일 추가 버튼은 위아래 두 곳에 있다', () {
    testWidgets('상단 바와 하단 FAB 이 같은 문구로 함께 존재한다', (tester) async {
      await prepare(tester);
      await pumpHome(tester);

      expect(
        find.text('할일 추가'),
        findsNWidgets(2),
        reason: '상단 버튼과 FAB 이 각각 하나씩, 모두 두 개여야 한다',
      );
      expect(
        find.byType(FloatingActionButton),
        findsOneWidget,
        reason: '기존 하단 FAB 이 사라졌다 — "기존위치도 유지" 위반',
      );
      // 상단 버튼은 Tooltip 을 달고 있다. 좁은 화면에서 글자를 뺄 때도
      // 뜻이 남아야 하므로 이 Tooltip 은 기능의 일부다.
      expect(find.byTooltip('할일 추가'), findsOneWidget);
    });

    testWidgets('좁은 화면에서도 상단 버튼은 사라지지 않고 아이콘만 남는다', (tester) async {
      await prepare(tester);
      // 480px 미만 — 상단 바에서 글자를 빼는 구간.
      await pumpHome(tester, width: 400);

      // 글자는 FAB 하나만 갖는다.
      expect(
        find.text('할일 추가'),
        findsOneWidget,
        reason: '좁은 화면에서 상단 버튼이 글자까지 달고 탭을 밀어내고 있다',
      );
      // 그래도 버튼 자체는 살아 있어야 한다.
      expect(find.byTooltip('할일 추가'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('상단 버튼을 누르면 할 일 편집기가 열린다', (tester) async {
      await prepare(tester);
      await pumpHome(tester);

      await tester.tap(find.byTooltip('할일 추가'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 편집기는 홈이 아닌 새 화면이다. 홈 화면이 뒤로 밀렸는지로 확인한다.
      expect(
        find.byType(HomeScreen),
        findsNothing,
        reason: '상단 버튼이 아무 일도 하지 않았다',
      );
    });
  });

  group('완료됨 구역이 밀도 테마를 따라간다', () {
    /// 우리가 넣은 그 완료 항목을 그리는 TaskRow 하나를 짚는다.
    final doneRow = find.ancestor(
      of: find.text('완료된 항목'),
      matching: find.byType(TaskRow),
    );

    Future<double> completedRowHeight(
      WidgetTester tester,
      String designId,
    ) async {
      await pumpHome(tester, designId: designId);
      expect(
        doneRow,
        findsOneWidget,
        reason: '$designId — 완료 구역에 TaskRow 가 그려지지 않았다. '
            '별도 위젯으로 되돌아갔다는 뜻이고, 그러면 테마를 다시 무시한다',
      );
      return tester.getSize(doneRow).height;
    }

    testWidgets('종이 테마의 완료 행보다 터미널 테마의 완료 행이 낮다', (tester) async {
      await prepare(tester);
      final paper = await completedRowHeight(tester, 'paper');
      final terminal = await completedRowHeight(tester, 'terminal');

      expect(
        terminal,
        lessThan(paper),
        reason: '종이 ${paper.toStringAsFixed(1)}px vs '
            '터미널 ${terminal.toStringAsFixed(1)}px — 완료 구역이 밀도를 못 따라간다',
      );
    });

    testWidgets('고밀도 다섯 테마 모두 완료 행이 종이보다 낮다', (tester) async {
      await prepare(tester);
      final paper = await completedRowHeight(tester, 'paper');
      for (final id in AppDesigns.denseIds) {
        final h = await completedRowHeight(tester, id);
        expect(
          h,
          lessThan(paper),
          reason: '$id 완료 행이 ${h.toStringAsFixed(1)}px 로 '
              '종이 ${paper.toStringAsFixed(1)}px 보다 낮지 않다',
        );
      }
    });

    testWidgets('어두운 화면에서 완료 구역이 흰 띠로 남지 않는다', (tester) async {
      await prepare(tester);
      await pumpHome(
        tester,
        designId: 'terminal',
        brightness: Brightness.dark,
      );

      // '완료됨' 제목을 감싸는 첫 Container 가 이 구역의 바탕이다.
      final ancestors = tester.widgetList<Container>(
        find.ancestor(
          of: find.text('완료됨'),
          matching: find.byType(Container),
        ),
      );
      final wrapper = ancestors.firstWhere(
        (c) =>
            c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).color != null,
        orElse: () => throw StateError('완료 구역 바탕 Container 를 찾지 못했다'),
      );
      final color = (wrapper.decoration as BoxDecoration).color!;

      expect(
        color,
        isNot(const Color(0xFFF7F8FC)),
        reason: '예전 하드코딩 배경색이 돌아왔다',
      );
      expect(
        color.computeLuminance(),
        lessThan(0.35),
        reason: '어두운 화면인데 완료 구역 바탕이 밝다 '
            '(luminance ${color.computeLuminance().toStringAsFixed(2)})',
      );
    });
  });
}
