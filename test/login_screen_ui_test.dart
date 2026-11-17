// 로그인 화면의 "이 기기에서 사용한 계정" 섹션이 실제로 그려지는지 확인한다.
//
// 서비스 계층 테스트(remembered_accounts_test.dart)는 저장·조회 로직만 본다.
// 여기서는 눈에 보이는 것을 본다: 계정이 있을 때 섹션이 나타나는가, 없을 때
// 나타나지 않는가, 그리고 비밀번호가 없는 계정을 누르면 아이디만 채워지는가.
//
// ## 시계 이야기 (한 번 크게 데인 부분)
// testWidgets 안에서는 시계가 가짜이고 타이머도 손으로 돌려야 한다. 그런데
// Hive 의 파일 I/O 는 **진짜** 비동기다. 가짜 시계 안에서 그걸 await 하면
// 영원히 끝나지 않고, 결국 테스트 러너가 죽는다 ("The Dart compiler exited
// unexpectedly" 라는 엉뚱한 메시지와 함께).
//
// 그래서 store 를 여는 일은 전부 `tester.runAsync` 안에서 한다. runAsync 는
// 콜백을 진짜 비동기 영역에서 돌려주는 공식 탈출구다. 화면을 그리는 일만
// 가짜 시계에 남긴다.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:june_scheduler/screens/login_screen.dart';
import 'package:june_scheduler/services/cloud/cloud_backend.dart';
import 'package:june_scheduler/services/store.dart';
import 'package:june_scheduler/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Store store;

  /// 실제 시간에서 store 를 준비한다. 위젯은 그 다음에 그린다.
  Future<void> openStore() async {
    SharedPreferences.setMockInitialValues({});
    await Hive.close();
    dir = Directory.systemTemp.createTempSync('loginscreen_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    store = Store();
    await store.init();
    store.useBackend(const NullBackend());
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<Store>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.build(store.skinKey, Brightness.light),
          home: const LoginScreen(),
        ),
      ),
    );
    // pumpAndSettle 은 쓰지 않는다. 위젯이 타이머를 돌리면 끝나지 않는다.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }

  tearDown(() async {
    try {
      store.sync.stop();
    } catch (_) {}
    await Hive.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('계정이 없으면 빠른 로그인 섹션이 보이지 않는다', (tester) async {
    await tester.runAsync(openStore);
    await pump(tester);

    expect(find.text('이 기기에서 사용한 계정'), findsNothing);
    expect(find.text('June 스케줄러'), findsOneWidget);
  });

  testWidgets('로그인한 계정이 있으면 하단에 이름과 아이디가 보인다', (tester) async {
    await tester.runAsync(() async {
      await openStore();
      await store.addUser('dad', 'abcd1234', displayName: '아빠');
      await store.authenticate('dad', 'abcd1234');
    });
    await pump(tester);

    expect(find.text('이 기기에서 사용한 계정'), findsOneWidget,
        reason: '저장된 계정이 있으면 섹션이 나타나야 한다');
    expect(find.text('아빠'), findsOneWidget, reason: '표시 이름');
    expect(find.text('dad'), findsOneWidget, reason: '아이디');
    expect(find.textContaining('이 기기에만 저장'), findsOneWidget,
        reason: '비밀번호가 기기에 남는다는 사실을 알려야 한다');
  });

  testWidgets('비밀번호가 저장된 계정은 채워진 열쇠 아이콘으로 표시된다', (tester) async {
    await tester.runAsync(() async {
      await openStore();
      await store.addUser('mom', 'hunter2!', displayName: '엄마');
      await store.authenticate('mom', 'hunter2!');
    });
    await pump(tester);

    // 채워진 열쇠 = 누르면 바로 로그인. 빈 열쇠 = 비밀번호를 물어본다.
    expect(find.byIcon(Icons.key_rounded), findsOneWidget);
    expect(find.byIcon(Icons.key_outlined), findsNothing);
  });

  testWidgets('비밀번호가 없는 계정을 누르면 아이디만 채워진다', (tester) async {
    await tester.runAsync(() async {
      await openStore();
      await store.addUser('guest', 'guestpw1', displayName: '손님');
      await store.authenticate('guest', 'guestpw1');
      // 다른 기기에서 비밀번호가 바뀐 상황을 흉내낸다.
      await store.forgetSavedPassword('guest');
    });
    await pump(tester);

    expect(find.byIcon(Icons.key_outlined), findsOneWidget);

    await tester.tap(find.text('손님'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // 계정 목록은 그대로 있고, 로그인은 시도되지 않았다 (스피너 없음).
    expect(find.text('이 기기에서 사용한 계정'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('대표 계정에는 표시가 붙는다', (tester) async {
    await tester.runAsync(() async {
      await openStore();
      // 마스터 계정은 init 에서 이미 만들어지지만 비밀번호가 무작위
      // 자리표시자다. 그건 절대 "저장된 비밀번호"로 승격되면 안 된다.
      await store.rememberAccount(Store.masterId, rememberPassword: false);
    });
    await pump(tester);

    expect(find.text('대표'), findsOneWidget);
    expect(find.byIcon(Icons.key_outlined), findsOneWidget,
        reason: '자리표시자 비밀번호는 저장되면 안 된다');
  });
}
