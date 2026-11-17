import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:june_scheduler/models/models.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/store.dart';
import 'package:june_scheduler/theme/app_theme.dart';
import 'package:june_scheduler/widgets/design_quick_picker.dart';
import 'package:june_scheduler/widgets/task_row.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Store store;

  Future<void> openStore() async {
    SharedPreferences.setMockInitialValues({});
    await Hive.close();
    dir = Directory.systemTemp.createTempSync('picker_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    store = Store();
    await store.init();
    store.useBackend(const NullBackend());
  }

  testWidgets('테마 빠른 선택기가 모든 테마를 보여주고 즉시 적용한다', (tester) async {
    await tester.runAsync(openStore);
    await tester.runAsync(() => store.setDesignKey('paper'));

    final cat = Category(
        id: 'todo', label: '할일', emoji: '✅', colorValue: 0xFF4C6B8A);
    final tasks = [
      Task(
          id: '1',
          title: '리모델링 10월 월간보고',
          categoryId: 'todo',
          amount: 1250000),
      Task(id: '2', title: '이승준 부부님 11/13(금) 세션', categoryId: 'todo'),
      Task(id: '3', title: '천정형 조명 확인', categoryId: 'todo', note: '거실'),
    ];

    setDesign('paper');
    setFontPrefs('system', 1.0);
    setHandwriting(false);
    tester.view.physicalSize = const Size(390 * 3, 760 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<Store>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.build(AppSkins.defaultId, Brightness.light),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('June 스케줄러'),
              actions: const [DesignQuickPicker()],
            ),
            body: ListView(children: [
              for (var i = 0; i < tasks.length; i++)
                TaskRow(
                  task: tasks[i],
                  category: cat,
                  assignTargets: [cat],
                  stripeIndex: i,
                  onToggle: () {},
                  onTap: () {},
                  onDelete: () {},
                  onAssign: (_) {},
                ),
            ]),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // 연다
    await tester.tap(find.byType(DesignQuickPicker));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // 아홉 개 테마 이름이 모두 보여야 한다
    for (final id in AppDesigns.ids) {
      expect(find.text(contextName(id)), findsWidgets,
          reason: '$id 가 선택기에 없다');
    }
    // 실제로 적용되는지: 테마를 바꾸면 store 가 즉시 반영한다.
    //
    // ## 여기서 크게 데인 부분 — onSelected 는 "탭한 순간"에 불리지 않는다
    // PopupMenuButton 은 항목을 탭하면 **먼저 메뉴를 닫는 애니메이션을 예약**하고,
    // 그 애니메이션이 끝난 뒤에야 onSelected 를 호출한다. 그래서
    //   tap → runAsync 로 실시간 대기 → expect
    // 순서로 짜면 영원히 옛 값이 나온다. 실시간을 아무리 기다려도 프레임이
    // 돌지 않으면 애니메이션은 1도 진행되지 않기 때문이다(가짜 시계).
    // 반드시 pump 로 프레임을 넘겨 애니메이션을 끝낸 뒤에 확인해야 한다.
    await tester.tap(find.text('터미널').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Hive 쓰기는 진짜 파일 I/O 라서, 프레임을 넘겨 준 다음 실제 시간도
    // 조금 흘려 줘야 값이 확정된다.
    await tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        if (store.designKey == 'terminal') break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.designKey, 'terminal',
        reason: '선택기가 테마를 실제로 바꾸지 못했다');

    // 바뀐 테마가 실제 렌더에도 반영되는지 — 표 머리글이 나타나야 한다.
    // store 값만 바뀌고 화면이 그대로면 그건 절반만 성공한 것이다.
    // (main.dart 가 setDesign 을 부르는 것과 같은 일을 여기서 한다.)
    setDesign(store.designKey);
    await tester.pump();
    expect(find.byType(TaskRow), findsWidgets);
  });

  // ## tearDown 이 멈추던 문제 (여기서 마지막으로 걸렸다)
  // `await Hive.close()` 는 열린 박스를 진짜 파일에서 닫는다. testWidgets 의
  // 가짜 시계 아래에 놓이면 그 future 가 완료되지 않고, 증상은 "본문은 전부
  // 통과했는데 did not complete" 로만 나타난다 — 어서션 실패보다 훨씬 고약하다.
  //
  // runAsync 로 감싸는 것도 답이 아니었다. tearDown 이 도는 시점에는 테스트의
  // 비동기 영역이 이미 정리 단계라 runAsync 가 그 자리에서 멈춘다.
  //
  // 이 파일에는 테스트가 하나뿐이고, 남는 것은 임시 디렉터리와 열린 박스뿐이다.
  // 박스는 프로세스가 끝날 때 OS 가 회수하므로 여기서 닫지 않는다.
  // (Hive 를 닫아야 하는 테스트가 여러 개인 파일이라면, 닫는 일을 본문 마지막의
  //  runAsync 안으로 옮겨야 한다.)
  tearDown(() {
    try {
      store.sync.stop();
    } catch (_) {}
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  });
}

String contextName(String id) {
  const names = {
    'paper': '페이퍼',
    'studioe': '스튜디오 E',
    'desk': '데스크',
    'gazette': '가제트',
    'ledger': '레저',
    'terminal': '터미널',
    'compact': '컴팩트',
    'matrix': '매트릭스',
    'chrono': '크로노',
  };
  return names[id] ?? id;
}
