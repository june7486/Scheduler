// 업데이트 팝업 위젯 시험.
//
// ## 왜 위젯 시험까지 필요한가
//
// `update_service_test.dart` 는 "새 빌드가 있는지 **판단**" 만 검사합니다.
// 판단이 맞아도 팝업이 깨져 있으면 사용자는 아무것도 못 봅니다:
//   · 버튼이 없거나 눌리지 않음
//   · "나중에" 를 눌렀는데 true 가 나옴 (그 반대도)
//   · 바깥을 눌러 닫았을 때 예외 (null 을 못 받아서)
//
// ## 이 파일이 지키는 계약
//
//   지금 업데이트 → true
//   나중에        → false
//   바깥 눌러 닫기 → false   (null 이 아니라 false)
//
// ## 왜 마지막 것이 중요한가
//
// `showDialog` 는 바깥을 누르면 `null` 을 돌려줍니다. `main.dart` 는
// 그 값을 bool 로 받아 분기합니다. `?? false` 를 빠뜨리면 타입 오류로
// 앱이 죽거나, 최악의 경우 null 을 true 로 착각해 **사용자 의사와 반대로
// 새로고침**합니다. 입력 중이던 내용이 날아갑니다.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/services/update_service.dart';
import 'package:june_scheduler/widgets/update_dialog.dart';

/// 시험용 UpdateCheck. 실제 서비스 없이 팝업만 띄웁니다.
UpdateCheck _check({
  String current = '2026.11.20.1400',
  String remote = '2026.11.21.0200',
  String? notes,
}) {
  return UpdateCheck(
    available: true,
    currentBuild: current,
    remoteBuild: remote,
    remoteVersion: '1.0.0',
    notes: notes,
  );
}

/// 팝업을 띄우고, 그 결과를 [result] 에 담는 최소 앱.
///
/// `UpdateDialog.show` 를 직접 부르는 이유: main.dart 의 배선이 아니라
/// **팝업 자체의 계약**을 시험하기 위해서입니다.
class _Host extends StatefulWidget {
  const _Host({required this.check, required this.onResult});
  final UpdateCheck check;
  final void Function(bool) onResult;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final r = await UpdateDialog.show(context, widget.check);
      widget.onResult(r);
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('기저 화면')));
  }
}

Future<bool?> _pumpAndCapture(
  WidgetTester tester, {
  required UpdateCheck check,
  required Future<void> Function(WidgetTester) interact,
}) async {
  bool? captured;
  var done = false;

  await tester.pumpWidget(MaterialApp(
    home: _Host(
      check: check,
      onResult: (r) {
        captured = r;
        done = true;
      },
    ),
  ));

  // 첫 프레임 뒤 postFrameCallback 이 돌아 팝업이 뜹니다.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  await interact(tester);
  await tester.pumpAndSettle();

  expect(done, isTrue, reason: '팝업이 결과를 돌려주지 않았습니다');
  return captured;
}

void main() {
  group('팝업이 뜬다', () {
    testWidgets('제목과 두 버튼이 보인다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: _Host(check: _check(), onResult: (_) {}),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(AlertDialog), findsOneWidget);
      // 버튼 두 개 — 라벨 문자열은 다국어 테이블에 있으므로 개수로 확인합니다.
      expect(find.byType(TextButton), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
    });

    testWidgets('notes 가 있으면 그대로 보여준다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: _Host(
          check: _check(notes: '반복 일정 버그 수정'),
          onResult: (_) {},
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('반복 일정 버그 수정'), findsOneWidget);
    });

    testWidgets('notes 가 없으면 빈칸 대신 안내 문구를 보여준다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: _Host(check: _check(notes: null), onResult: (_) {}),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 빈 문자열이 그려지면 사용자는 "아무 정보 없음" 으로 봅니다.
      // 최소한 빌드 ID 는 보여야 "내 것과 다르다"가 전달됩니다.
      expect(find.textContaining('2026.11.21.0200'), findsWidgets);
    });
  });

  group('선택의 결과가 정확하다', () {
    testWidgets('"지금 업데이트" → true', (tester) async {
      final r = await _pumpAndCapture(
        tester,
        check: _check(),
        interact: (t) async {
          await t.tap(find.byType(FilledButton));
        },
      );
      expect(r, isTrue);
    });

    testWidgets('"나중에" → false', (tester) async {
      final r = await _pumpAndCapture(
        tester,
        check: _check(),
        interact: (t) async {
          await t.tap(find.byType(TextButton));
        },
      );
      expect(r, isFalse);
    });

    testWidgets('바깥을 눌러 닫아도 false (null 이 아니다)', (tester) async {
      // ## 이 시험이 가장 중요합니다
      // showDialog 는 바깥을 누르면 null 을 돌려줍니다. 팝업이 `?? false`
      // 를 빠뜨리면 null 이 그대로 올라가고, 호출하는 쪽이 null 을
      // truthy 로 다루면 **사용자가 닫았는데 새로고침**됩니다.
      final r = await _pumpAndCapture(
        tester,
        check: _check(),
        interact: (t) async {
          // 다이얼로그 바깥(좌상단 모서리)을 누릅니다.
          await t.tapAt(const Offset(5, 5));
        },
      );
      expect(r, isFalse);
      expect(r, isNotNull);
    });
  });

  group('긴 빌드 ID 를 다룬다', () {
    testWidgets('아주 긴 값도 레이아웃을 깨뜨리지 않는다', (tester) async {
      // 18자 초과는 잘라서 보여줍니다. 자르지 않으면 팝업이 넘칩니다.
      final r = await _pumpAndCapture(
        tester,
        check: _check(
          remote: '2026-11-21T02-00-00Z-CRITICAL-HOTFIX-BUILD',
        ),
        interact: (t) async {
          await t.tap(find.byType(TextButton));
        },
      );
      expect(r, isFalse);
      // 넘침 예외가 있었으면 pumpAndSettle 단계에서 실패합니다.
      expect(tester.takeException(), isNull);
    });

    testWidgets('빈 문자열도 예외 없이 처리한다', (tester) async {
      // 서버가 build 를 빈 값으로 주면 여기까지 오지 않는 것이 정상이지만,
      // 방어적으로 막아둡니다. '—' 로 표시됩니다.
      final r = await _pumpAndCapture(
        tester,
        check: _check(current: '', remote: ''),
        interact: (t) async {
          await t.tap(find.byType(TextButton));
        },
      );
      expect(r, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
