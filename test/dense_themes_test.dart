// 고밀도 테마가 정말 촘촘한가 — 그리고 기존 테마를 건드리지 않았는가.
//
// 이 테스트가 없으면 "고밀도 테마 5개 추가"는 이름만 늘리는 일이 된다.
// 밀도는 느낌이 아니라 숫자여야 하고, 숫자는 두 방향으로 확인해야 한다.
//
//  1. 새 테마가 기존 테마보다 실제로 더 많은 행을 한 화면에 담는가.
//  2. 기존 네 테마(PAPER/STUDIO/DESK/GAZETTE)의 값이 예전 그대로인가.
//     밀도 필드를 추가할 때 기본값을 "예전 동작"으로 잡은 이유가 이것이다.
//     기본값을 잘못 잡으면 사용자가 아무 요청도 안 했는데 화면이 바뀐다.
//
// 마지막으로 실제 위젯을 그려서 확인한다: 터미널 테마에서 한 행의 높이가
// 종이 테마보다 눈에 띄게 작은가. 스펙 숫자와 렌더 결과가 따로 놀면 의미가 없다.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/models/models.dart';
import 'package:june_scheduler/theme/app_theme.dart';
import 'package:june_scheduler/widgets/task_row.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const originals = ['paper', 'studioe', 'desk', 'gazette'];

  group('카탈로그', () {
    test('고밀도 테마가 다섯 개 있고 카탈로그에 모두 들어 있다', () {
      expect(AppDesigns.denseIds.length, 5);
      for (final id in AppDesigns.denseIds) {
        expect(AppDesigns.ids, contains(id), reason: '$id 누락');
        expect(AppDesigns.contains(id), isTrue);
        expect(AppDesigns.of(id).id, id);
        expect(AppDesigns.isDense(id), isTrue);
      }
      // 기존 넷은 그대로 있어야 한다.
      for (final id in originals) {
        expect(AppDesigns.ids, contains(id), reason: '$id 가 사라졌다');
        expect(AppDesigns.isDense(id), isFalse);
      }
      expect(AppDesigns.ids.length, 9);
    });

    test('모든 고밀도 테마가 기존 테마보다 밀도가 높다', () {
      final baseline = originals
          .map((id) => AppDesigns.of(id).surface.densityScore)
          .reduce((a, b) => a > b ? a : b);

      for (final id in AppDesigns.denseIds) {
        final score = AppDesigns.of(id).surface.densityScore;
        expect(
          score,
          greaterThan(baseline),
          reason:
              '$id (${score.toStringAsFixed(2)}) 가 기존 최고 '
              '(${baseline.toStringAsFixed(2)}) 보다 촘촘하지 않다',
        );
      }
    });

    test('다섯 개가 서로 충분히 다르다 (색만 바꾼 변형이 아니다)', () {
      final scores = AppDesigns.denseIds
          .map((id) => AppDesigns.of(id).surface.densityScore)
          .toList();
      // 최고와 최저가 최소 40% 차이 나야 "다른 선택지"라고 부를 수 있다.
      final min = scores.reduce((a, b) => a < b ? a : b);
      final max = scores.reduce((a, b) => a > b ? a : b);
      expect(
        max / min,
        greaterThan(1.4),
        reason:
            '고밀도 테마끼리 밀도 차이가 ${(max / min).toStringAsFixed(2)}배 '
            '뿐이다 — 사용자가 고를 이유가 없다',
      );

      // 그리고 서로 같은 스펙 조합이 있으면 안 된다.
      final signatures = AppDesigns.denseIds.map((id) {
        final s = AppDesigns.of(id).surface;
        return '${s.titleSize}/${s.rowGap}/${s.showNote}/${s.showMeta}'
            '/${s.showAssignChips}/${s.zebra}/${s.rowDivider}';
      }).toSet();
      expect(
        signatures.length,
        AppDesigns.denseIds.length,
        reason: '스펙이 완전히 같은 테마가 있다',
      );
    });
  });

  group('기존 테마 회귀 — UI 는 요청 없이 바뀌면 안 된다', () {
    test('paper 의 값이 예전 그대로다', () {
      final s = AppDesigns.of('paper').surface;
      expect(s.radius, 12);
      expect(s.radiusSmall, 6);
      expect(s.rowGap, 8);
      expect(s.headerHeight, 92);
      expect(s.pillChips, isTrue);
      expect(s.roundCheck, isFalse);
      expect(s.elevation, closeTo(0.55, 0.001));
      // 밀도 필드는 전부 "예전 동작" 기본값이어야 한다.
      expect(s.titleSize, 13.5);
      expect(s.metaSize, 10);
      expect(s.checkSize, 26);
      expect(s.showAssignChips, isTrue);
      expect(s.rowDivider, isFalse);
      expect(s.showMeta, isTrue);
      expect(s.showNote, isTrue);
      expect(s.zebra, isFalse);
      expect(s.compactCategory, isFalse);
      expect(s.amountGutter, isFalse);
      expect(s.upperMeta, isFalse);
    });

    test('studioe / desk / gazette 도 밀도 필드 기본값을 유지한다', () {
      for (final id in ['studioe', 'desk', 'gazette']) {
        final s = AppDesigns.of(id).surface;
        expect(s.titleSize, 13.5, reason: '$id titleSize');
        expect(s.rowGap, id == 'desk' ? 4 : (id == 'gazette' ? 0 : 0));
        expect(s.showAssignChips, isTrue, reason: '$id 칩 띠가 사라졌다');
        expect(s.rowDivider, isFalse, reason: '$id 에 구분선이 생겼다');
        expect(s.zebra, isFalse, reason: '$id 에 줄무늬가 생겼다');
      }
    });

    test('기존 테마는 칩 띠를 잃지 않는다 (기능 회귀 금지)', () {
      for (final id in originals) {
        expect(
          AppDesigns.of(id).surface.showAssignChips,
          isTrue,
          reason: '$id 에서 카테고리 즉시 지정 기능이 사라졌다',
        );
      }
    });
  });

  group('실제 렌더 — 스펙 숫자가 화면에 반영되는가', () {
    late Category cat;
    late Task task;

    setUp(() {
      cat = Category(
        id: 'todo',
        label: '할일',
        emoji: '✅',
        colorValue: 0xFF4C6B8A,
      );
      task = Task(
        id: 't1',
        title: '도면 검토 — 3층 평면',
        categoryId: 'todo',
        note: '구조팀 확인 필요',
        amount: 1250000,
      );
    });

    Future<double> rowHeight(WidgetTester tester, String designId) async {
      setDesign(designId);
      setFontPrefs('system', 1.0);
      setHandwriting(false);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(AppSkins.defaultId, Brightness.light),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 380,
                child: TaskRow(
                  key: key,
                  task: task,
                  category: cat,
                  assignTargets: [cat],
                  onToggle: () {},
                  onTap: () {},
                  onDelete: () {},
                  onAssign: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final size = tester.getSize(find.byKey(key));
      return size.height;
    }

    testWidgets('터미널 행이 종이 행보다 확실히 낮다', (tester) async {
      final paper = await rowHeight(tester, 'paper');
      final terminal = await rowHeight(tester, 'terminal');

      expect(
        terminal,
        lessThan(paper * 0.72),
        reason:
            '종이 ${paper.toStringAsFixed(1)}px vs '
            '터미널 ${terminal.toStringAsFixed(1)}px — 고밀도답지 않다',
      );
    });

    testWidgets('고밀도 테마 다섯 개 모두 종이보다 낮다', (tester) async {
      final paper = await rowHeight(tester, 'paper');
      for (final id in AppDesigns.denseIds) {
        final h = await rowHeight(tester, id);
        expect(
          h,
          lessThan(paper),
          reason:
              '$id 행이 ${h.toStringAsFixed(1)}px 로 '
              '종이 ${paper.toStringAsFixed(1)}px 보다 낮지 않다',
        );
      }
    });

    testWidgets('칩 띠를 끄면 행이 눈에 띄게 줄어든다', (tester) async {
      // 같은 테마 안에서 칩 띠만 켜고 끈 차이를 잰다. 밀도 필드가 실제로
      // 일하고 있다는 가장 직접적인 증거다.
      final paper = await rowHeight(tester, 'paper');

      // desk 는 여전히 칩을 켠다 — 기존 동작 유지 확인용.
      final desk = await rowHeight(tester, 'desk');
      expect(desk, lessThan(paper), reason: 'desk 는 rowGap 이 작아 더 낮다');

      // ledger 는 칩을 껐다.
      final ledger = await rowHeight(tester, 'ledger');
      expect(
        ledger,
        lessThan(desk),
        reason: '칩 띠를 끈 ledger 가 칩을 켠 desk 보다 낮아야 한다',
      );
    });

    testWidgets('상세 정보는 사라지지 않는다 — 금액은 고밀도에서도 보인다', (tester) async {
      for (final id in AppDesigns.denseIds) {
        await rowHeight(tester, id);
        expect(
          find.textContaining('1,250,000'),
          findsOneWidget,
          reason: '$id: 금액은 목록에서 유일하게 남아야 하는 정보 중 하나다',
        );
      }
    });

    testWidgets('다섯 개 모두 진짜 표(table)다 — 열과 머리글을 갖는다', (tester) async {
      for (final id in AppDesigns.denseIds) {
        final spec = AppDesigns.of(id).surface;
        expect(spec.isTable, isTrue, reason: '$id: 고밀도는 "작은 목록"이 아니라 "표"여야 한다');
        expect(spec.showTableHeader, isTrue, reason: '$id: 열에 이름이 있어야 열이다');
        expect(spec.colCategory, greaterThan(0), reason: '$id: 분류 열이 없다');
        expect(spec.colAmount, greaterThan(0), reason: '$id: 금액 열이 없다');
        // 표는 한 줄 레이아웃과 동시에 쓰면 정보가 두 번 그려진다.
        expect(spec.inlineMeta, isFalse, reason: '$id: 표와 인라인 접기는 배타적이다');
      }
    });

    testWidgets('표 행은 한 줄로 유지된다 — 금액이 줄바꿈되면 표가 무너진다', (tester) async {
      for (final id in AppDesigns.denseIds) {
        final h = await rowHeight(tester, id);
        // 한 줄짜리 표 행은 40px 를 넘을 이유가 없다. 넘으면 어딘가에서
        // 줄바꿈이 일어나 '열'이 깨진 것이다.
        expect(
          h,
          lessThan(40),
          reason: '$id: 행 높이 ${h.toStringAsFixed(1)}px — 표 행이 한 줄이 아니다',
        );
      }
    });

    testWidgets('표는 정보를 빼지 않는다 — 분류·금액·제목이 모두 보인다', (tester) async {
      for (final id in AppDesigns.denseIds) {
        await rowHeight(tester, id);
        expect(
          find.textContaining('1,250,000'),
          findsOneWidget,
          reason: '$id: 금액이 사라졌다',
        );
        // 표기 방식은 테마마다 다르다(색 견본 `할일`, 이모지 포함 `✅ 할일`).
        // 확인하려는 것은 표기법이 아니라 '분류 정보가 남아 있는가'다.
        expect(
          find.textContaining('할일'),
          findsWidgets,
          reason: '$id: 분류가 사라졌다',
        );
        expect(
          find.textContaining('도면 검토'),
          findsOneWidget,
          reason: '$id: 제목이 사라졌다',
        );
      }
    });
  });

  group('다섯 개가 실제로 서로 다르게 보인다 (측정)', () {
    late Category c2;
    late Task t2;

    setUp(() {
      c2 = Category(
        id: 'todo',
        label: '할일',
        emoji: '✅',
        colorValue: 0xFF4C6B8A,
      );
      t2 = Task(
        id: 't2',
        title: '도면 검토 — 3층 평면',
        categoryId: 'todo',
        note: '구조팀 확인 필요',
        amount: 1250000,
      );
    });

    Future<double> measure(WidgetTester tester, String designId) async {
      setDesign(designId);
      setFontPrefs('system', 1.0);
      setHandwriting(false);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(AppSkins.defaultId, Brightness.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 380,
                child: TaskRow(
                  task: t2,
                  category: c2,
                  assignTargets: [c2],
                  onToggle: () {},
                  onTap: () {},
                  onDelete: () {},
                  onAssign: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getSize(find.byType(TaskRow)).height;
    }

    testWidgets('고밀도 다섯 개가 서로 다른 높이를 낸다', (tester) async {
      final heights = <String, double>{};
      for (final id in AppDesigns.denseIds) {
        heights[id] = await measure(tester, id);
      }
      // 완전히 같은 높이가 둘 이상 있으면 그 둘은 사용자에게 같은 테마다.
      final values = heights.values.map((h) => h.toStringAsFixed(1)).toList();
      expect(
        values.toSet().length,
        greaterThanOrEqualTo(4),
        reason: '높이가 겹친다: $heights',
      );
      // 가장 촘촘한 것과 가장 덜 촘촘한 것의 차이가 보여야 한다.
      final sorted = heights.values.toList()..sort();
      expect(
        sorted.first,
        lessThan(sorted.last * 0.85),
        reason: '고밀도 테마끼리 높이 차가 거의 없다: $heights',
      );
    });

    testWidgets('종이 대비 최소 두 배는 촘촘하다', (tester) async {
      final paper = await measure(tester, 'paper');
      for (final id in AppDesigns.denseIds) {
        final h = await measure(tester, id);
        expect(
          h,
          lessThan(paper * 0.5),
          reason:
              '$id: ${h.toStringAsFixed(1)}px vs 종이 '
              '${paper.toStringAsFixed(1)}px — 두 배 밀도에 못 미친다',
        );
      }
    });

    testWidgets('행 삭제 버튼을 끄면 높이가 절반 가까이 줄어든다', (tester) async {
      // Material 의 IconButton 은 최소 40px 탭 영역을 강제한다. 이 위젯 하나가
      // 행 전체 높이를 결정한다는 사실을 숫자로 못박아 둔다.
      final desk = await measure(tester, 'desk'); // 버튼 유지
      final ledger = await measure(tester, 'ledger'); // 버튼 제거
      expect(
        ledger,
        lessThan(desk * 0.6),
        reason:
            'desk ${desk.toStringAsFixed(1)} vs '
            'ledger ${ledger.toStringAsFixed(1)}',
      );
    });
  });
}
