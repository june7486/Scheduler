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
    // runAsync 로 감싸는 이유는 setDesignKey 가 실제 Hive 에 쓰기 때문이다.
    // testWidgets 의 가짜 시계 아래에서 진짜 파일 I/O 를 돌리면 그 future 가
    // 영원히 완료되지 않고 테스트가 멈춘다(이 프로젝트에서 이미 여러 번 겪었다).
    await tester.tap(find.text('터미널').first);
    await tester.pump();
    await tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        if (store.designKey == 'terminal') break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    expect(store.designKey, 'terminal',
        reason: '선택기가 테마를 실제로 바꾸지 못했다');
  });

  tearDown(() async {
    try {
      store.sync.stop();
    } catch (_) {}
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
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
